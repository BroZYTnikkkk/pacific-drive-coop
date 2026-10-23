-- PDCoopNet items: the host's world items are the truth; the other players have local copies of them.
-- Loaded by main.lua: require("items")(ctx).
--
-- The game's item actors cannot be replicated: the proxy on player 2's machine has no item data and the game's
-- native code reads it at once (exp143: player 2 crashed, access violation at 0x18). So the host gives every world
-- item a marker of our own (PDCoopItemMarker from PDCoopNet.pak, movement replicated, relevant up to 1.5 km) and
-- moves it with the item. Player 2's game gets the marker from the engine, asks the host what it is
-- (ServerSendRef "WHOIS" with the marker; the engine maps it to the host's marker) and the host answers
-- (ClientSendRef "ITEM|<id>|<archetype>|<state>"); player 2 then spawns its own item of that type there, which
-- follows the marker. When the marker goes (the item left the host's world, or player 2 went out of range), the
-- local item goes too.
-- Picking a local item up runs player 2's own game code (it goes into its own inventory); player 2 then tells the
-- host (PICKUP) and the host removes the original. A new local item near player 2 (dropped from its inventory) is
-- sent to the host (DROP), removed locally, and comes back as a marker. Player 2's own world loot (its spawners
-- roll their own) is removed. Item state changes go as "ITEMS|S,<id>,<state>;...". Inventories stay per player.
return function(ctx)
    local log, valid, UEHelpers = ctx.log, ctx.valid, ctx.UEHelpers
    local ItemState, archShort, archLoad, instanceOf = ctx.ItemState, ctx.archShort, ctx.archLoad, ctx.instanceOf
    local M = {}
    local SKIP_ITEM_CLASSES = { BP_GameplayEventItem_World_C = true }
    local MARKER_CLASS = "/Game/Mods/PDCoopNet/PDCoopItemMarker.PDCoopItemMarker_C"

    local markerCls = nil
    local function markerClass()
        if markerCls and not valid(markerCls) then markerCls = nil end     -- collected after a map change
        if not markerCls then
            local c = StaticFindObject(MARKER_CLASS)
            if not valid(c) then
                local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
                pcall(function() c = arh:GetAsset({ ObjectPath = UEHelpers.FindOrAddFName(MARKER_CLASS) }) end)
            end
            markerCls = valid(c) and c or nil
        end
        return markerCls
    end

    -- the world items of this machine: list of { actor, id, arch, state, x, y, z, p, yw, r }
    function M.scan()
        local out = {}
        for _, a in ipairs(FindAllOf("ItemWorldManifestation") or {}) do
            if valid(a) and not SKIP_ITEM_CLASSES[ctx.className(a)] then
                local ok, e = pcall(function()
                    if a:K2_GetActorContext() ~= 0 then return nil end        -- EItemActorContext::World only
                    if a.bHidden then return nil end
                    -- items held by something (a gas pump's handle, a station) are fixtures, not loot: never synced
                    -- (exp38: the client's pump took the mirrored handle and the client reported a false PICKUP)
                    if valid(a:GetAttachParentActor()) then return nil end
                    local inst = a.Instance
                    if not valid(inst) or not valid(inst.Archetype) then return nil end
                    local l = a:K2_GetActorLocation()
                    if math.abs(l.X) + math.abs(l.Y) + math.abs(l.Z) < 1 then return nil end   -- parked at the origin
                    local r = a:K2_GetActorRotation()
                    return { actor = a, id = a:GetFName():ToString() .. "#" .. inst:GetFName():ToString(),
                             -- UE4SS objects have no GetPathName (exp37: every item was skipped); take it from the full name
                             arch = archShort(inst.Archetype:GetFullName():match("%s(%S+)$")),
                             state = ItemState.read(inst),
                             x = l.X, y = l.Y, z = l.Z, p = r.Pitch, yw = r.Yaw, r = r.Roll }
                end)
                if ok and e then out[#out + 1] = e end
            end
        end
        return out
    end
    local function fmtXf(e)
        return string.format("%.0f,%.0f,%.0f,%.0f,%.0f,%.0f", e.x, e.y, e.z, e.p, e.yw, e.r)
    end
    local function anyClient()
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() then return true end
        end
        return false
    end

    -- ------------------------------------------------------------ host
    local host = { known = {}, byMarker = {}, world = nil }    -- id -> entry with .marker; marker name -> id
    local function placeMarker(mk, e)
        mk:K2_SetActorLocationAndRotation({ X = e.x, Y = e.y, Z = e.z }, { Pitch = e.p, Yaw = e.yw, Roll = e.r }, false, {}, true)
    end

    -- every second: a marker for each world item, moved with it; removed with it
    function M.hostTick()
        local okW, addr = pcall(function() return UEHelpers.GetWorld():GetAddress() end)
        if okW and addr ~= host.world then host.world, host.known, host.byMarker = addr, {}, {} end
        if not anyClient() and next(host.known) == nil then return end
        local cls = markerClass()
        if not cls then return end
        local now, states, added, moved = {}, {}, 0, 0
        for _, e in ipairs(M.scan()) do
            local k = host.known[e.id]
            if k and not valid(k.marker) then host.byMarker[k.markerName or ""] = nil; k = nil end
            if not k then
                local mk = nil
                pcall(function() mk = e.actor:GetWorld():SpawnActor(cls, { X = e.x, Y = e.y, Z = e.z }, { Pitch = e.p, Yaw = e.yw, Roll = e.r }) end)
                if valid(mk) then
                    e.marker, e.markerName = mk, mk:GetFullName()
                    host.byMarker[e.markerName] = e.id
                    now[e.id] = e
                    added = added + 1
                end
            else
                if math.abs(k.x - e.x) + math.abs(k.y - e.y) + math.abs(k.z - e.z) > 2
                    or math.abs(k.yw - e.yw) + math.abs(k.p - e.p) + math.abs(k.r - e.r) > 2 then
                    pcall(placeMarker, k.marker, e)
                    k.x, k.y, k.z, k.p, k.yw, k.r = e.x, e.y, e.z, e.p, e.yw, e.r
                    moved = moved + 1
                end
                if (k.state or "") ~= e.state then
                    k.state = e.state
                    states[#states + 1] = "S," .. e.id .. "," .. e.state
                end
                k.actor = e.actor
                now[e.id] = k
            end
        end
        local removed = 0
        for id, k in pairs(host.known) do
            if not now[id] then
                host.byMarker[k.markerName or ""] = nil
                if valid(k.marker) then pcall(function() k.marker:K2_DestroyActor() end) end
                removed = removed + 1
            end
        end
        host.known = now
        if #states > 0 then ctx.hostSend("ITEMS|" .. table.concat(states, ";")) end
        if added + removed > 0 or #states > 0 then
            local c = 0
            for _ in pairs(now) do c = c + 1 end
            log("ITEMSYNC host markers +%d -%d, %d moved, %d state(s) (%d world items)", added, removed, moved, #states, c)
        end
    end

    -- player 2 asks what a marker is
    ctx.refHandlers["WHOIS"] = function(ch, ref, _)
        if ctx.role() ~= "host" then return end
        local id = valid(ref) and host.byMarker[ref:GetFullName()]
        local k = id and host.known[id]
        if not k then return end            -- gone meanwhile: its marker goes too
        ch:ClientSendRef(ref, "ITEM|" .. id .. "|" .. k.arch .. "|" .. (k.state or ""))
    end

    function M.hostCommand(kind, args, pc)
        if kind == "PICKUP" then
            local e = host.known[args]
            if e and valid(e.actor) then
                local inst = instanceOf(e.actor)
                local ok, res = false, "item already gone"
                if inst then ok, res = pcall(function() return inst:Remove(true) end) end
                log("ITEMSYNC PICKUP by %s: removed host item %s (%s) ok=%s", ctx.objName(pc), args, e.arch, tostring(ok and res))
            else
                log("ITEMSYNC PICKUP by %s: host item %s not found", ctx.objName(pc), args)
            end
            return true
        elseif kind == "DROP" then
            local arch, x, y, z, pi, yw, r, st = args:match("^([^,]+),(-?[%d.]+),(-?[%d.]+),(-?[%d.]+),(-?[%d.]+),(-?[%d.]+),(-?[%d.]+),?([%w_.%-]*)$")
            local a = arch and archLoad(arch)
            local inv = FindFirstOf("InventorySystem")
            if a and valid(inv) then
                -- a spawned item does not simulate until something touches it, so player 2's drop (reported at hand
                -- height) hung in the air for both (playtest 2026-10-21). Put it at the feet of player 2's character.
                -- (Turning its physics on instead crashed the host a few seconds later, twice, dev session 2026-10-22.)
                pcall(function()
                    local feet = pc.Pawn:K2_GetActorLocation().Z - 70
                    if tonumber(z) > feet then z = tostring(feet) end
                end)
                local xf = UEHelpers.GetKismetMathLibrary():MakeTransform({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
                    { Pitch = tonumber(pi), Yaw = tonumber(yw), Roll = tonumber(r) }, { X = 1, Y = 1, Z = 1 })
                local ok, act = pcall(function() return inv:SpawnItemActor(UEHelpers.GetWorldContextObject(), xf, a, 0, 0) end)
                if ok and valid(act) and st and st ~= "" then ItemState.write(act.Instance, st, arch) end
                log("ITEMSYNC DROP by %s: spawned %s (%s) on the host ok=%s %s", ctx.objName(pc), arch, st or "", tostring(ok), ok and ctx.objName(act) or tostring(act))
            else
                log("ITEMSYNC DROP by %s: cannot spawn %s", ctx.objName(pc), tostring(arch))
            end
            return true
        end
        return false
    end

    -- ------------------------------------------------------------ client
    local mirror = {}             -- host id -> { actor, actorName, inst, marker, markerName, x, y, z }
    M.mirror = mirror
    local mirrorByActor = {}      -- local actor full name -> host id
    local mirrorByMarker = {}     -- marker full name -> host id
    local asked = {}              -- marker full name -> os.clock() of the last WHOIS
    -- markers whose local item a fixture of this game took (the garage gas pump takes its handle): not asked again
    -- (exp145: the handle was made and taken 64 times)
    local ignored = {}
    local arrivedAt = nil         -- os.clock() when this map's session with the host started

    local function forget(id)
        local m = mirror[id]
        mirror[id] = nil
        if not m then return end
        mirrorByActor[m.actorName] = nil
        mirrorByMarker[m.markerName] = nil
        return m
    end
    local function removeLocal(id)
        local m = forget(id)
        if m and valid(m.actor) and m.actor:GetFullName() == m.actorName then
            local inst = instanceOf(m.actor)
            if inst then pcall(function() inst:Remove(true) end) end
        end
    end

    -- the host's answer: our own item of that type where the marker is
    ctx.refHandlers["ITEM"] = function(_, ref, rest)
        if ctx.role() ~= "client" or not valid(ref) then return end
        local id, arch, st = rest:match("^([^|]+)|([^|]+)|(.*)$")
        if not id then return end
        local mname = ref:GetFullName()
        if mirror[id] then
            if mirror[id].markerName == mname then return end
            removeLocal(id)
        end
        local a = archLoad(arch)
        local inv = FindFirstOf("InventorySystem")
        if not (a and valid(inv)) then log("ITEMSYNC cannot make %s (%s)", id, arch); return end
        local l, r = ref:K2_GetActorLocation(), ref:K2_GetActorRotation()
        local xf = UEHelpers.GetKismetMathLibrary():MakeTransform(l, r, { X = 1, Y = 1, Z = 1 })
        local act = nil
        pcall(function() act = inv:SpawnItemActor(UEHelpers.GetWorldContextObject(), xf, a, 0, 0) end)
        if not valid(act) then return end
        if st and st ~= "" then ItemState.write(act.Instance, st, arch) end
        local name = act:GetFullName()
        mirror[id] = { actor = act, actorName = name, inst = act.Instance:GetFullName(), marker = ref, markerName = mname,
                       x = l.X, y = l.Y, z = l.Z, mx = l.X, my = l.Y, mz = l.Z }
        mirrorByActor[name] = id
        mirrorByMarker[mname] = id
        log("ITEMSYNC client item %s (%s) from its marker at %.0f,%.0f,%.0f", id, arch, l.X, l.Y, l.Z)
    end

    -- item state changes on the host
    ctx.hostMsgHandlers["ITEMS"] = function(rest)
        for op in rest:gmatch("[^;]+") do
            local id, st = op:match("^S,([^,]+),([%w_.%-]*)$")
            local m = id and mirror[id]
            local inst = m and instanceOf(m.actor)
            if inst then ItemState.write(inst, st, id) end
        end
    end

    -- every 200 ms: local items follow their markers; a marker that went takes its item along
    function M.clientFollow()
        for id, m in pairs(mirror) do
            if not valid(m.marker) then
                removeLocal(id)
                log("ITEMSYNC marker of %s gone: local item removed", id)
            elseif valid(m.actor) then
                local l = m.marker:K2_GetActorLocation()
                if math.abs(l.X - m.mx) + math.abs(l.Y - m.my) + math.abs(l.Z - m.mz) > 2 then
                    local r = m.marker:K2_GetActorRotation()
                    pcall(function() m.actor:K2_SetActorLocationAndRotation(l, r, false, {}, true) end)
                    m.mx, m.my, m.mz = l.X, l.Y, l.Z
                end
            end
        end
    end

    -- every second: ask about new markers; pickups and drops of this player; this client's own loot
    function M.clientTick()
        if ctx.hostSession() == "" then arrivedAt = nil; return end
        arrivedAt = arrivedAt or os.clock()
        local ch = ctx.clientChannel()
        local now = os.clock()
        if ch then
            for _, mk in ipairs(FindAllOf("PDCoopItemMarker_C") or {}) do
                if valid(mk) then
                    local name = mk:GetFullName()
                    if not mirrorByMarker[name] and not ignored[name] and now - (asked[name] or -100) > 5 then
                        asked[name] = now
                        pcall(function() ch:ServerSendRef(mk, "WHOIS") end)
                    end
                end
            end
        end
        local myPawn = nil
        pcall(function() myPawn = ctx.localController().Pawn end)
        local myLoc = valid(myPawn) and myPawn:K2_GetActorLocation() or nil
        -- 1) local items that left the world while their marker is still there were picked up (or used) here
        for id, m in pairs(mirror) do
            -- the same full name too: a destroyed and collected actor's slot can hold another object later
            local gone = not (valid(m.actor) and m.actor:GetFullName() == m.actorName)
            local grabbed = false
            if not gone then
                local ok, still = pcall(function()
                    return m.actor:K2_GetActorContext() == 0 and not m.actor.bHidden and valid(m.actor.Instance)
                        and m.actor.Instance:GetFullName() == m.inst
                end)
                gone = not (ok and still)
                -- a local fixture taking the item (the garage gas pump takes its handle) attaches it: not a pickup
                pcall(function() grabbed = valid(m.actor:GetAttachParentActor()) end)
                if grabbed then gone = true end
                if not gone then
                    local l = m.actor:K2_GetActorLocation()
                    m.x, m.y, m.z = l.X, l.Y, l.Z
                end
            end
            if gone then
                forget(id)
                -- only an item that left the world next to this player, without being attached to something, was
                -- picked up here (exp38: fixtures took mirrors far away and the host lost its items)
                local near = myLoc and ctx.dist({ X = m.x, Y = m.y, Z = m.z }, myLoc) < 500
                if near and not grabbed then
                    ctx.sendCommand("PICKUP," .. id)
                    log("ITEMSYNC mirror %s left the world next to this player: PICKUP sent", id)
                else
                    ignored[m.markerName] = true
                    log("ITEMSYNC mirror %s left the world (near=%s, attached=%s): not a pickup", id, tostring(near), tostring(grabbed))
                end
            end
        end
        -- 2) local world items that are not the host's: dropped by this player (near it), or this client's own loot
        local purged, dropped = 0, 0
        for _, e in ipairs(M.scan()) do
            local name = e.actor:GetFullName()
            if not mirrorByActor[name] then
                local near = myLoc and (math.abs(e.x - myLoc.X) + math.abs(e.y - myLoc.Y) < 400)
                if near and now - arrivedAt > 10 then
                    ctx.sendCommand("DROP," .. e.arch .. "," .. fmtXf(e) .. "," .. e.state)
                    dropped = dropped + 1
                else
                    purged = purged + 1
                end
                local inst = instanceOf(e.actor)
                if inst then pcall(function() inst:Remove(true) end) end
            end
        end
        if purged + dropped > 0 then log("ITEMSYNC client removed %d local items, sent %d drops", purged, dropped) end
    end

    function M.reset()
        for id in pairs(mirror) do mirror[id] = nil end
        mirrorByActor, mirrorByMarker, asked, ignored, arrivedAt = {}, {}, {}, {}, nil
        host.known, host.byMarker = {}, {}
    end

    return M
end
