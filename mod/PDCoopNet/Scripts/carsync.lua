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
--           follow the host; only player 2's own actions count: the game's TransferFuel (fuel can, pump handle,
--           siphon) and DoCharge (battery charger tool) are hooked on the client. In a second in which such a call
--           touched the car, the actual change of every fuel (or battery) value of the car is sent as
--           "CARADD,<key>=<+/-amount>;..." (the gas cap passes fuel on to the tank, so the amount the call reports
--           is not what the car got). Background changes (garage charger, consumption) are computed by the host.
--   inventory of player 2: the client has a random id (player_id.txt next to role.txt), says "HELLO,<id>" to every
--           new host session and sends "INVSAVE,<id>!<container>=<items>!..." when its inventory changes; the
--           host writes ue4ss/Mods/PDCoopNet/save_<id>.txt and sends "INVLOAD|<id>|..." back when that player
--           joins again; the client then replaces its inventory with the saved one.
-- Items carry their state (fuel, charge, durability, health; itemstate.lua): an entry key is "<arch>" or
-- "<arch>@<state>", so two cans with different fuel are different keys.
return function(ctx)
    local log, valid, UEHelpers = ctx.log, ctx.valid, ctx.UEHelpers
    local IS = ctx.ItemState
    local EV = ctx.Events       -- takeDirty(container): the container changed since the last call
    local on = ctx.feature      -- on("trunk"), on("carstate"), on("refuel"), on("invsave")
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
    local function keyOf(inst)
        local arch = archOfInstance(inst)
        if not arch then return nil end
        local st = IS.read(inst)
        return st ~= "" and (arch .. "@" .. st) or arch
    end
    local function splitKey(key)
        local arch, st = key:match("^([^@]+)@?(.*)$")
        return arch, st or ""
    end
    -- calls fn(instance) for every item of the container
    local function eachItem(cont, fn)
        pcall(function()
            cont.Slots:ForEach(function(_, e)
                local slot = e:get()
                pcall(function()
                    slot.Items:ForEach(function(_, it)
                        local inst = it:get()
                        if valid(inst) then fn(inst) end
                    end)
                end)
            end)
        end)
    end
    -- entries in slot order: { {key, n}, ... } (items of one slot with the same key are one entry)
    local function containerEntries(cont)
        local out = {}
        if not valid(cont) then return out end
        pcall(function()
            cont.Slots:ForEach(function(_, e)
                local slot = e:get()
                local last = nil
                pcall(function()
                    slot.Items:ForEach(function(_, it)
                        local key = keyOf(it:get())
                        if key then
                            if last and last[1] == key then last[2] = last[2] + 1
                            else last = { key, 1 }; out[#out + 1] = last end
                        end
                    end)
                end)
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
    local function addItems(cont, key, n)
        local arch, st = splitKey(key)
        local a = ctx.archLoad(arch)
        if not a then log("CARSYNC cannot load %s", arch); return 0 end
        local wco = UEHelpers.GetWorldContextObject()
        local added = 0
        for _ = 1, n do
            local ok = pcall(function()
                local inst = a:CreateInstance(wco, 0)
                if st ~= "" or IS.isStateful(inst) then IS.write(inst, st, arch) end
                cont:AddItem(inst, true)
            end)
            if ok then added = added + 1 end
        end
        return added
    end
    -- removes n items with this key; if fewer match exactly, items of the same type with another state
    -- (the state changed on the host meanwhile) are taken instead
    local function removeItems(cont, key, n)
        local arch = splitKey(key)
        local exact, other = {}, {}
        eachItem(cont, function(inst)
            if archOfInstance(inst) == arch then
                if keyOf(inst) == key then exact[#exact + 1] = inst else other[#other + 1] = inst end
            end
        end)
        local removed = 0
        for _, list in ipairs({ exact, other }) do
            for _, inst in ipairs(list) do
                if removed >= n then break end
                if pcall(function() cont:RemoveItem(inst) end) then removed = removed + 1 end
            end
        end
        if #exact < n and removed > #exact then
            log("CARSYNC removed %d %s with another state than %s", removed - #exact, arch, key)
        end
        return removed
    end
    local function rebuild(cont, entries)
        pcall(function() cont:RemoveAllItems() end)
        for _, e in ipairs(entries) do addItems(cont, e[1], e[2]) end
    end

    M.keyOf = function(inst) return keyOf(inst) end
    -- the container helpers of the trunk sync, for other shared containers (worldloot.lua)
    M.containerEntries, M.entriesText, M.parseEntries = containerEntries, entriesText, parseEntries
    M.countsOf, M.countsDiff, M.rebuild = countsOf, countsDiff, rebuild
    M.addItems, M.removeItems = addItems, removeItems
    -- adds "<key>*<n>;..." to a container; returns the number of items added
    M.addEntries = function(cont, text)
        local n = 0
        for _, e in ipairs(parseEntries(text)) do n = n + addItems(cont, e[1], e[2]) end
        return n
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
                -- (classes only after the validity checks: GetClass on a dead object crashed the host, exp67)
                if valid(c) and valid(o) and top(o):GetFullName() == carName
                    and not (c:GetClass():GetFName():ToString() .. "|" .. o:GetClass():GetFName():ToString()):find("ChargePort", 1, true) then
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
            if v and (not onlyKeys or onlyKeys[k]) then parts[#parts + 1] = string.format("%s=%.2f", k, v) end
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
        -- trunk: when items went in or out (or the last list is void: the host answers every TRUNKD); every 5 s
        -- also a check for item state changes (fuel, durability), which move no item (exp135)
        local t = on("trunk") and trunk() or nil
        host.trunkTicks = (host.trunkTicks or 0) + 1
        if t and (EV.takeDirty(t) or fresh or host.trunkText == nil or host.trunkTicks % 5 == 0) then
            local text = entriesText(containerEntries(t))
            if fresh or text ~= host.trunkText then
                host.trunkText = text
                ctx.hostSend("TRUNK|" .. text)
                log("CARSYNC host trunk sent (%s): %s", fresh and "new clients" or "changed", text == "" and "empty" or text)
            end
        end
        -- car parts
        local car = on("carstate") and ctx.playerCar() or nil
        if valid(car) then
            local vals = carValues(car)
            local changed = {}
            local n = 0
            for k, v in pairs(vals) do
                if fresh or host.car[k] == nil or math.abs(host.car[k] - v) >= (k:sub(1, 1) == "H" and 0.5 or 0.1) then changed[k] = true; n = n + 1 end
            end
            if n > 0 then
                -- always the full state, and only the newest one waits in the queue (fuel drains every second;
                -- queued partial updates made the client lag 5-8 s behind)
                for k in pairs(vals) do host.car[k] = vals[k] end
                local text = valuesText(vals)
                if #text < ctx.CHAN_MAX - 50 then ctx.hostSendLatest("CARST|" .. text) end
                if fresh or n >= 3 then log("CARSYNC host car state sent: %d value(s)%s", n, fresh and " (full)" or "") end
            end
        end
    end

    -- client commands; returns true if handled
    function M.hostCommand(kind, args, pc)
        if kind == "TRUNKD" then
            local t = trunk()
            if not t then log("CARSYNC TRUNKD: host has no trunk"); return true end
            -- the host answers every change with its list, also when the change did nothing here (an item the
            -- host had already taken): the client's trunk then follows the host again
            host.trunkText = nil
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
        elseif kind == "CARADD" then
            local car = ctx.playerCar()
            local comps = carComponents(car)
            for k, d in pairs(parseValues(args)) do
                local e = comps[k]
                local cur = e and compValue(e)
                if e and cur then
                    local max = nil
                    if e.kind == "F" then local b = {}; pcall(function() e.comp:GetFuelStatus({}, b, {}, {}, {}, {}, {}) end); max = b["Fuel Capacity"]
                    elseif e.kind == "B" then local b = {}; pcall(function() e.comp:GetBatteryStatus({}, b, {}, {}, {}) end); max = b["Battery Capacity"] end
                    local v = math.max(0, cur + d)
                    if type(max) == "number" then v = math.min(v, max) end
                    local ok = setCompValue(e, v)
                    host.car[k] = nil
                    log("CARSYNC CARADD from %s: %s %+.2f (%.2f -> %.2f) ok=%s", ctx.objName(pc), k, d, cur, v, tostring(ok))
                else
                    log("CARSYNC CARADD from %s: unknown part %s", ctx.objName(pc), k)
                end
            end
            return true
        elseif kind == "CARRESET" then
            return M.resetCommand(args, pc)
        elseif kind == "TRUNKLOCK" or kind == "TRUNKUNLOCK" then
            return M.lockCommand(kind, pc)
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
    -- player 2's refuel / charge actions on the car
    local add = { flag = {}, keyByComp = {}, snap = {}, hooked = false, tries = 0 }
    local FUEL_FN = "/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_FuelableComponent.BP_FuelableComponent_C:TransferFuel"
    local CHARGE_FN = "/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_BatteryChargerComponent.BP_BatteryChargerComponent_C:DoCharge"
    local function compKey(c)
        if not valid(c) then return nil end
        return add.keyByComp[c:GetFullName()]
    end
    -- a player action touched the car's fuel ("F") or battery ("B") this second
    local function note(key)
        if key then add.flag[key:sub(1, 1)] = true end
    end
    local function get(p)
        local ok, v = pcall(function() return p:get() end)
        return ok and v or nil
    end
    local function registerHooks()
        if add.hooked or add.tries > 20 then return end
        add.tries = add.tries + 1
        local okF = StaticFindObject(FUEL_FN) and pcall(function()
            RegisterHook(FUEL_FN, function(_, src, tgt, _, transferred)
                note(compKey(get(tgt)))
                note(compKey(get(src)))
            end)
        end)
        local okC = StaticFindObject(CHARGE_FN) and pcall(function()
            RegisterHook(CHARGE_FN, function(_, target)
                note(compKey(get(target)))
            end)
        end)
        if okF and okC then
            add.hooked = true
            log("CARSYNC hooked TransferFuel and DoCharge (player 2's refuel / charge)")
        end
    end

    local cl = { trunkActive = false, trunkBase = {}, carHost = {}, carActive = false,
                 id = nil, helloFor = nil, invLoaded = false, invRestored = false, invText = nil, invSentTick = -100 }

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
        local t = on("trunk") and trunk() or nil
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
        if not on("carstate") then return end
        local vals = parseValues(rest)
        local car = ctx.playerCar()
        local comps = carComponents(car)
        local set, missing = 0, 0
        for k, v in pairs(vals) do
            cl.carHost[k] = v
            local e = comps[k]
            -- a refuel / charge by player 2 not sent yet: the host's older value must not undo it before the client
            -- tick measures it (exp127: the charge came back as 5 -> 5; CARST arrives at once with the new channel)
            if add.flag[k:sub(1, 1)] then
                -- left as it is here
            elseif e then
                local cur = compValue(e)
                -- the gas cap holds whole litres only (writing 19.5 keeps 19): do not fight it over less than 1
                local tol = k:find("GasCap", 1, true) and 1.0 or 0.05
                if not cur or math.abs(cur - v) >= tol then setCompValue(e, v); set = set + 1 end
                if add.snap[k] then add.snap[k] = compValue(e) end
            else
                missing = missing + 1
            end
        end
        cl.carActive = true
        -- fuel drains every second on the host: log only bigger updates
        if set >= 3 or missing > 0 then log("CARSYNC client car: %d value(s) set from host, %d part(s) not found here", set, missing) end
    end

    ctx.hostMsgHandlers["INVLOAD"] = function(rest)
        local id, text = rest:match("^([%w]+)|(.*)$")
        if id ~= playerId() or not on("invsave") then return end
        cl.invLoaded = true
        -- only once per launch of player 2's game: its inventory lives on across map changes and rejoins, and a
        -- save up to 5 s old would take back items picked up since (or undo the losses of a team death)
        if cl.invRestored then log("CARSYNC saved inventory not applied: this game already has player 2's inventory"); return end
        cl.invRestored = true
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
        -- trunk: local changes -> host, when items went in or out here (and every 5 s for item state changes)
        local t = on("trunk") and trunk() or nil
        cl.trunkTicks = (cl.trunkTicks or 0) + 1
        if cl.trunkActive and t and (EV.takeDirty(t) or cl.trunkTicks % 5 == 0) then
            local d, now = trunkDeltaText(t)
            if d then
                ctx.sendCommand("TRUNKD," .. d)
                cl.trunkBase = now
                log("CARSYNC client trunk change sent: %s", d)
            end
        end
        -- car: keep the host's values; increases made here go to the host
        if cl.carActive and on("carstate") then
            local car = ctx.playerCar()
            local comps = carComponents(car)
            if on("refuel") then registerHooks() end
            local byComp = {}
            for k, e in pairs(comps) do byComp[e.comp:GetFullName()] = k end
            add.keyByComp = byComp
            local adds = {}
            for k, e in pairs(comps) do
                if e.kind == "F" or e.kind == "B" then
                    local cur = compValue(e)
                    if cur then
                        local d = add.snap[k] and (cur - add.snap[k]) or 0
                        if on("refuel") and add.flag[e.kind] and math.abs(d) >= 0.01 then
                            adds[#adds + 1] = string.format("%s=%.2f", k, d)
                            -- the hold below must not undo our own change before the host answers
                            if cl.carHost[k] then cl.carHost[k] = cl.carHost[k] + d end
                        end
                        add.snap[k] = cur
                    end
                end
            end
            add.flag = {}
            if #adds > 0 then
                ctx.sendCommand("CARADD," .. table.concat(adds, ";"))
                log("CARSYNC client refuel/charge sent: %s", table.concat(adds, ";"))
            end
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
        -- inventory: save on the host when items went in or out of the pockets / hand (at most every 5 s), after
        -- the saved one was loaded; item state changes (fuel used from a can in the hand) add no item, so a check
        -- every 30 s catches those
        if on("invsave") then
            local m = im()
            for _, cname in ipairs(PLAYER_CONTAINERS) do
                local cont = nil
                pcall(function() cont = m[cname] end)
                if valid(cont) and EV.takeDirty(cont) then cl.invDirty = true end
            end
        end
        if on("invsave") and cl.invLoaded and fastTick - cl.invSentTick >= 25
            and (cl.invDirty or fastTick - cl.invSentTick >= 150) then
            cl.invDirty = false
            local text = inventoryText()
            if fastTick - cl.invSentTick >= 150 then cl.invSentTick = fastTick end
            if text and text ~= cl.invText then
                cl.invText = text
                cl.invSentTick = fastTick
                ctx.sendCommand("INVSAVE," .. playerId() .. "!" .. text)
                log("CARSYNC inventory sent to the host for saving (%d bytes)", #text)
            end
        end
    end

    -- ------------------------------------------------------------ trunk lock
    -- Only one player has the trunk open at a time (owner's decision 2026-10-22, until world sync replaces the
    -- container mirror): both taking the same item at once duplicated it. Opening is seen through the game's
    -- open functions (hooked on both machines), the host decides who holds the trunk (first come), the other
    -- player's menu is closed with a message. Release: the holder's player menu is no longer open (polled).
    local lock = { holder = "none", mine = false, hooked = false, tries = 0, wantSince = nil, lastSaid = 0 }
    local IM_PATH = "/Game/Systems/Managers/BP_InventoryManager.BP_InventoryManager_C:"
    local function menuOpen()
        local m, open = im(), false
        if valid(m) then
            local a = {}
            pcall(function() m:IsPlayerMenuOpen(a, {}) end)
            open = a.IsOpen == true
        end
        return open
    end
    local function closeMenu(reason)
        local m = im()
        if valid(m) then pcall(function() m:RequestPlayerMenuClose() end) end
        local wl = FindFirstOf("UMG_Feedback_WarningList_C")
        if valid(wl) then
            pcall(function()
                wl:SetVisibility(4)
                wl["Add Message"](wl, FText(reason), 1, FName("PDCoopTrunk"), nil)
            end)
        end
        log("TRUNKLOCK %s", reason)
    end
    local function isTrunk(c)
        local t = trunk()
        return valid(c) and t and c:GetFullName() == t:GetFullName()
    end
    -- this player opened the trunk
    local function openedTrunk()
        if not on("trunk") then return end
        -- one open calls OpenCarInventories -> OpenPlayerInventory -> OpenInventoryContainer: count it once
        local now = os.clock()
        if lock.lastOpen and now - lock.lastOpen < 1.0 then return end
        lock.lastOpen = now
        if ctx.role() == "host" then
            if lock.holder ~= "none" and lock.holder ~= "host" then
                closeMenu("The trunk is open at your partner's.")
            else
                lock.holder, lock.mine = "host", true
                ctx.hostSendLatest("TRUNKLOCK|host")
            end
        else
            lock.wantSince = os.clock()
            ctx.sendCommand("TRUNKLOCK")
        end
    end
    local function registerLockHooks()
        if lock.hooked or lock.tries > 30 then return end
        lock.tries = lock.tries + 1
        if not StaticFindObject(IM_PATH .. "OpenCarInventories") then return end
        local okAll = true
        okAll = pcall(function() RegisterHook(IM_PATH .. "OpenCarInventories", function() openedTrunk() end) end) and okAll
        okAll = pcall(function()
            RegisterHook(IM_PATH .. "OpenPlayerInventory", function(_, _, other)
                local c = nil
                pcall(function() c = other:get() end)
                if isTrunk(c) then openedTrunk() end
            end)
        end) and okAll
        okAll = pcall(function()
            RegisterHook(IM_PATH .. "OpenInventoryContainer", function(_, cont)
                local c = nil
                pcall(function() c = cont:get() end)
                if isTrunk(c) then openedTrunk() end
            end)
        end) and okAll
        lock.hooked = true
        log("TRUNKLOCK hooks registered ok=%s", tostring(okAll))
    end
    M.openedTrunk = openedTrunk   -- for the dev tools / tests

    -- ------------------------------------------------------------ car reset (teleport) by player 2
    -- The car reset runs in player 2's game on its copy of the car (animation, no real move: the host's
    -- replicated transform wins). Player 2's StartCarReset / StopCarReset are forwarded; the host runs them on
    -- the real car, so the car moves for both (owner's decision 2026-10-22: player 2 may reset the car).
    local CM_PATH = "/Game/Systems/Managers/BP_CarManager.BP_CarManager_C:"
    local reset = { hooked = false, tries = 0, forwarding = false }
    local function registerResetHooks()
        if reset.hooked or reset.tries > 30 or ctx.role() ~= "client" then return end
        reset.tries = reset.tries + 1
        if not StaticFindObject(CM_PATH .. "StartCarReset") then return end
        local ok1 = pcall(function() RegisterHook(CM_PATH .. "StartCarReset", function() ctx.sendCommand("CARRESET,start") end) end)
        local ok2 = pcall(function() RegisterHook(CM_PATH .. "StopCarReset", function() ctx.sendCommand("CARRESET,stop") end) end)
        reset.hooked = true
        log("CARRESET hooks for player 2 ok=%s/%s", tostring(ok1), tostring(ok2))
    end
    function M.resetCommand(args, pc)
        local _, carm = FindFirstOf("BP_MainCharacterManager_C"), FindFirstOf("BP_CarManager_C")
        if not valid(carm) then return true end
        local fn = (args == "stop") and "StopCarReset" or "StartCarReset"
        local ok, err = pcall(function() carm[fn](carm) end)
        log("CARRESET %s from %s ok=%s %s", fn, ctx.objName(pc), tostring(ok), ok and "" or tostring(err))
        return true
    end

    -- host: requests and releases from player 2
    function M.lockCommand(kind, pc)
        if kind == "TRUNKLOCK" then
            local pid = tostring(pc.PlayerState.PlayerId)
            if lock.holder == "none" or lock.holder == pid then
                lock.holder = pid
                log("TRUNKLOCK player %s has the trunk", pid)
            else
                log("TRUNKLOCK player %s asked, %s has it", pid, lock.holder)
            end
            ctx.hostSendLatest("TRUNKLOCK|" .. lock.holder)
            return true
        elseif kind == "TRUNKUNLOCK" then
            local pid = tostring(pc.PlayerState.PlayerId)
            if lock.holder == pid then lock.holder = "none"; ctx.hostSendLatest("TRUNKLOCK|none") end
            return true
        end
        return false
    end
    ctx.hostMsgHandlers["TRUNKLOCK"] = function(rest)
        lock.holder = rest
        local me = tostring(ctx.myPlayerId())
        if rest == me then
            lock.mine, lock.wantSince = true, nil
        elseif lock.wantSince then
            -- asked for it, the partner has it: close this player's menu
            lock.wantSince = nil
            lock.mine = false
            if rest ~= "none" then closeMenu("The trunk is open at your partner's.") end
        end
    end

    function M.lockTick()
        pcall(registerResetHooks)
        if not on("trunk") then return end
        registerLockHooks()
        if ctx.role() == "host" then
            -- the holder left the session: free the trunk
            if lock.holder ~= "none" and lock.holder ~= "host" then
                local present = false
                for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
                    local ok, pid = pcall(function() return pc.PlayerState.PlayerId end)
                    if ok and valid(pc) and not pc:IsLocalController() and tostring(pid) == lock.holder then present = true end
                end
                if not present then lock.holder = "none"; ctx.hostSendLatest("TRUNKLOCK|none"); log("TRUNKLOCK holder left") end
            end
            if lock.mine and not menuOpen() then
                lock.mine = false
                if lock.holder == "host" then lock.holder = "none"; ctx.hostSendLatest("TRUNKLOCK|none") end
            end
        else
            if lock.mine and not menuOpen() then
                lock.mine = false
                ctx.sendCommand("TRUNKUNLOCK")
            end
        end
    end

    return M
end
