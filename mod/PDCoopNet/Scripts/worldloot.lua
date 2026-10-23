-- PDCoopNet worldloot: lootable containers of the zone (BP_Lootable_*: crates, backpacks, cabinets, fridges...) hold
-- the host's items.
--
-- The containers reach player 2 through worldrep, but each game fills a container itself when it is first opened
-- ("Populate Container" rolls the decision tree), so both players found different loot in the same crate, and items
-- taken by one were still there for the other. The host is the truth, as for the car trunk (carsync.lua):
--   player 2 opens a container: its own roll is emptied at once and "LOOTOPEN,<class>,<x>,<y>,<z>" goes to the
--             host; the host fills its container if nobody had (the same roll the game does), and from then on sends
--             "LOOTC|<class>,<x>,<y>,<z>|<key>*<n>;..." whenever that container changes;
--   player 2 rebuilds its container from the list; what it takes or puts in goes to the host as count deltas
--             "LOOTD,<class>,<x>,<y>,<z>,<key>*<+n|-n>;..." (the trunk's merge rules: deltas of both players add up).
-- A container is found on the other machine by class and place (both on the host's spot after worldrep).
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local CS = ctx.CarSync
    local EV = ctx.Events
    local M = {}
    local POPULATE, INTERACTED = "Populate Container", "OnInteractedWith"
    local declaring = nil                -- path of the class that declares the hooked functions, once found
    local host = { watched = {} }        -- name -> { lt, text }
    local cl = { open = {} }             -- client: name -> { lt, base (counts), pending = bool }

    local function isLootable(c) return c:sub(1, 12) == "BP_Lootable_" end
    local function lootKey(lt)
        local l = lt:K2_GetActorLocation()
        return string.format("%s,%.0f,%.0f,%.0f", lt:GetClass():GetFName():ToString(), l.X, l.Y, l.Z)
    end
    local function container(lt)
        local c = nil
        pcall(function() c = lt.InventoryContainer end)
        return valid(c) and c or nil
    end
    local function findLootable(c, x, y, z)
        local best, bestD = nil, 60
        for _, a in ipairs(FindAllOf(c) or {}) do
            if valid(a) then
                local l = a:K2_GetActorLocation()
                local d = math.abs(l.X - x) + math.abs(l.Y - y) + math.abs(l.Z - z)
                if d < bestD then best, bestD = a, d end
            end
        end
        return best
    end
    local function parseKey(args)
        local c, x, y, z, rest = args:match("^([^,]+),(-?%d+),(-?%d+),(-?%d+),?(.*)$")
        if not c then return nil end
        return c, tonumber(x), tonumber(y), tonumber(z), rest
    end

    -- hooks on the class that declares the functions (BP_Lootable_Base_C for every lootable)
    local function hookDeclaring()
        -- player 2's own roll is emptied right away: the host's items come in a moment
        local okP = EV.hookFunction(declaring .. ":" .. POPULATE, function(selfp)
                if ctx.role() ~= "client" or not ctx.enabled() then return end
                local lt = selfp:get()
                local cont = valid(lt) and container(lt)
                if cont then pcall(function() cont:RemoveAllItems() end) end
            end)
        local okI = EV.hookFunction(declaring .. ":" .. INTERACTED, function(selfp)
                if ctx.role() ~= "client" or not ctx.enabled() then return end
                local lt = selfp:get()
                if not valid(lt) then return end
                local key = lootKey(lt)
                cl.open[lt:GetFullName()] = { lt = lt, key = key, pending = true }
                local cont = container(lt)
                if cont then pcall(function() cont:RemoveAllItems() end) end
                ctx.sendCommand("LOOTOPEN," .. key)
                log("LOOT player 2 opened %s: asked the host", key)
            end)
        return okP and okI
    end
    local function findDeclaring(cls)
        for _ = 1, 6 do
            if not (cls and cls:IsValid()) then return nil end
            local path = cls:GetFullName():match("%s(%S+)$")
            local f = StaticFindObject(path .. ":" .. INTERACTED)
            if f and f:IsValid() then return path end
            cls = cls:GetSuperStruct()
        end
    end

    -- every 5 s: the hooks are in place (the class is loaded again in a new zone); the zone's actors are searched
    -- for a lootable only until its base class was found once
    function M.discover()
        if not ctx.enabled() then return end
        if declaring then hookDeclaring(); return end
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            if valid(a) and isLootable(a:GetClass():GetFName():ToString()) then
                declaring = findDeclaring(a:GetClass())
                if declaring then
                    log("LOOT lootables are %s", declaring:match("[^.]+$"))
                    hookDeclaring()
                end
                return
            end
        end
    end

    -- host: send a watched container's list when it changed (or to a new set of clients: everything watched)
    local function hostSendOne(name, w, force)
        if not valid(w.lt) then host.watched[name] = nil; return end
        local cont = container(w.lt)
        if not cont then return end
        -- only when items went in or out (or the last list is void: the host answers every LOOTD)
        if not (EV.takeDirty(cont) or force or w.text == nil) then return end
        local text = CS.entriesText(CS.containerEntries(cont))
        if force or text ~= w.text then
            w.text = text
            ctx.hostSend("LOOTC|" .. w.key .. "|" .. text)
            log("LOOT host %s: %s", w.key, text == "" and "empty" or text)
        end
    end
    function M.hostTick()
        if not ctx.enabled() then return end
        for name, w in pairs(host.watched) do hostSendOne(name, w, false) end
    end

    function M.hostCommand(kind, args)
        if kind ~= "LOOTOPEN" and kind ~= "LOOTD" then return false end
        local c, x, y, z, rest = parseKey(args)
        if not c then return true end
        local lt = findLootable(c, x, y, z)
        if not lt then log("LOOT %s from player 2: the host has no %s at %d,%d,%d", kind, c, x, y, z); return true end
        local name = lt:GetFullName()
        local w = host.watched[name]
        if not w then w = { lt = lt, key = lootKey(lt) }; host.watched[name] = w end
        if kind == "LOOTOPEN" then
            local populated = false
            pcall(function() populated = lt["Container Populated"] end)
            if not populated then
                local ok, err = pcall(function() lt[POPULATE](lt) end)
                log("LOOT host filled %s for player 2: %s", w.key, ok and "ok" or tostring(err))
            end
            hostSendOne(name, w, true)
        else
            local cont = container(lt)
            if not cont then return true end
            w.text = nil         -- the answer goes out also when the change did nothing here
            for _, e in ipairs(CS.parseEntries(rest)) do
                if e[2] > 0 then
                    CS.addItems(cont, e[1], e[2])
                elseif e[2] < 0 then
                    local removed = CS.removeItems(cont, e[1], -e[2])
                    if removed < -e[2] then log("LOOT %s: player 2 took %d %s, the host had %d", w.key, -e[2], e[1], removed) end
                end
            end
            log("LOOT player 2 changed %s: %s", w.key, rest)
        end
        return true
    end

    -- client
    local function deltaText(o)
        local cont = container(o.lt)
        if not cont then return nil end
        local now = CS.countsOf(CS.containerEntries(cont))
        local d = CS.countsDiff(now, o.base or {})
        if not d then return nil, now end
        local parts = {}
        for _, e in ipairs(d) do parts[#parts + 1] = e[1] .. "*" .. string.format("%d", e[2]) end
        return table.concat(parts, ";"), now
    end
    ctx.hostMsgHandlers["LOOTC"] = function(rest)
        local key, text = rest:match("^([^|]+)|(.*)$")
        if not key then return end
        local c, x, y, z = parseKey(key)
        local lt = c and findLootable(c, x, y, z)
        if not lt then return end
        local cont = container(lt)
        if not cont then return end
        local name = lt:GetFullName()
        local o = cl.open[name]
        if not o then o = { lt = lt, key = key }; cl.open[name] = o end
        -- a change made here that the host has not seen yet goes first
        if not o.pending and o.base then
            local d, now = deltaText(o)
            if d then
                ctx.sendCommand("LOOTD," .. key .. "," .. d)
                o.base = now
                return
            end
        end
        local entries = CS.parseEntries(text)
        if CS.countsDiff(CS.countsOf(entries), CS.countsOf(CS.containerEntries(cont))) then CS.rebuild(cont, entries) end
        o.base = CS.countsOf(CS.containerEntries(cont))
        o.pending = false
        log("LOOT %s from the host: %s", key, text == "" and "empty" or text)
    end
    function M.clientTick()
        if not ctx.enabled() then return end
        for name, o in pairs(cl.open) do
            if not valid(o.lt) then cl.open[name] = nil
            elseif not o.pending and o.base and container(o.lt) and EV.takeDirty(container(o.lt)) then
                local d, now = deltaText(o)
                if d then
                    ctx.sendCommand("LOOTD," .. o.key .. "," .. d)
                    o.base = now
                    log("LOOT player 2 changed %s: %s", o.key, d)
                end
            end
        end
    end

    function M.reset() host.watched, cl.open = {}, {} end

    return M
end
