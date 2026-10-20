-- PDCoopNet carsync: shared car trunk, car part health / fuel / battery, and player 2's inventory saved on the host.
-- Loaded by main.lua: require("carsync")(ctx); ctx carries the channel functions and helpers of main.lua.
--
-- Every machine has its own inventory system (GameInstance): its own trunk container and its own copy of the
-- car's parts (parts are not replicated). The host is the truth:
--   trunk:  host sends "TRUNK|<arch>*<n>;..." (slot order) when its trunk changes or clients change; a client
--           rebuilds its local trunk to match. A client's own changes (it took or put items) are sent as count
--           deltas "TRUNKD,<arch>*<+n|-n>;..." and applied by the host; deltas from two players merge.
--   car:    host sends "CARST|<key>=<value>;..." (part health "H", fuel "F", battery "B"); a client sets its local
--           parts to these values and keeps them there (local damage on the client is overwritten). A repair made
--           on the client (part health went up) is sent to the host as "CARUP,<key>=<value>;...". Fuel and battery
--           come only from the host (a refuel or charge done by player 2 is lost; see the notes).
--   inventory of player 2: the client has a random id (player_id.txt next to role.txt), says "HELLO,<id>" to every
--           new host session and sends "INVSAVE,<id>!<container>=<items>!..." when its inventory changes; the
--           host writes ue4ss/Mods/PDCoopNet/save_<id>.txt and sends "INVLOAD|<id>|..." back when that player
--           joins again; the client then replaces its inventory with the saved one.
-- Item state (durability, fuel in a can, charge) is not carried: items are recreated from their archetype.
return function(ctx)
    local log, valid, UEHelpers = ctx.log, ctx.valid, ctx.UEHelpers
    local M = {}
    local DIR = "ue4ss/Mods/PDCoopNet/"
    local PLAYER_CONTAINERS = { "Inventory_Player", "Inventory_PlayerHand" }

    -- ------------------------------------------------------------ containers
    local function im() return FindFirstOf("BP_InventoryManager_C") end
    local function trunk()
        local m = im()
        local t = nil
        if valid(m) then pcall(function() t = m.Inventory_Trunk end) end
        return valid(t) and t or nil
    end
    local function archOfInstance(inst)
        local a = nil
        pcall(function() a = inst.Archetype end)
        if not valid(a) then return nil end
        return ctx.archShort(a:GetFullName():match("%s(%S+)$"))
    end
    -- entries in slot order: { {arch, n}, ... } (one per non-empty slot)
    local function containerEntries(cont)
        local out = {}
        if not valid(cont) then return out end
        pcall(function()
            cont.Slots:ForEach(function(_, e)
                local slot = e:get()
                local n, arch = 0, nil
                pcall(function() n = slot.Items:GetArrayNum() end)
                if n > 0 then
                    pcall(function() arch = archOfInstance(slot.Items[1]) end)
                    if arch then out[#out + 1] = { arch, n } end
                end
            end)
        end)
        return out
    end
    local function entriesText(entries)
        local parts = {}
        for _, e in ipairs(entries) do parts[#parts + 1] = e[1] .. "*" .. e[2] end
        return table.concat(parts, ";")
    end
    local function parseEntries(text)
        local out = {}
        for arch, n in (text or ""):gmatch("([^;*]+)%*(%-?%d+)") do out[#out + 1] = { arch, tonumber(n) } end
        return out
    end
    local function countsOf(entries)
        local c = {}
        for _, e in ipairs(entries) do c[e[1]] = (c[e[1]] or 0) + e[2] end
        return c
    end
    local function countsDiff(new, old)
        local d, any = {}, false
        for k, v in pairs(new) do
            local x = v - (old[k] or 0)
            if x ~= 0 then d[#d + 1] = { k, x }; any = true end
        end
        for k, v in pairs(old) do
            if new[k] == nil then d[#d + 1] = { k, -v }; any = true end
        end
        return any and d or nil
    end
    local function addItems(cont, arch, n)
        local a = ctx.archLoad(arch)
        if not a then log("CARSYNC cannot load %s", arch); return 0 end
        local wco = UEHelpers.GetWorldContextObject()
        local added = 0
        for _ = 1, n do
            local ok = pcall(function()
                local inst = a:CreateInstance(wco, 0)
                cont:AddItem(inst, true)
            end)
            if ok then added = added + 1 end
        end
        return added
    end
    local function removeItems(cont, arch, n)
        local a = ctx.archLoad(arch)
        if not a then return 0 end
        local before = countsOf(containerEntries(cont))[arch] or 0
        pcall(function() cont:RemoveItemsOfType(a, n) end)
        local after = countsOf(containerEntries(cont))[arch] or 0
        return before - after
    end
    local function rebuild(cont, entries)
        pcall(function() cont:RemoveAllItems() end)
        for _, e in ipairs(entries) do addItems(cont, e[1], e[2]) end
    end

    -- ------------------------------------------------------------ car parts
    -- key = <kind><class>@<x>,<y>,<z>: the part's position in the car's frame, 50 uu grid (front wheels steer)
    local function carComponents(car)
        local out = {}
        if not valid(car) then return out end
        local carName = car:GetFullName()
        local kml = UEHelpers.GetKismetMathLibrary()
        local xf = car:GetTransform()
        local function top(a)
            local t = a
            for _ = 1, 5 do
                local p = nil
                pcall(function() p = t:GetAttachParentActor() end)
                if not valid(p) then break end
                t = p
            end
            return t
        end
        for _, spec in ipairs({ { "H", "BP_HealthComponent_C" }, { "F", "BP_FuelableComponent_C" }, { "B", "BP_BatteryComponent_C" } }) do
            for _, c in ipairs(FindAllOf(spec[2]) or {}) do
                local o = nil
                pcall(function() o = c:GetOwner() end)
                -- the charge port's battery component is a pass-through of the charger, not a battery
                if valid(c) and valid(o) and top(o):GetFullName() == carName
                    and not c:GetClass():GetFName():ToString():find("ChargePort", 1, true) then
                    local rel = kml:InverseTransformLocation(xf, o:K2_GetActorLocation())
                    local key = string.format("%s%s@%d,%d,%d", spec[1], o:GetClass():GetFName():ToString(),
                        math.floor(rel.X / 50 + 0.5), math.floor(rel.Y / 50 + 0.5), math.floor(rel.Z / 50 + 0.5))
                    local n = 1
                    while out[key .. (n > 1 and ("#" .. n) or "")] do n = n + 1 end
                    out[key .. (n > 1 and ("#" .. n) or "")] = { kind = spec[1], comp = c }
                end
            end
        end
        return out
    end
    local function compValue(e)
        local v = nil
        if e.kind == "H" then
            pcall(function() v = e.comp:HC_GetHealth() end)
        elseif e.kind == "F" then
            local a = {}
            pcall(function() e.comp:GetFuelStatus(a, {}, {}, {}, {}, {}, {}) end)
            v = a.Fuel
        else
            local a = {}
            pcall(function() e.comp:GetBatteryStatus(a, {}, {}, {}, {}) end)
            v = a.BATTERY or a.Battery
        end
        return type(v) == "number" and v or nil
    end
    local function setCompValue(e, v)
        if e.kind == "H" then return pcall(function() e.comp:SetHealth(v) end)
        elseif e.kind == "F" then return pcall(function() e.comp["Set Fuel"](e.comp, v) end)
        else return pcall(function() e.comp["Set Battery"](e.comp, v) end) end
    end
    local function carValues(car)
        local vals, comps = {}, carComponents(car)
        for k, e in pairs(comps) do vals[k] = compValue(e) end
        return vals, comps
    end
    local function valuesText(vals, onlyKeys)
        local parts = {}
        for k, v in pairs(vals) do
            if v and (not onlyKeys or onlyKeys[k]) then parts[#parts + 1] = string.format("%s=%.1f", k, v) end
        end
        table.sort(parts)
        return table.concat(parts, ";")
    end
    local function parseValues(text)
        local out = {}
        for k, v in (text or ""):gmatch("([^;=]+)=(%-?[%d.]+)") do out[k] = tonumber(v) end
        return out
    end

    -- ------------------------------------------------------------ host
    local host = { clientsKey = "", trunkText = nil, car = {}, clientIds = {} }
    local function clientsKey()
        local keys = {}
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() then keys[#keys + 1] = pc:GetFullName() end
        end
        table.sort(keys)
        return table.concat(keys, ",")
    end

    local function savePath(id) return DIR .. "save_" .. id .. ".txt" end
    local function sanitizeId(id) return (id or ""):gsub("[^%w]", ""):sub(1, 32) end

    function M.hostTick()
        local ck = clientsKey()
        if ck == "" then host.clientsKey = ""; return end
        local fresh = ck ~= host.clientsKey
        host.clientsKey = ck
        -- trunk
        local t = trunk()
        if t then
            local text = entriesText(containerEntries(t))
            if fresh or text ~= host.trunkText then
                host.trunkText = text
                ctx.hostSend("TRUNK|" .. text)
                log("CARSYNC host trunk sent (%s): %s", fresh and "new clients" or "changed", text == "" and "empty" or text)
            end
        end
        -- car parts
        local car = ctx.playerCar()
        if valid(car) then
            local vals = carValues(car)
            local changed = {}
            local n = 0
            for k, v in pairs(vals) do
                if fresh or host.car[k] == nil or math.abs(host.car[k] - v) >= 0.5 then changed[k] = true; n = n + 1 end
            end
            if n > 0 then
                for k in pairs(changed) do host.car[k] = vals[k] end
                local text = valuesText(vals, changed)
                if #text < ctx.CHAN_MAX - 50 then ctx.hostSend("CARST|" .. text) end
                if fresh or n >= 3 then log("CARSYNC host car state sent: %d value(s)%s", n, fresh and " (full)" or "") end
            end
        end
    end

    -- client commands; returns true if handled
    function M.hostCommand(kind, args, pc)
        if kind == "TRUNKD" then
            local t = trunk()
            if not t then log("CARSYNC TRUNKD: host has no trunk"); return true end
            for _, e in ipairs(parseEntries(args)) do
                if e[2] > 0 then
                    local added = addItems(t, e[1], e[2])
                    log("CARSYNC TRUNKD from %s: +%d %s (added %d)", ctx.objName(pc), e[2], e[1], added)
                elseif e[2] < 0 then
                    local removed = removeItems(t, e[1], -e[2])
                    log("CARSYNC TRUNKD from %s: %d %s (removed %d%s)", ctx.objName(pc), e[2], e[1], removed,
                        removed < -e[2] and ", NOT ENOUGH ON THE HOST: the item was duplicated" or "")
                end
            end
            return true
        elseif kind == "CARUP" then
            local car = ctx.playerCar()
            local comps = carComponents(car)
            for k, v in pairs(parseValues(args)) do
                local e = comps[k]
                if e then
                    local ok = setCompValue(e, v)
                    host.car[k] = nil   -- resend
                    log("CARSYNC CARUP from %s: %s -> %.1f ok=%s", ctx.objName(pc), k, v, tostring(ok))
                else
                    log("CARSYNC CARUP from %s: unknown part %s", ctx.objName(pc), k)
                end
            end
            return true
        elseif kind == "HELLO" then
            local id = sanitizeId(args)
            if id == "" then return true end
            host.clientIds[pc:GetFullName()] = id
            local f = io.open(savePath(id), "r")
            if f then
                local text = f:read("*a") or ""
                f:close()
                text = text:gsub("%s+$", "")
                ctx.hostSend("INVLOAD|" .. id .. "|" .. text)
                log("CARSYNC HELLO %s from %s: saved inventory sent (%d bytes)", id, ctx.objName(pc), #text)
            else
                ctx.hostSend("INVLOAD|" .. id .. "|NONE")
                log("CARSYNC HELLO %s from %s: no saved inventory yet", id, ctx.objName(pc))
            end
            return true
        elseif kind == "INVSAVE" then
            local id, rest = args:match("^([%w]+)!(.*)$")
            id = sanitizeId(id)
            if id == "" then return true end
            local f = io.open(savePath(id), "w")
            if f then
                f:write(rest)
                f:close()
                log("CARSYNC INVSAVE %s from %s: %d bytes saved", id, ctx.objName(pc), #rest)
            else
                log("CARSYNC INVSAVE %s: cannot write %s", id, savePath(id))
            end
            return true
        end
        return false
    end

    -- ------------------------------------------------------------ client
    local cl = { trunkActive = false, trunkBase = {}, carHost = {}, carActive = false,
                 id = nil, helloFor = nil, invLoaded = false, invText = nil, invSentTick = -100 }

    local function playerId()
        if cl.id then return cl.id end
        local f = io.open(DIR .. "player_id.txt", "r")
        if f then cl.id = sanitizeId(f:read("*l")); f:close() end
        if not cl.id or cl.id == "" then
            math.randomseed(os.time() + math.floor(os.clock() * 1000))
            local t = {}
            for i = 1, 16 do t[i] = string.format("%x", math.random(0, 15)) end
            cl.id = table.concat(t)
            f = io.open(DIR .. "player_id.txt", "w")
            if f then f:write(cl.id .. "\n"); f:close() end
            log("CARSYNC new player id %s", cl.id)
        end
        return cl.id
    end

    local function trunkDeltaText(t)
        local now = countsOf(containerEntries(t))
        local d = countsDiff(now, cl.trunkBase)
        if not d then return nil, now end
        local parts = {}
        for _, e in ipairs(d) do parts[#parts + 1] = e[1] .. "*" .. string.format("%d", e[2]) end
        return table.concat(parts, ";"), now
    end

    ctx.hostMsgHandlers["TRUNK"] = function(rest)
        local t = trunk()
        if not t then return end
        -- a change made here that the host has not seen yet: send it first, keep the local trunk
        if cl.trunkActive then
            local d, now = trunkDeltaText(t)
            if d then
                ctx.sendCommand("TRUNKD," .. d)
                cl.trunkBase = now
                log("CARSYNC client trunk: local change sent before applying the host's list (%s)", d)
                return
            end
        end
        local entries = parseEntries(rest)
        local localCounts = countsOf(containerEntries(t))
        if countsDiff(countsOf(entries), localCounts) then
            rebuild(t, entries)
            log("CARSYNC client trunk rebuilt from host: %s", rest == "" and "empty" or rest)
        end
        cl.trunkBase = countsOf(containerEntries(t))
        cl.trunkActive = true
    end

    ctx.hostMsgHandlers["CARST"] = function(rest)
        local vals = parseValues(rest)
        local car = ctx.playerCar()
        local comps = carComponents(car)
        local set, missing = 0, 0
        for k, v in pairs(vals) do
            cl.carHost[k] = v
            local e = comps[k]
            if e then
                local cur = compValue(e)
                if not cur or math.abs(cur - v) >= 0.5 then setCompValue(e, v); set = set + 1 end
            else
                missing = missing + 1
            end
        end
        cl.carActive = true
        if set > 0 or missing > 0 then log("CARSYNC client car: %d value(s) set from host, %d part(s) not found here", set, missing) end
    end

    ctx.hostMsgHandlers["INVLOAD"] = function(rest)
        local id, text = rest:match("^([%w]+)|(.*)$")
        if id ~= playerId() then return end
        cl.invLoaded = true
        if text == "NONE" then log("CARSYNC no saved inventory on the host: keeping the current one"); return end
        local m = im()
        local n = 0
        for cname, items in (text .. "!"):gmatch("([%w_]+)=([^!]*)!") do
            local cont = nil
            pcall(function() cont = m[cname] end)
            if valid(cont) then
                local entries = parseEntries(items)
                rebuild(cont, entries)
                n = n + #entries
            end
        end
        cl.invText = nil
        log("CARSYNC inventory restored from the host save: %d stack(s)", n)
    end

    local function inventoryText()
        local m = im()
        if not valid(m) then return nil end
        local parts = {}
        for _, cname in ipairs(PLAYER_CONTAINERS) do
            local cont = nil
            pcall(function() cont = m[cname] end)
            if valid(cont) then parts[#parts + 1] = cname .. "=" .. entriesText(containerEntries(cont)) end
        end
        return table.concat(parts, "!")
    end

    function M.clientTick(hostSession, fastTick)
        -- hello once per host session (a new host PlayerState after a map change or rejoin)
        if hostSession ~= "" and hostSession ~= cl.helloFor then
            cl.helloFor = hostSession
            cl.invLoaded = false
            cl.trunkActive = false
            ctx.sendCommand("HELLO," .. playerId())
            log("CARSYNC HELLO sent as %s", playerId())
        end
        -- trunk: local changes -> host
        local t = trunk()
        if cl.trunkActive and t then
            local d, now = trunkDeltaText(t)
            if d then
                ctx.sendCommand("TRUNKD," .. d)
                cl.trunkBase = now
                log("CARSYNC client trunk change sent: %s", d)
            end
        end
        -- car: keep the host's values; increases made here go to the host
        if cl.carActive then
            local car = ctx.playerCar()
            local comps = carComponents(car)
            local ups = {}
            for k, hv in pairs(cl.carHost) do
                local e = comps[k]
                if e then
                    local cur = compValue(e)
                    -- only part health: fuel and battery also rise on their own on both machines (the garage
                    -- charger, a pump), sending those would add them twice and run away
                    if cur and e.kind == "H" and cur > hv + 1.0 then
                        ups[#ups + 1] = string.format("%s=%.1f", k, cur)
                        cl.carHost[k] = cur
                    elseif cur and cur < hv - 0.5 then
                        setCompValue(e, hv)
                    end
                end
            end
            if #ups > 0 then
                ctx.sendCommand("CARUP," .. table.concat(ups, ";"))
                log("CARSYNC client car increase sent: %s", table.concat(ups, ";"))
            end
        end
        -- inventory: save on the host when it changes (at most every 5 s), after the saved one was loaded
        if cl.invLoaded and fastTick - cl.invSentTick >= 25 then
            local text = inventoryText()
            if text and text ~= cl.invText then
                cl.invText = text
                cl.invSentTick = fastTick
                ctx.sendCommand("INVSAVE," .. playerId() .. "!" .. text)
                log("CARSYNC inventory sent to the host for saving (%d bytes)", #text)
            end
        end
    end

    return M
end
