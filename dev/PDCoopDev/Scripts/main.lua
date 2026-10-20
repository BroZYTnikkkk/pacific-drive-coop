-- PDCoopDev: developer tools for the Pacific Drive co-op mod. NOT part of the playable build:
-- install it only into test copies of the game (tools/run_test.ps1 -Dev, tools/dev_session.ps1).
--
-- 1) Command file. Write a request to ue4ss/Mods/PDCoopDev/cmd.txt (line 1 = request id, the rest = command);
--    the mod runs it in the game thread within 250 ms, deletes cmd.txt and writes ue4ss/Mods/PDCoopDev/out.txt:
--    "@<id>" / output lines / "@end". tools/dev.ps1 does this for you.
--    Commands: help, state, inv [all|player|hand|trunk|<container field>], give <item> [n] [trunk], spawn <item> [n],
--    items <filter>, find <class> [filter], props <class|name> [filter], funcs <class|name> [filter],
--    god [on|off], heal, hurt [n], car, carfix (repair/refuel/charge), carhurt [pct], tp <x> <y> <z>, tpcar, carhere,
--    shot, con <console command>, luafile <path>,
--    lua <code> (multi-line; helpers below are in scope, p(...) prints into the output, the return value is printed).
-- 2) Keys (game window focused): Ctrl+F9 god mode on/off, Ctrl+F10 car: refuel/charge/repair, Ctrl+F11 state into
--    the UE4SS log.
-- 3) ue4ss/Mods/PDCoopDev/dev.txt (optional): "open <map or address>" opens it once the main menu is up,
--    "god" starts with god mode on.
local UEHelpers = require("UEHelpers")
local TAG = "[PDCoopDev] "
local DIR = "ue4ss/Mods/PDCoopDev/"
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

-- ---------------------------------------------------------------- helpers (also visible to "lua")
local H = {}

function H.valid(o)
    if o == nil or not o:IsValid() then return false end
    local ok, dead = pcall(function() return o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end)
    return not (ok and dead)
end
local valid = H.valid
function H.name(o) return valid(o) and o:GetFName():ToString() or "nil" end
function H.cls(o) return valid(o) and o:GetClass():GetFName():ToString() or "nil" end
function H.find(className)
    local r = {}
    for _, o in ipairs(FindAllOf(className) or {}) do if valid(o) then r[#r + 1] = o end end
    return r
end
function H.first(className) return H.find(className)[1] end
function H.pc()
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) and c:IsLocalController() then return c end
    end
end
function H.pawn() local c = H.pc(); return c and valid(c.Pawn) and c.Pawn or nil end
function H.cm() return H.first("BP_MainCharacterManager_C") end
function H.carm() return H.first("BP_CarManager_C") end
function H.im() return H.first("BP_InventoryManager_C") end
function H.invsys() return H.first("InventorySystem") end
-- the character this machine plays (the pawn, or the character sitting in the car while driving)
function H.me()
    local p = H.pawn()
    if p and H.cls(p) == "PDP_MainCharacter_C" then return p end
    for _, ch in ipairs(H.find("PDP_MainCharacter_C")) do
        local okR, r = pcall(function() return ch.Role end)
        local okC, remote = pcall(function() return valid(ch.Controller) and not ch.Controller:IsLocalController() end)
        if okR and r == 2 then return ch end                       -- client: autonomous proxy
        if okR and r == 3 and not (okC and remote) then return ch end -- host: not driven by a remote player
    end
end
function H.car()
    local m = H.carm()
    local c = nil
    pcall(function() c = m.NewCarActor end)
    if valid(c) then return c end
    return H.first("BaseNewCar")
end
function H.loc(a)
    local ok, l = pcall(function() return a:K2_GetActorLocation() end)
    if not ok or not l then return "?" end
    return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
end
function H.console(cmd)
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(UEHelpers.GetWorldContextObject(), cmd, H.pc())
end

-- value -> short text
function H.fmt(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "number" then return (math.type and math.type(v) == "integer") and tostring(v) or string.format("%.3f", v) end
    if t == "boolean" or t == "string" then return tostring(v) end
    if t == "table" then
        local parts = {}
        for k, x in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. (depth < 2 and H.fmt(x, depth + 1) or "...")
            if #parts > 30 then parts[#parts + 1] = "..."; break end
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    if t == "userdata" then
        local okG, g = pcall(function() return v:get() end)              -- RemoteUnrealParam (out params, arrays)
        if okG and g ~= nil and g ~= v and depth < 3 then return H.fmt(g, depth + 1) end
        local ok, s = pcall(function() return v:ToString() end)          -- FString / FText / FName
        if ok and type(s) == "string" then return '"' .. s .. '"' end
        ok, s = pcall(function() return v:GetFullName() end)            -- UObject
        if ok and type(s) == "string" then return s end
        ok, s = pcall(function() return v:GetArrayNum() end)            -- TArray
        if ok and type(s) == "number" then
            local parts = {}
            if depth < 1 then
                pcall(function() v:ForEach(function(i, e)
                    if #parts < 12 then parts[#parts + 1] = H.fmt(e:get(), depth + 1) end
                end) end)
            end
            return string.format("TArray[%d]%s", s, #parts > 0 and (" " .. table.concat(parts, "; ")) or "")
        end
        local okx, x = pcall(function() return v.X end)                   -- vectors and rotators
        if okx and type(x) == "number" then
            local y, z, w = v.Y, v.Z, nil
            pcall(function() w = v.W end)
            return string.format("(%.1f, %.1f, %.1f%s)", x, y or 0, z or 0, type(w) == "number" and string.format(", %.2f", w) or "")
        end
        local okp, pitch = pcall(function() return v.Pitch end)
        if okp and type(pitch) == "number" then return string.format("(P%.1f Y%.1f R%.1f)", pitch, v.Yaw, v.Roll) end
        return tostring(v)
    end
    return tostring(v)
end

-- find an object: a class name ("BP_CarManager_C") gives its first live instance; anything else is matched
-- against the names of live objects of class `classHint` (default Actor), then StaticFindObject.
function H.obj(what, classHint)
    if type(what) ~= "string" then return what end
    local o = H.first(what)
    if o then return o end
    for _, x in ipairs(H.find(classHint or "Actor")) do
        if x:GetFName():ToString():find(what, 1, true) then return x end
    end
    local s = StaticFindObject(what)
    if valid(s) then return s end
end

-- properties of an object (walks the class chain); filter is a plain substring (case-insensitive)
function H.props(o, filter)
    o = H.obj(o)
    if not valid(o) then return { "no object" } end
    local out = {}
    local f = filter and filter:lower()
    local c = o:GetClass()
    while c and c:IsValid() do
        local cname = c:GetFName():ToString()
        c:ForEachProperty(function(prop)
            local n = prop:GetFName():ToString()
            if not f or n:lower():find(f, 1, true) then
                local ok, v = pcall(function() return o[n] end)
                out[#out + 1] = string.format("%s.%s [%s] = %s", cname, n, prop:GetClass():GetFName():ToString(),
                    ok and H.fmt(v) or ("<" .. tostring(v) .. ">"))
            end
        end)
        if cname == "Actor" or cname == "Object" or cname == "ActorComponent" then break end
        c = c:GetSuperStruct()
    end
    return out
end

function H.funcs(o, filter)
    o = H.obj(o)
    if not valid(o) then return { "no object" } end
    local out = {}
    local f = filter and filter:lower()
    local c = o:IsA(StaticFindObject("/Script/CoreUObject.Class")) and o or o:GetClass()
    while c and c:IsValid() do
        local cname = c:GetFName():ToString()
        pcall(function() c:ForEachFunction(function(fn)
            local n = fn:GetFName():ToString()
            if not f or n:lower():find(f, 1, true) then out[#out + 1] = cname .. ":" .. n end
        end) end)
        if cname == "Actor" or cname == "Object" then break end
        c = c:GetSuperStruct()
    end
    return out
end

-- item archetypes: "IA_Resource_Raw_Scrap_Steel", a full /Game path, or a unique substring
local archCache = nil
function H.archetypes()
    if archCache then return archCache end
    archCache = {}
    local inv = H.invsys()
    -- returns a Lua table of RemoteUnrealParam (one :get() each)
    local ok, arr = pcall(function() return inv:GetAllArchetypes() end)
    if ok and type(arr) == "table" then
        for _, e in ipairs(arr) do
            local okA, a = pcall(function() return e:get() end)
            if okA and valid(a) then archCache[#archCache + 1] = a end
        end
    end
    if #archCache == 0 then archCache = H.find("ItemArchetype") end
    return archCache
end
function H.arch(what)
    if type(what) ~= "string" then return what end
    if what:sub(1, 1) == "/" then
        local ok, a = pcall(LoadAsset, what)
        return ok and valid(a) and a or nil
    end
    local exact, hits = nil, {}
    local wl = what:lower()
    for _, a in ipairs(H.archetypes()) do
        local n = a:GetFName():ToString()
        if n == what then exact = a; break end
        if n:lower():find(wl, 1, true) then hits[#hits + 1] = a end
    end
    if exact then return exact end
    if #hits == 1 then return hits[1] end
    -- several matches: the shortest name wins if it is the only one of that length ("scrap_steel" -> ..._Steel)
    table.sort(hits, function(x, y) return #x:GetFName():ToString() < #y:GetFName():ToString() end)
    if #hits > 1 and #hits[1]:GetFName():ToString() < #hits[2]:GetFName():ToString() then return hits[1] end
    return nil, hits
end

-- item containers of the inventory manager: { fieldName = UItemContainer }
function H.containers()
    local im = H.im()
    local r = {}
    if not valid(im) then return r end
    local c = im:GetClass()
    while c and c:IsValid() do
        c:ForEachProperty(function(prop)
            local n = prop:GetFName():ToString()
            if n:find("^Inventory_") then
                local ok, v = pcall(function() return im[n] end)
                if ok and valid(v) then r[n] = v end
            end
        end)
        if c:GetFName():ToString() == "Object" then break end
        c = c:GetSuperStruct()
    end
    return r
end
-- { {slot=i, arch=name, n=count} ... } for a container
function H.listContainer(cont)
    local r = {}
    if not valid(cont) then return r end
    local i = 0
    pcall(function() cont.Slots:ForEach(function(_, e)
        i = i + 1
        local slot = e:get()
        local n, arch = 0, nil
        pcall(function() n = slot.Items:GetArrayNum() end)
        if n > 0 then
            pcall(function() arch = slot.Items[1].Archetype:GetFName():ToString() end)
            r[#r + 1] = { slot = i, arch = arch or "?", n = n }
        end
    end) end)
    return r, i
end

-- ---------------------------------------------------------------- health, car
-- Player health, the car's aggregated health, fuel and battery are UGameResource objects of the
-- BP_ResourceManager (GameInstance, one per process: each machine has its own). Car parts carry item property
-- components (BP_HealthComponent_C, BP_FuelableComponent_C, BP_BatteryComponent_C); GetOwner() is the part actor.
-- Out parameters: pass one table per out parameter, the game fills it by parameter name ({Fuel=...}).
function H.rm() return H.first("BP_ResourceManager_C") end
function H.res(nameOrNil)
    local rm = H.rm()
    if not valid(rm) then return nil end
    if nameOrNil then return rm[nameOrNil] end
    return rm
end

-- the top attach parent of an actor (part -> car)
function H.top(a)
    local t = a
    for _ = 1, 5 do
        local p = nil
        pcall(function() p = t:GetAttachParentActor() end)
        if not valid(p) then break end
        t = p
    end
    return t
end
function H.ownerOf(comp)
    local o = nil
    pcall(function() o = comp:GetOwner() end)
    return valid(o) and o or nil
end
-- property components of `className` that sit on the car or on parts attached to it
function H.carComps(className, car)
    car = car or H.car()
    local r = {}
    if not valid(car) then return r end
    local carName = car:GetFullName()
    for _, c in ipairs(H.find(className)) do
        local o = H.ownerOf(c)
        if o and H.top(o):GetFullName() == carName then r[#r + 1] = c end
    end
    return r
end
function H.hp(hc)
    local h, m = nil, nil
    pcall(function() h = hc:HC_GetHealth() end)
    pcall(function() m = hc:HC_GetMaxHealth() end)
    return h, m
end
function H.fuelOf(c)
    local a, b = {}, {}
    pcall(function() c:GetFuelStatus(a, b, {}, {}, {}, {}, {}) end)
    return a.Fuel, b["Fuel Capacity"]
end
function H.batteryOf(c)
    local a, b = {}, {}
    pcall(function() c:GetBatteryStatus(a, b, {}, {}, {}) end)
    return a.BATTERY or a.Battery, b["Battery Capacity"]
end
-- car parts with health: { part, hc, hp, max }
function H.carParts(car)
    local r = {}
    for _, hc in ipairs(H.carComps("BP_HealthComponent_C", car)) do
        local h, m = H.hp(hc)
        r[#r + 1] = { part = H.ownerOf(hc), hc = hc, hp = h, max = m }
    end
    return r
end

local god = false
local function godTick()
    local g = H.res("PlayerHealth")
    if valid(g) and g.Current < g.Maximum then g:Fill(H.pc()) end
end

local function heal()
    local g = H.res("PlayerHealth")
    if not valid(g) then return "no PlayerHealth resource" end
    local before = g.Current
    g:Fill(H.pc())
    return string.format("player health %.1f -> %.1f / %.1f", before, g.Current, g.Maximum)
end

local function hurt(n)
    local g = H.res("PlayerHealth")
    if not valid(g) then return "no PlayerHealth resource" end
    g:Adjust(H.pc(), -(tonumber(n) or 25))
    return string.format("player health %.1f / %.1f", g.Current, g.Maximum)
end

local function carFix()
    local car = H.car()
    if not valid(car) then return "no car" end
    local fixed, fuel, bat = 0, 0, 0
    for _, e in ipairs(H.carParts(car)) do
        if type(e.hp) == "number" and type(e.max) == "number" and e.hp < e.max then
            pcall(function() e.hc:SetHealth(e.max) end)
            fixed = fixed + 1
        end
    end
    for _, c in ipairs(H.carComps("BP_FuelableComponent_C", car)) do
        local f, cap = H.fuelOf(c)
        if type(cap) == "number" and type(f) == "number" and f < cap then
            if pcall(function() c["Set Fuel"](c, cap) end) then fuel = fuel + 1 end
        end
    end
    for _, c in ipairs(H.carComps("BP_BatteryComponent_C", car)) do
        local b, cap = H.batteryOf(c)
        if type(cap) == "number" and type(b) == "number" and b < cap then
            if pcall(function() c["Set Battery"](c, cap) end) then bat = bat + 1 end
        end
    end
    return string.format("car %s: repaired %d part(s), refuelled %d tank(s), charged %d battery(ies)", H.name(car), fixed, fuel, bat)
end

-- damage every car part to `pct` percent of its max health (for damage sync tests)
local function carHurt(pct)
    pct = tonumber(pct) or 50
    local n = 0
    for _, e in ipairs(H.carParts()) do
        if type(e.max) == "number" and e.max > 0 then
            pcall(function() e.hc:SetHealth(e.max * pct / 100) end)
            n = n + 1
        end
    end
    return string.format("%d part(s) set to %d%%", n, pct)
end

local function carText()
    local car = H.car()
    if not valid(car) then return "no car" end
    local out = { string.format("car %s at %s", H.name(car), H.loc(car)) }
    for _, e in ipairs(H.carParts(car)) do
        out[#out + 1] = string.format("  part %-45s hp %s / %s", H.cls(e.part), H.fmt(e.hp), H.fmt(e.max))
    end
    for _, c in ipairs(H.carComps("BP_FuelableComponent_C", car)) do
        local f, cap = H.fuelOf(c)
        out[#out + 1] = string.format("  fuel %-45s %s / %s", H.cls(H.ownerOf(c)), H.fmt(f), H.fmt(cap))
    end
    for _, c in ipairs(H.carComps("BP_BatteryComponent_C", car)) do
        local b, cap = H.batteryOf(c)
        out[#out + 1] = string.format("  battery %-42s %s / %s", H.cls(H.ownerOf(c)), H.fmt(b), H.fmt(cap))
    end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- commands
local outBuf = nil
local function p(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = H.fmt((select(i, ...))) end
    local line = table.concat(parts, " ")
    if outBuf then outBuf[#outBuf + 1] = line else log("%s", line) end
end
H.p = p

local function stateText()
    local lines = {}
    local w = UEHelpers.GetWorld()
    lines[#lines + 1] = "world: " .. (valid(w) and w:GetFName():ToString() or "?")
    local pc = H.pc()
    local net = "?"
    pcall(function()
        local ksl = UEHelpers.GetKismetSystemLibrary()
        local wco = UEHelpers.GetWorldContextObject()
        net = ksl:IsServer(wco) and (ksl:IsStandalone(wco) and "standalone" or "host") or "client"
    end)
    lines[#lines + 1] = "net: " .. net .. "  players: " .. #H.find("PlayerState")
    local me = H.me()
    lines[#lines + 1] = string.format("me: %s at %s  pawn: %s", H.name(me), valid(me) and H.loc(me) or "?", H.name(pc and pc.Pawn))
    local g = H.res("PlayerHealth")
    if valid(g) then lines[#lines + 1] = string.format("health: %.1f / %.1f  god: %s", g.Current, g.Maximum, tostring(god)) end
    local car = H.car()
    lines[#lines + 1] = string.format("car: %s at %s", H.name(car), valid(car) and H.loc(car) or "?")
    if valid(car) then
        local parts = H.carParts(car)
        local hurt = 0
        for _, e in ipairs(parts) do if type(e.hp) == "number" and type(e.max) == "number" and e.hp < e.max then hurt = hurt + 1 end end
        local fuel, cap = 0, 0
        for _, c in ipairs(H.carComps("BP_FuelableComponent_C", car)) do
            local f, m = H.fuelOf(c)
            if type(f) == "number" and type(m) == "number" then fuel, cap = fuel + f, cap + m end
        end
        local bat, bcap = 0, 0
        for _, c in ipairs(H.carComps("BP_BatteryComponent_C", car)) do
            local b2, m = H.batteryOf(c)
            if type(b2) == "number" and type(m) == "number" then bat, bcap = bat + b2, bcap + m end
        end
        lines[#lines + 1] = string.format("  parts with health: %d, damaged: %d; fuel %.1f / %.1f; battery %.1f / %.1f",
            #parts, hurt, fuel, cap, bat, bcap)
    end
    for _, ch in ipairs(H.find("PDP_MainCharacter_C")) do
        local ctrl, role = "none", "?"
        pcall(function() if valid(ch.Controller) then ctrl = ch.Controller:IsLocalController() and "local" or "remote" end end)
        pcall(function() role = tostring(ch.Role) end)
        lines[#lines + 1] = string.format("character %s at %s controller=%s role=%s", H.name(ch), H.loc(ch), ctrl, role)
    end
    local conts = H.containers()
    local cn = {}
    for n, c in pairs(conts) do
        local items = H.listContainer(c)
        local total = 0
        for _, e in ipairs(items) do total = total + e.n end
        if total > 0 or n == "Inventory_Player" or n == "Inventory_Trunk" then cn[#cn + 1] = string.format("%s=%d", n:sub(11), total) end
    end
    table.sort(cn)
    lines[#lines + 1] = "containers (item count): " .. table.concat(cn, " ")
    return table.concat(lines, "\n")
end

local function containerByWord(word)
    local conts = H.containers()
    local map = { player = "Inventory_Player", hand = "Inventory_PlayerHand", trunk = "Inventory_Trunk", garage = "Inventory_Garage" }
    local key = map[word] or word
    if conts[key] then return conts[key], key end
    if conts["Inventory_" .. key] then return conts["Inventory_" .. key], "Inventory_" .. key end
end

local function invText(word)
    word = word or "all"
    local out = {}
    local names = {}
    if word == "all" then
        for n in pairs(H.containers()) do names[#names + 1] = n end
        table.sort(names)
    else
        local _, key = containerByWord(word)
        if not key then return "unknown container " .. word end
        names = { key }
    end
    local conts = H.containers()
    for _, n in ipairs(names) do
        local items, slots = H.listContainer(conts[n])
        if #items > 0 or word ~= "all" then
            out[#out + 1] = string.format("%s (%s, %d slots):", n, H.name(conts[n]), slots or 0)
            for _, e in ipairs(items) do out[#out + 1] = string.format("  [%d] %s x%d", e.slot, e.arch, e.n) end
        end
    end
    return #out > 0 and table.concat(out, "\n") or "all containers empty"
end

local function give(what, n, where)
    local a, hits = H.arch(what)
    if not a then
        local names = {}
        for i = 1, math.min(#(hits or {}), 15) do names[#names + 1] = hits[i]:GetFName():ToString() end
        return string.format("no unique item '%s' (%d matches) %s", what, #(hits or {}), table.concat(names, " "))
    end
    local im = H.im()
    n = tonumber(n) or 1
    local trunk = (where == "trunk")
    local okAll, err = true, nil
    for _ = 1, n do
        local ok, e = pcall(function() im:CreateItemInPlayerInventory(a, false, trunk, 0, true) end)
        if not ok then okAll, err = false, e; break end
    end
    return string.format("give %s x%d -> %s: %s", a:GetFName():ToString(), n, trunk and "trunk" or "player", okAll and "ok" or tostring(err))
end

local function spawnItems(what, n)
    local a, hits = H.arch(what)
    if not a then return string.format("no unique item '%s' (%d matches)", what, #(hits or {})) end
    local me = H.me()
    local base = valid(me) and me or H.pawn()
    if not valid(base) then return "no pawn" end
    local l = base:K2_GetActorLocation()
    local f = base:GetActorForwardVector()
    local inv = H.invsys()
    local out = {}
    for i = 1, (tonumber(n) or 1) do
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                     Translation = { X = l.X + f.X * (150 + 40 * i), Y = l.Y + f.Y * (150 + 40 * i), Z = l.Z + 50 },
                     Scale3D = { X = 1, Y = 1, Z = 1 } }
        local ok, r = pcall(function() return inv:SpawnItemActor(UEHelpers.GetWorldContextObject(), xf, a, 0, 0) end)
        out[#out + 1] = ok and (H.name(r) .. " at " .. H.loc(r)) or tostring(r)
    end
    return table.concat(out, "\n")
end

local function tp(x, y, z)
    local me = H.pawn()
    if not valid(me) then return "no pawn" end
    me:K2_SetActorLocation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, false, {}, true)
    return "at " .. H.loc(me)
end

local function joinLines(t) return type(t) == "table" and table.concat(t, "\n") or tostring(t) end

local commands = {}
commands.help = function() return "help state inv give spawn items find props funcs god heal hurt car carfix carhurt fuel tp tpcar carhere shot con lua luafile" end
commands.state = function() return stateText() end
commands.inv = function(a) return invText(a[1]) end
commands.give = function(a) return give(a[1], a[2], a[3]) end
commands.spawn = function(a) return spawnItems(a[1], a[2]) end
commands.items = function(a)
    local f = (a[1] or ""):lower()
    local out = {}
    for _, x in ipairs(H.archetypes()) do
        local n = x:GetFName():ToString()
        if n:lower():find(f, 1, true) then out[#out + 1] = n end
    end
    table.sort(out)
    return string.format("%d item(s)\n%s", #out, table.concat(out, "\n"))
end
commands.find = function(a)
    local out = {}
    for _, o in ipairs(H.find(a[1] or "Actor")) do
        local n = o:GetFName():ToString()
        if not a[2] or n:lower():find(a[2]:lower(), 1, true) then
            local l = ""
            pcall(function() if o:IsA(StaticFindObject("/Script/Engine.Actor")) then l = " at " .. H.loc(o) end end)
            out[#out + 1] = o:GetFullName() .. l
        end
    end
    return string.format("%d object(s)\n%s", #out, table.concat(out, "\n"))
end
commands.props = function(a) return joinLines(H.props(a[1], a[2])) end
commands.funcs = function(a) return joinLines(H.funcs(a[1], a[2])) end
commands.god = function(a)
    if a[1] == "on" then god = true elseif a[1] == "off" then god = false else god = not god end
    return "god " .. tostring(god)
end
commands.heal = function() return heal() end
commands.hurt = function(a) return hurt(a[1]) end
commands.car = function() return carText() end
commands.carhurt = function(a) return carHurt(a[1]) end
commands.carfix = function() return carFix() end
commands.fuel = commands.carfix
commands.tp = function(a) return tp(a[1], a[2], a[3]) end
commands.tpcar = function()
    local car = H.car()
    if not valid(car) then return "no car" end
    local l = car:K2_GetActorLocation()
    local r = car:GetActorRightVector()
    return tp(l.X + r.X * 300, l.Y + r.Y * 300, l.Z + 100)
end
commands.carhere = function()
    local car, me = H.car(), H.pawn()
    if not (valid(car) and valid(me)) then return "no car or pawn" end
    local l = me:K2_GetActorLocation()
    local f = me:GetActorForwardVector()
    car:K2_SetActorLocation({ X = l.X + f.X * 500, Y = l.Y + f.Y * 500, Z = l.Z + 100 }, false, {}, true)
    return "car at " .. H.loc(car)
end
commands.shot = function() H.console("HighResShot 1"); return "screenshot requested" end
commands.con = function(_, rest) H.console(rest); return "console: " .. rest end

local env = setmetatable({}, { __index = function(_, k) if H[k] ~= nil then return H[k] end return _G[k] end })
commands.lua = function(_, rest)
    local chunk, err = load(rest, "=dev", "t", env)
    if not chunk then
        chunk, err = load("return " .. rest, "=dev", "t", env)
        if not chunk then return "compile error: " .. tostring(err) end
    end
    local res = table.pack(pcall(chunk))
    if not res[1] then return "error: " .. tostring(res[2]) end
    local parts = {}
    for i = 2, res.n do parts[#parts + 1] = H.fmt(res[i]) end
    return #parts > 0 and table.concat(parts, "\t") or nil
end
-- run a Lua file (relative to Binaries/Win64 or absolute) with the same helpers in scope
commands.luafile = function(_, rest)
    local f = io.open(rest, "r")
    if not f then return "cannot open " .. rest end
    local code = f:read("*a")
    f:close()
    return commands.lua(nil, code)
end
-- "lua" with the first expression auto-returned: "lua H.cm()" works, so does a full block
local function runCommand(text)
    local word, rest = text:match("^%s*(%S+)%s*(.-)%s*$")
    if not word then return "empty command" end
    local fn = commands[word]
    if not fn then return "unknown command '" .. word .. "' (help)" end
    local args = {}
    for x in rest:gmatch("%S+") do args[#args + 1] = x end
    if word == "lua" then
        local okE, r = pcall(load, "return " .. rest, "=dev", "t", env)
        if okE and r then
            local res = table.pack(pcall(r))
            if res[1] then
                local parts = {}
                for i = 2, res.n do parts[#parts + 1] = H.fmt(res[i]) end
                return table.concat(parts, "\t")
            end
            return "error: " .. tostring(res[2])
        end
    end
    local ok, r = pcall(fn, args, rest)
    if not ok then return "error: " .. tostring(r) end
    return r
end

local function writeFile(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function pollCommandFile()
    local f = io.open(DIR .. "cmd.txt", "r")
    if not f then return end
    local all = f:read("*a") or ""
    f:close()
    os.remove(DIR .. "cmd.txt")
    local id, body = all:match("^([^\r\n]*)\r?\n(.*)$")
    if not id then id, body = "?", all end
    outBuf = {}
    local t0 = os.clock()
    local res = runCommand(body)
    local lines = outBuf
    outBuf = nil
    if res ~= nil and res ~= "" then lines[#lines + 1] = tostring(res) end
    writeFile(DIR .. "out.txt", "@" .. id .. "\n" .. table.concat(lines, "\n") .. "\n@end\n")
    log("cmd %s: %s (%.0f ms)", id, (body:gsub("\n.*", " ...")):sub(1, 80), (os.clock() - t0) * 1000)
end

-- ---------------------------------------------------------------- config, loops, keys
local cfg = { open = nil, god = false }
do
    local f = io.open(DIR .. "dev.txt", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^%s*(%S+)%s*(.-)%s*$")
            if k == "open" and v ~= "" then cfg.open = v end
            if k == "god" then cfg.god = true end
        end
        f:close()
    end
end
god = cfg.god
local opened = false
os.remove(DIR .. "out.txt")

LoopInGameThreadWithDelay(250, function()
    local ok, e = pcall(pollCommandFile)
    if not ok then
        outBuf = nil
        log("command error: %s", tostring(e))
        writeFile(DIR .. "out.txt", "@?\ninternal error: " .. tostring(e) .. "\n@end\n")
    end
    if god then pcall(godTick) end
    if cfg.open and not opened then
        local w = UEHelpers.GetWorld()
        if valid(w) and w:GetFullName():find("RB_MainMenu", 1, true) then
            opened = true
            ExecuteInGameThreadWithDelay(3000, function()
                log("dev.txt: open %s", cfg.open)
                H.console("open " .. cfg.open)
            end)
        end
    end
end)

local function onGameThread(fn)
    return function()
        ExecuteInGameThread(function()
            local ok, r = pcall(fn)
            log("%s", ok and tostring(r) or ("key error: " .. tostring(r)))
        end)
    end
end
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, onGameThread(function() god = not god; return "god " .. tostring(god) end))
RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, onGameThread(carFix))
RegisterKeyBind(Key.F11, { ModifierKey.CONTROL }, onGameThread(stateText))

log("loaded: command file %scmd.txt, keys Ctrl+F9 god, Ctrl+F10 car, Ctrl+F11 state", DIR)
