-- PDCoopNet itemstate: read and write the numeric state of an item instance (fuel, battery charge, durability,
-- health) so items that cross the network keep it.
--
-- The state lives in the instance's property data, which Blueprint reads through property components
-- (BP_FuelableComponent_C, ...). Those components normally sit on the item's actor, which an item in a
-- container does not have. A component can be pointed at any instance with SetItemInstance, so this module
-- keeps one standalone "accessor" component per kind (StaticConstructObject, no actor) and points it at the
-- instance it reads or writes. Verified on a fuel can in the player's inventory (dev session 2026-10-20).
--
-- State text: kinds joined by "_", e.g. "F7.25_D3" (F fuel, B battery, D durability, H health).
-- Writing follows the owner's rule: exact value; if that does not stick, 50% of max but never more than the
-- value it had; if that fails too, the item keeps the default it was created with (logged as STATE LOST).
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local M = {}
    local COMP = "/Game/Gameplay/Inventory/GenericItemProperties/Components/"
    local PROP = "/Game/Gameplay/Inventory/GenericItemProperties/"
    local KINDS = {
        { k = "F", prop = "IP_Fuelable", comp = "BP_FuelableComponent",
          get = function(c) local a, b = {}, {}; c:GetFuelStatus(a, b, {}, {}, {}, {}, {}); return a.Fuel, b["Fuel Capacity"] end,
          set = function(c, v) c["Set Fuel"](c, v) end },
        { k = "B", prop = "IP_Battery", comp = "BP_BatteryComponent",
          get = function(c) local a, b = {}, {}; c:GetBatteryStatus(a, b, {}, {}, {}); return a.BATTERY or a.Battery, b["Battery Capacity"] end,
          set = function(c, v) c["Set Battery"](c, v) end },
        { k = "D", prop = "IP_Durability", comp = "BP_DurabilityComponent", int = true,
          get = function(c) local a, b = {}, {}; c["Get Durability"](c, a, b, {}, {}, {}); return a.Durability, b["Max Durability"] end,
          set = function(c, v) c["Set Durability"](c, math.floor(v + 0.5)) end },
        { k = "H", prop = "IP_Health", comp = "BP_HealthComponent",
          get = function(c) return c:HC_GetHealth(), c:HC_GetMaxHealth() end,
          set = function(c, v) c:SetHealth(v) end },
    }
    local byKey = {}
    for _, s in ipairs(KINDS) do byKey[s.k] = s end

    local function findOrLoad(path)
        local o = StaticFindObject(path)
        if valid(o) then return o end
        local ok, a = pcall(LoadAsset, path)
        if ok and valid(a) then return a end
        o = StaticFindObject(path)
        return valid(o) and o or nil
    end
    local propCache = {}
    local function propStruct(s)
        if propCache[s.k] == nil then propCache[s.k] = findOrLoad(PROP .. s.prop .. "." .. s.prop) or false end
        return propCache[s.k] or nil
    end
    -- A new accessor for every use, never kept: nothing in the game references it, so Unreal's garbage collector
    -- frees it, and a kept one was a dangling pointer (dev session 2026-10-22: the dev tools' copy of this module
    -- crashed the host with an access violation inside a UObject call). GC does not run while Lua runs, so an
    -- accessor made here lives for the call that made it.
    local accClass = {}
    local function accessor(s)
        local cls = accClass[s.k]
        if not valid(cls) then cls = findOrLoad(COMP .. s.comp .. "." .. s.comp .. "_C"); accClass[s.k] = cls end
        if not cls then return nil end
        local outer = FindFirstOf("InventorySystem")
        local ok, obj = pcall(function() return StaticConstructObject(cls, outer) end)
        if ok and valid(obj) then return obj end
        log("ITEMSTATE cannot create the %s accessor: %s", s.comp, tostring(obj))
        return nil
    end

    -- kinds an archetype supports, cached per archetype full name
    local kindsCache = {}
    local function kindsOf(inst)
        local arch = nil
        pcall(function() arch = inst.Archetype end)
        if not valid(arch) then return {} end
        local key = arch:GetFullName()
        local ks = kindsCache[key]
        if ks then return ks end
        ks = {}
        for _, s in ipairs(KINDS) do
            local st = propStruct(s)
            local ok, has = false, false
            if st then ok, has = pcall(function() return inst:HasProperties(st) end) end
            if ok and has then ks[#ks + 1] = s end
        end
        kindsCache[key] = ks
        return ks
    end
    M.isStateful = function(inst) return #kindsOf(inst) > 0 end

    local function readKind(s, inst)
        local c = accessor(s)
        if not c then return nil end
        local ok, v, m = pcall(function()
            c:SetItemInstance(inst, false)
            return s.get(c)
        end)
        if ok and type(v) == "number" then return v, (type(m) == "number" and m or nil) end
        return nil
    end
    local function writeKind(s, inst, v)
        local c = accessor(s)
        if not c then return false end
        return pcall(function()
            c:SetItemInstance(inst, false)
            s.set(c, v)
        end)
    end
    local function fmtVal(s, v)
        if s.int then return string.format("%d", math.floor(v + 0.5)) end
        local t = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "")
        return t
    end
    local function close(s, a, b)
        if s.int then return math.floor(a + 0.5) == math.floor(b + 0.5) end
        return math.abs(a - b) <= 0.011
    end

    local function on() return not ctx.feature or ctx.feature("itemstate") end
    -- "" for items without state (and for every item when the itemstate feature is off)
    function M.read(inst)
        if not on() or not valid(inst) then return "" end
        local parts = {}
        for _, s in ipairs(kindsOf(inst)) do
            local v = readKind(s, inst)
            if v then parts[#parts + 1] = s.k .. fmtVal(s, v) end
        end
        return table.concat(parts, "_")
    end

    function M.parse(text)
        local t = {}
        for k, v in (text or ""):gmatch("([FBDH])(%-?[%d.]+)") do t[k] = tonumber(v) end
        return t
    end

    -- returns "exact" | "half" | "lost" (worst over the kinds) and a short report
    local stats = { exact = 0, half = 0, lost = 0 }
    M.stats = stats
    function M.write(inst, text, what)
        if not on() then return "exact", "feature off" end
        if not valid(inst) then return "lost", "no instance" end
        local want = M.parse(text)
        local worst, notes = "exact", {}
        for _, s in ipairs(kindsOf(inst)) do
            local target = want[s.k]
            local result = "lost"
            -- the setters do not clamp ("Set Fuel" 999 sticks in a 10 l can): never write more than the max
            local _, max0 = readKind(s, inst)
            if target and max0 then target = math.max(0, math.min(target, max0)) end
            if target then
                writeKind(s, inst, target)
                local got = readKind(s, inst)
                if got and close(s, got, target) then result = "exact" end
            end
            if result ~= "exact" then
                local _, max = readKind(s, inst)
                if max then
                    local half = max * 0.5
                    if target then half = math.min(half, target) end
                    writeKind(s, inst, half)
                    local got = readKind(s, inst)
                    if got and close(s, got, half) then result = "half" end
                end
            end
            if result ~= "exact" then
                notes[#notes + 1] = s.k .. "=" .. result
                if result == "lost" or worst == "exact" then worst = result end
            end
        end
        stats[worst] = stats[worst] + 1
        if worst ~= "exact" then
            log("ITEMSTATE %s %s: wanted '%s', %s%s", worst == "lost" and "STATE LOST for" or "50% fallback for",
                what or inst:GetFName():ToString(), text or "", table.concat(notes, " "),
                worst == "lost" and " (the item keeps its default state)" or "")
        end
        return worst, table.concat(notes, " ")
    end

    return M
end
