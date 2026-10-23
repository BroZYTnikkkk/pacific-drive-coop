-- PDCoopNet worlddoors: doors of the zone (BP_Door_*: shops, cabins, gas stations) are the host's.
--
-- The doors reach player 2 through worldrep (engine replication) but their state does not: the door Blueprints
-- keep it in plain variables (CurrentState, the door mesh's rotation) and each game randomizes it at BeginPlay
-- (RandomizeDoorState), so the same door could be open for one player and closed for the other, and the collision
-- that counts is the host's (player 2's character moves on the host).
--   host:     a door whose state may have changed (its open/close animation finished, its state was set, its lock
--             opened: hooked events) is compared with what was sent, changes go to player 2; every 10 s all doors are
--             compared as well; everything goes to a new set of clients.
--   player 2: applies the host's state to the same door (class + position, both on the host's spot after the
--             worldrep placement fixes); its own E on a door runs the door locally and is sent to the host, which
--             runs the same interaction on its door (exp108: the interact event with the door's Highlight and no
--             data opens/closes it on the host).
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local EV = ctx.Events
    local M = {}
    local INTERACT = "BndEvt__Highlight_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature"
    -- every zone door is one of these two Blueprints or a child of one; both declare the events below
    local ROOTS = { "BP_Door_Single_C", "BP_Door_Sliding_Single_C" }
    local CHANGED = { "AnimTimeline__FinishedFunc", "Set Door from State", "OnLockOpened_Event_0" }
    local rootPath = {}         -- root class name -> its path
    local doors = {}            -- discovered door actors (this machine): list
    local dirty = {}            -- host: door full name -> true (an event said its state may have changed)
    local ticks = 0
    local lastSent = {}         -- host: door full name -> state text
    local sentKey = ""
    local desired = {}          -- client: class -> list of { x, y, z, text, st, rel = {lx,ly,lz,p,yw,r} }
    local quietUntil = {}       -- client: door full name -> os.clock() until which the host's state is not applied
    local lastNewAt = 0         -- client: when the host last told of a door not known before

    local function isDoor(a, c)
        if c:sub(1, 7) ~= "BP_Door" then return false end
        local ok, mesh = pcall(function() return a.SM_DoorMesh end)
        return ok and valid(mesh)
    end

    local function stateText(d)
        local mesh = d.SM_DoorMesh
        local l, r = mesh.RelativeLocation, mesh.RelativeRotation
        local st = 0
        pcall(function() st = d.CurrentState end)
        return string.format("%d,%.0f,%.0f,%.0f,%.1f,%.1f,%.1f", st, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll)
    end

    -- the client's E on a replicated door: run by the host too. Replicated doors and the client's own copies of
    -- the host's level-attached ones alike: the host finds its door by class and place.
    local function onClientInteract(selfp)
        if ctx.role() ~= "client" or not ctx.enabled() then return end
        local d = selfp:get()
        if not valid(d) then return end
        local l = d:K2_GetActorLocation()
        local c = d:GetClass():GetFName():ToString()
        quietUntil[d:GetFullName()] = os.clock() + 3
        ctx.sendCommand(string.format("DOOR,%s,%.0f,%.0f,%.0f", c, l.X, l.Y, l.Z))
        log("DOORS player 2 used %s at %.0f,%.0f,%.0f: sent to the host", c, l.X, l.Y, l.Z)
    end
    local function onHostChanged(selfp)
        local ok, name = pcall(function() return selfp:get():GetFullName() end)
        if ok and name then dirty[name] = true end
    end
    local function hookRoots()
        for _, path in pairs(rootPath) do
            if ctx.role() == "client" then
                EV.hookFunction(path .. ":" .. INTERACT, onClientInteract)
            else
                for _, fn in ipairs(CHANGED) do EV.hookFunction(path .. ":" .. fn, onHostChanged) end
            end
        end
    end

    -- every 5 s: the doors of both root classes (children included), hooks in place (a new zone loads the classes
    -- again)
    function M.discover()
        if not ctx.enabled() then return end
        local found = {}
        for _, root in ipairs(ROOTS) do
            for _, a in ipairs(FindAllOf(root) or {}) do
                if valid(a) and isDoor(a, a:GetClass():GetFName():ToString()) then
                    found[#found + 1] = a
                    if not rootPath[root] then
                        local cls = a:GetClass()
                        for _ = 1, 6 do
                            if not (cls and cls:IsValid()) then break end
                            if cls:GetFName():ToString() == root then rootPath[root] = cls:GetFullName():match("%s(%S+)$"); break end
                            cls = cls:GetSuperStruct()
                        end
                    end
                end
            end
        end
        doors = found
        hookRoots()
    end

    local function remoteKey()
        local keys = {}
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() then keys[#keys + 1] = pc:GetFullName() end
        end
        table.sort(keys)
        return table.concat(keys, ";")
    end

    -- host, every second: the doors an event marked, all of them every 10 s
    function M.hostTick()
        if not ctx.enabled() then return end
        local key = remoteKey()
        if key == "" then sentKey = ""; dirty = {}; return end
        local fresh = key ~= sentKey
        sentKey = key
        ticks = ticks + 1
        local all = fresh or ticks % 10 == 0
        if not all and next(dirty) == nil then return end
        local marked = dirty
        dirty = {}
        local out, size = {}, 0
        local function flush()
            if #out > 0 then ctx.hostSend("DOORS|" .. table.concat(out, ";")); out, size = {}, 0 end
        end
        for _, d in ipairs(doors) do
            if valid(d) and (all or marked[d:GetFullName()]) then
                local okS, text = pcall(stateText, d)
                local name = d:GetFullName()
                if okS and (fresh or lastSent[name] ~= text) then
                    lastSent[name] = text
                    local l = d:K2_GetActorLocation()
                    local e = string.format("%s,%.0f,%.0f,%.0f,%s", d:GetClass():GetFName():ToString(), l.X, l.Y, l.Z, text)
                    if size + #e > ctx.CHAN_MAX - 200 then flush() end
                    out[#out + 1] = e; size = size + #e + 1
                end
            end
        end
        flush()
        -- after a full list: player 2 now knows every door of the host
        if fresh then ctx.hostSend("DOORSEND|" .. #doors) end
    end

    -- host: player 2 used a door
    function M.hostCommand(kind, args)
        if kind ~= "DOOR" then return false end
        local c, x, y, z = args:match("^([^,]+),(-?%d+),(-?%d+),(-?%d+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if not c then return true end
        local best, bestD = nil, 60
        for _, d in ipairs(doors) do
            if valid(d) and d:GetClass():GetFName():ToString() == c then
                local l = d:K2_GetActorLocation()
                local dist = math.abs(l.X - x) + math.abs(l.Y - y) + math.abs(l.Z - z)
                if dist < bestD then best, bestD = d, dist end
            end
        end
        if not best then log("DOORS player 2 used a %s at %d,%d,%d the host does not have", c, x, y, z); return true end
        local ok, err = pcall(function() best[INTERACT](best, best.Highlight, nil) end)
        log("DOORS player 2 used %s (%.0f uu away): %s", best:GetFName():ToString(), bestD,
            ok and "done on the host" or tostring(err))
        return true
    end

    ctx.hostMsgHandlers["DOORS"] = function(rest)
        for e in rest:gmatch("[^;]+") do
            local c, x, y, z, st, lx, ly, lz, p, yw, r = e:match(
                "^([^,]+),(-?%d+),(-?%d+),(-?%d+),(%d+),(-?%d+),(-?%d+),(-?%d+),(-?[%d.]+),(-?[%d.]+),(-?[%d.]+)$")
            if c then
                desired[c] = desired[c] or {}
                local list, entry = desired[c], nil
                x, y, z = tonumber(x), tonumber(y), tonumber(z)
                for _, v in ipairs(list) do
                    if math.abs(v.x - x) + math.abs(v.y - y) + math.abs(v.z - z) < 5 then entry = v; break end
                end
                if not entry then entry = { x = x, y = y, z = z }; list[#list + 1] = entry; lastNewAt = os.clock() end
                entry.st = tonumber(st)
                entry.rel = { tonumber(lx), tonumber(ly), tonumber(lz), tonumber(p), tonumber(yw), tonumber(r) }
                entry.logged = false
            end
        end
        -- applied at once (the client tick is only the 5 s check)
        local ok, err = pcall(M.clientTick)
        if not ok then log("DOORS apply error: %s", tostring(err)) end
    end

    local fullAt = nil          -- client: when the host's full door list was complete
    ctx.hostMsgHandlers["DOORSEND"] = function(rest)
        fullAt = os.clock()
        log("DOORS the host's %s door(s) known", tostring(rest))
    end

    -- client, when the host's states arrive and every 5 s: put each door the way the host has it. A door of the client's own (role authority:
    -- built by its own game, not replicated) that the host does not have is removed once the host has sent its
    -- full list and no new door for 20 s: its prefab was generated elsewhere on the host (exp112: 4 sliding doors
    -- 600-4700 uu from any host door). Not sooner: the host finds its doors every 5 s, and its first full list can
    -- be short (exp113: 4 doors at the join, a client door removed that the host found later).
    function M.clientTick()
        if not ctx.enabled() then return end
        local now, n, removed = os.clock(), 0, 0
        local settled = fullAt and now - fullAt > 20 and now - lastNewAt > 20
        for _, d in ipairs(doors) do
            if valid(d) then
                local c = d:GetClass():GetFName():ToString()
                local list = desired[c]
                local name = d:GetFullName()
                local gone = false
                if settled then
                    local okR, role = pcall(function() return d.Role end)
                    if okR and role == 3 then
                        local l = d:K2_GetActorLocation()
                        local known = false
                        for _, v in ipairs(list or {}) do
                            if math.abs(v.x - l.X) + math.abs(v.y - l.Y) + math.abs(v.z - l.Z) < 60 then known = true; break end
                        end
                        if not known and pcall(function() d:K2_DestroyActor() end) then
                            removed, gone = removed + 1, true
                            log("DOORS removed player 2's own %s at %.0f,%.0f,%.0f: the host has no door there", c, l.X, l.Y, l.Z)
                        end
                    end
                end
                if not gone and list and not (quietUntil[name] and quietUntil[name] > now) then
                    local l = d:K2_GetActorLocation()
                    local best, bestD = nil, 40
                    for _, v in ipairs(list) do
                        local dist = math.abs(v.x - l.X) + math.abs(v.y - l.Y) + math.abs(v.z - l.Z)
                        if dist < bestD then best, bestD = v, dist end
                    end
                    if best then
                        local okS, now_ = pcall(stateText, d)
                        local want = string.format("%d,%.0f,%.0f,%.0f,%.1f,%.1f,%.1f", best.st, best.rel[1], best.rel[2],
                            best.rel[3], best.rel[4], best.rel[5], best.rel[6])
                        -- numbers, not text: "-0.0" from the host and "0.0" here are the same (exp110: one door
                        -- was set again every second)
                        local differs = false
                        if okS then
                            local i = 0
                            for v in now_:gmatch("[^,]+") do
                                i = i + 1
                                local w = (i == 1) and best.st or best.rel[i - 1]
                                local tol = (i == 1) and 0 or ((i <= 4) and 1 or 0.5)
                                local dv = (tonumber(v) or 0) - w
                                if i >= 5 then dv = (dv + 540) % 360 - 180 end   -- angles: -180 is 180
                                if math.abs(dv) > tol then differs = true end
                            end
                        end
                        if okS and differs then
                            local ok = pcall(function()
                                pcall(function() d.AnimTimeline:Stop() end)
                                d.SM_DoorMesh:K2_SetRelativeLocationAndRotation(
                                    { X = best.rel[1], Y = best.rel[2], Z = best.rel[3] },
                                    { Pitch = best.rel[4], Yaw = best.rel[5], Roll = best.rel[6] }, false, {}, true)
                                d.CurrentState = best.st
                            end)
                            if ok then
                                n = n + 1
                                if not best.logged then
                                    best.logged = true
                                    log("DOORS %s set to the host's %s (was %s)", c, want, now_)
                                end
                            end
                        end
                    end
                end
            end
        end
        if n > 0 then log("DOORS %d door(s) set to the host's state", n) end
    end

    function M.reset() doors, lastSent, sentKey, desired, quietUntil, fullAt, lastNewAt, dirty = {}, {}, "", {}, {}, nil, 0, {} end

    return M
end
