-- PDCoopNet channel: messages between the host and the other players over our own replicated actor.
-- Loaded by main.lua: require("channel")(ctx). The modules use hostSend / hostSendLatest / sendCommand and
-- hostMsgHandlers; main.lua sets the command handler and calls hostTick / clientTick every 200 ms.
return function(ctx)
local log, valid, objName, UEHelpers = ctx.log, ctx.valid, ctx.objName, ctx.UEHelpers
local ROLE = ctx.role
local function localController() return ctx.localController() end

-- ---------------------------------------------------------------- channel
-- Our own replicated actor from PDCoopNet.pak (mounted by UE4SS's BPModLoaderMod; source in the repo's pak/): the
-- host spawns one PDCoopChannel per remote player and gives it to that player's controller (it is relevant only
-- to its owner). ServerSend(Msg) runs on the host, ClientSend(Msg) on the owning client; both are reliable RPCs,
-- so messages arrive whole and in order, and the hooks below handle each one as it arrives.
-- exp123: one RPC carries up to 64 KB (a 100 KB one was refused by the engine, the connection stayed up), so
-- bigger messages go as parts. A connection keeps at most 256 reliable bunches waiting for an acknowledgement
-- (about 1 KB each), so each side sends at most CHAN_TICK_BYTES per 200 ms tick and keeps the rest queued.
local CHAN_CLASS = "/Game/Mods/PDCoopNet/PDCoopChannel.PDCoopChannel_C"
local CHAN_MAX = 16000
local CHAN_TICK_BYTES = 32000
local fastTick = 0           -- 200 ms ticks of the host channel loop (stats)
local hostMsgHandlers = {}   -- kind -> function(rest, seq), host -> client messages
local handleHostCommand      -- function(pc, cmd, seq), client -> host commands (main.lua sets it)

local chanClass = nil
local function channelClass()
    if valid(chanClass) then return chanClass end
    local c = StaticFindObject(CHAN_CLASS)
    if not valid(c) then
        -- UE4SS LoadAsset returned an invalid object for it (exp123); the asset registry loads it, as BPModLoaderMod does
        local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if valid(arh) then pcall(function() c = arh:GetAsset({ ObjectPath = UEHelpers.FindOrAddFName(CHAN_CLASS) }) end) end
    end
    chanClass = valid(c) and c or nil
    return chanClass
end

local function myPlayerId()
    local pc = localController()
    local id = nil
    pcall(function() id = pc.PlayerState.PlayerId end)
    return id
end

-- "PART|<id>|<i>|<n>|<piece>" for a message over CHAN_MAX
local partSeq = 0
local function splitMessage(payload, queue)
    if #payload <= CHAN_MAX then table.insert(queue, payload); return end
    local size = CHAN_MAX - 40
    local n = math.ceil(#payload / size)
    partSeq = partSeq + 1
    for i = 1, n do
        table.insert(queue, string.format("PART|%d|%d|%d|%s", partSeq, i, n, payload:sub((i - 1) * size + 1, i * size)))
    end
    log("CHAN message of %d bytes queued in %d parts", #payload, n)
end

-- collects the parts of one sender (bufs: message id -> parts; the parts of an urgent message can come between
-- the parts of a bulk one); returns the whole message with its last part
local function joinParts(bufs, rest)
    local id, i, n, piece = rest:match("^(%d+)|(%d+)|(%d+)|(.*)$")
    i, n = tonumber(i), tonumber(n)
    if not id then return nil end
    if i == 1 or not bufs[id] then bufs[id] = {} end
    local parts = bufs[id]
    parts[i] = piece
    if i < n then return nil end
    bufs[id] = nil
    for k = 1, n do
        if not parts[k] then log("CHAN message %s: part %d missing, dropped", id, k); return nil end
    end
    return table.concat(parts)
end

-- sends from the front of the queues, the first queue first, up to the byte budget of one tick (always at least
-- one message)
local function drain(queues, send)
    local budget = CHAN_TICK_BYTES
    for _, queue in ipairs(queues) do
        while #queue > 0 and (budget == CHAN_TICK_BYTES or #queue[1] <= budget) do
            local msg = table.remove(queue, 1)
            send(msg)
            budget = budget - #msg
        end
        if budget <= 0 then return end
    end
end

-- host side: one channel per remote player, client commands arrive through the ServerSend hook
-- Two queues: state the other player needs now (items, car, trunk, doors, downed...) and bulk (the world
-- placement table, 100+ KB per zone, nearest first), which only gets what is left of a tick's budget.
local BULK_KINDS = { WFIX = true }
local hostChannels = {}      -- remote PlayerController full name -> its channel
local hostOut = { queue = {}, bulk = {} }
local hostParts = {}         -- remote PlayerController full name -> part buffers
local hostCmdSeq = {}        -- remote PlayerController full name -> commands received
local function hostSend(payload)
    local kind = payload:match("^([^|]+)") or ""
    -- a reset makes the queued bulk of its kind stale (WFIXRESET -> WFIX)
    local stale = kind:match("^(.+)RESET$")
    if stale and BULK_KINDS[stale] then
        local keep = {}
        for _, q in ipairs(hostOut.bulk) do
            if q:match("^([^|]+)") ~= stale and q:sub(1, 5) ~= "PART|" then keep[#keep + 1] = q end
        end
        if #keep < #hostOut.bulk then log("CHAN %s dropped %d queued bulk message(s)", kind, #hostOut.bulk - #keep) end
        hostOut.bulk = keep
    end
    splitMessage(payload, BULK_KINDS[kind] and hostOut.bulk or hostOut.queue)
end

-- a message that replaces a queued one of the same kind (full-state messages: only the newest matters)
local function hostSendLatest(payload)
    local kind = payload:match("^([^|]+)|")
    if #payload <= CHAN_MAX then
        for i, q in ipairs(hostOut.queue) do
            if q:match("^([^|]+)|") == kind then hostOut.queue[i] = payload; return end
        end
    end
    hostSend(payload)
end

local function onServerSend(ch, msg)
    local pc = ch:GetOwner()
    if not valid(pc) then return end
    local key = pc:GetFullName()
    if msg:sub(1, 5) == "PART|" then
        hostParts[key] = hostParts[key] or {}
        msg = joinParts(hostParts[key], msg:sub(6))
        if not msg then return end
    end
    hostCmdSeq[key] = (hostCmdSeq[key] or 0) + 1
    if handleHostCommand then handleHostCommand(pc, msg, hostCmdSeq[key]) end
end

-- client side: my channel, host messages arrive through the ClientSend hook
local cmdQueue = {}
local clientParts = {}       -- message id -> parts
local recvSeq = 0
local myChannel = nil
local hostSession = ""       -- my channel's name: a new one after a map change or a new host session
local function clientChannel()
    if valid(myChannel) then return myChannel end
    myChannel, hostSession = nil, ""
    local mine = localController()
    if not valid(mine) then return nil end
    for _, ch in ipairs(FindAllOf("PDCoopChannel_C") or {}) do
        local owner = valid(ch) and ch:GetOwner() or nil
        if valid(owner) and owner:GetFullName() == mine:GetFullName() then
            myChannel, hostSession = ch, ch:GetFullName()
            break
        end
    end
    return myChannel
end

local function sendCommand(cmd)
    splitMessage(cmd, cmdQueue)
end

local function clientCommandTick()
    if #cmdQueue == 0 then return end
    local ch = clientChannel()
    if not ch then return end    -- not connected yet: the commands wait
    drain({ cmdQueue }, function(msg)
        ch:ServerSend(msg)
        if msg:sub(1, 5) ~= "PART|" then log("CMD sent %s", msg:sub(1, 120)) end
    end)
end

local function onClientSend(ch, msg)
    if msg:sub(1, 5) == "PART|" then
        msg = joinParts(clientParts, msg:sub(6))
        if not msg then return end
    end
    recvSeq = recvSeq + 1
    local kind, rest = msg:match("^([^|]+)|?(.*)$")
    local h = hostMsgHandlers[kind or ""]
    if h then
        local okH, errH = pcall(h, rest or "", recvSeq)
        if not okH then log("CHAN handler %s failed: %s", tostring(kind), tostring(errH)) end
    else
        log("CHAN recv #%d kind=%s bytes=%d (no handler)", recvSeq, tostring(kind), #msg)
    end
end

-- messages with an actor reference (ServerSendRef / ClientSendRef): the engine maps the reference to the
-- receiver's own copy of the actor (an item marker: player 2 asks what it is, the host answers about it).
-- refHandlers[kind](channel, ref, rest); on the host the sender is channel:GetOwner().
local refHandlers = {}
local function onRef(ch, ref, msg)
    local kind, rest = msg:match("^([^|]+)|?(.*)$")
    local h = refHandlers[kind or ""]
    if h then h(ch, ref, rest or "") else log("CHAN ref message %s has no handler", tostring(kind)) end
end

-- messages received, handled in order by the inbox loop: { channel, text, ref (Ref RPCs only) }
local inbox = {}
local function drainInbox()
    if #inbox == 0 then return end
    local batch = inbox
    inbox = {}
    for _, m in ipairs(batch) do
        local okM, errM = pcall(function()
            if m.ref ~= nil then onRef(m[1], m.ref, m[2])
            elseif ROLE == "host" then onServerSend(m[1], m[2]) else onClientSend(m[1], m[2]) end
        end)
        if not okM then log("CHAN handle error: %s", tostring(errM)) end
    end
end
LoopInGameThreadWithDelay(50, function() drainInbox() end)

-- The RPC hooks must be in place before the first message arrives. The class can be loaded again after a map
-- change (garbage collection), so the hooks follow the function object: checked at start, before the host
-- spawns a channel, and when a channel begins play on the client (before its RPCs are processed).
-- exp124/125: after a map change the class is collected and loaded again (the hooked function object is no
-- longer valid), and the old hook still fires for the new function: the old one is unregistered first, else
-- every message is handled twice.
-- The hook runs inside the engine's packet processing: it only queues; handlers (which spawn actors and load
-- assets) run from the inbox loop (exp127: a handler that loaded an asset inside the RPC hung player 2).
local hooks = {}             -- function name -> { fn = function object, ids = { pre, post } }
local function hookOne(name, withRef)
    local h = hooks[name]
    if h and valid(h.fn) then return true end
    local path = CHAN_CLASS .. ":" .. name
    local fn = StaticFindObject(path)
    if not valid(fn) then return false end
    if h and h.ids then
        local okU, errU = pcall(UnregisterHook, path, h.ids[1], h.ids[2])
        log("CHAN unhooked the old %s: %s %s", name, tostring(okU), tostring(errU or ""))
    end
    local ok, err, postId = pcall(RegisterHook, path, function(self, a, b)
        local okM, errM = pcall(function()
            if withRef then
                local ref = a:get()
                inbox[#inbox + 1] = { self:get(), b:get():ToString(), ref = ref or false }
            else
                inbox[#inbox + 1] = { self:get(), a:get():ToString() }
            end
        end)
        if not okM then log("CHAN %s error: %s", name, tostring(errM)) end
    end)
    if not ok then hooks[name] = nil; log("CHAN hook %s failed: %s", name, tostring(err)); return false end
    hooks[name] = { fn = fn, ids = { err, postId } }
    log("CHAN hooked %s", name)
    return true
end
local function ensureChannelHooks()
    if not channelClass() then return false end
    local plain = hookOne(ROLE == "host" and "ServerSend" or "ClientSend", false)
    -- an older PDCoopNet.pak has no Ref RPCs: the plain channel still works
    hookOne(ROLE == "host" and "ServerSendRef" or "ClientSendRef", true)
    return plain
end

local function hostEnsureChannels()
    local alive, ready = {}, true
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() then
            local key = pc:GetFullName()
            alive[key] = true
            if not valid(hostChannels[key]) then
                hostChannels[key] = nil
                local ch = nil
                if ensureChannelHooks() then
                    pcall(function() ch = pc:GetWorld():SpawnActor(channelClass(), {}, {}) end)
                end
                if valid(ch) then
                    ch:SetOwner(pc)
                    hostChannels[key] = ch
                    log("CHAN opened %s for %s", objName(ch), objName(pc))
                else
                    ready = false
                end
            end
        end
    end
    for key in pairs(hostChannels) do
        if not alive[key] then hostChannels[key], hostParts[key], hostCmdSeq[key] = nil, nil, nil end
    end
    return next(alive) ~= nil, ready
end

-- bytes sent per message kind, logged once a minute (what to make smaller)
local chanStats, chanStatsTick = {}, 0
local function countSent(msg)
    local kind = msg:match("^([^|]+)") or "?"
    chanStats[kind] = (chanStats[kind] or 0) + #msg
end
local function logChanStats()
    if fastTick - chanStatsTick < 300 then return end
    chanStatsTick = fastTick
    local parts, total = {}, 0
    for k, v in pairs(chanStats) do parts[#parts + 1] = k .. "=" .. v; total = total + v end
    if total == 0 then return end
    table.sort(parts)
    log("CHAN stats last minute: %d bytes, queued %d+%d: %s", total, #hostOut.queue, #hostOut.bulk, table.concat(parts, " "))
    chanStats = {}
end

local chanMissingLogged = false
local function hostChannelTick()
    fastTick = fastTick + 1
    local anyClient, ready = hostEnsureChannels()
    -- without clients nothing waits: every module sends its full state to a new set of clients
    if not anyClient then hostOut.queue, hostOut.bulk = {}, {}; return end
    if not ready then
        if not chanMissingLogged then
            chanMissingLogged = true
            log("CHAN cannot open a channel: is PDCoopNet.pak in Content\\Paks\\LogicMods and BPModLoaderMod on?")
        end
        return
    end
    if #hostOut.queue == 0 and #hostOut.bulk == 0 then return end
    local chans = {}
    for _, ch in pairs(hostChannels) do table.insert(chans, ch) end
    drain({ hostOut.queue, hostOut.bulk }, function(msg)
        for _, ch in ipairs(chans) do ch:ClientSend(msg) end
        countSent(msg)
    end)
    logChanStats()
end

local chanFName = UEHelpers.FindOrAddFName("PDCoopChannel_C")
RegisterBeginPlayPostHook(function(ctx)
    if ROLE ~= "client" then return end
    local a = ctx:get()
    if a:GetClass():GetFName() ~= chanFName then return end
    ensureChannelHooks()
    myChannel = nil
    clientChannel()
end)
ExecuteInGameThread(function()
    if ROLE ~= "host" and ROLE ~= "client" then return end
    if not ensureChannelHooks() then log("CHAN PDCoopChannel not loaded at start (PDCoopNet.pak missing?)") end
end)

-- channel test: PING|<i>|<size>|xxx...|END to the client, which answers PINGBACK,<i>,<size>,<same body>
hostMsgHandlers["PING"] = function(rest, seq)
    local i, size, body = rest:match("^(%d+)|(%d+)|(.*)$")
    local okBody = body and body:sub(-4) == "|END" and (#body - 4) == tonumber(size)
    log("CHAN recv PING #%d i=%s size=%s intact=%s", seq, tostring(i), tostring(size), tostring(okBody))
    sendCommand("PINGBACK," .. tostring(i) .. "," .. tostring(size) .. "," .. (body or ""))
end
local pingQueued = false
local function queueChannelTest()
    if pingQueued then return end
    pingQueued = true
    -- 20000 and up go in parts; 70000 and 200000 are over the engine's 64 KB per RPC
    local sizes = { 20, 200, 1000, 4000, 7900, 12000, 20000, 70000, 200000, 20 }
    for i, n in ipairs(sizes) do hostSend("PING|" .. i .. "|" .. n .. "|" .. string.rep("x", n) .. "|END") end
    log("CHAN queued %d test messages", #sizes)
end
local function hostPingBack(args)
    local i, size, body = args:match("^(%d+),(%d+),(.*)$")
    local okBody = body and body:sub(-4) == "|END" and (#body - 4) == tonumber(size)
    log("CHAN recv PINGBACK i=%s size=%s intact=%s", tostring(i), tostring(size), tostring(okBody))
end

return {
    CHAN_MAX = CHAN_MAX, hostMsgHandlers = hostMsgHandlers,
    hostSend = hostSend, hostSendLatest = hostSendLatest, sendCommand = sendCommand, myPlayerId = myPlayerId,
    setCommandHandler = function(fn) handleHostCommand = fn end,
    hostTick = hostChannelTick, clientTick = clientCommandTick,
    clientChannel = clientChannel, hostSession = function() return hostSession end,
    queueTest = queueChannelTest, hostPingBack = hostPingBack,
    refHandlers = refHandlers,
}
end
