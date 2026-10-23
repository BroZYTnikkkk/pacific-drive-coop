-- PDCoopNet v7: Pacific Drive co-op (carsync.lua: trunk, car state, player 2 inventory save; itemstate.lua: item
-- fuel/charge/durability/health; downed.lua: down / revive / team death).
-- Role comes from ue4ss/Mods/PDCoopNet/role.txt (line 1: host|client|off, line 2: map or address,
-- line 3: scenario play|car|rejoincar|travel|gametravel|lootprobe|itemprobe|channel|loot, default play).
-- play: no test bots. Keys: F8 host = host the current map (servertravel ?listen), F8 client = connect to the
-- host in line 2; F6 client = sit in the host's car as passenger, F7 client = get out.
-- The other scenarios are automated tests driven by bots (tools/run_test.ps1).
-- The host also "re-hosts": when the game itself travels (native code, no ?listen) after clients were
-- connected, the host lands standalone; it then servertravels to the same map with ?listen and clients rejoin.
-- host:   opens <map>?listen; spawns and possesses a main character for every remote PlayerController
--         without one; nudges its own pawn every 5 s (movement replication check).
-- client: opens <address>; removes the locally spawned duplicate player car and points the local
--         managers at the replicated car / own character; walks forward in bursts (client -> host check).
-- Both log one "PDNET|" status line every 5 s for the test harness to parse.
local UEHelpers = require("UEHelpers")
local TAG = "[PDCoopNet] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

local function readRole()
    local f = io.open("ue4ss/Mods/PDCoopNet/role.txt", "r")
    if not f then return "off", nil end
    local role = (f:read("*l") or "off"):gsub("%s+", "")
    local arg = f:read("*l"); if arg then arg = arg:gsub("%s+", "") end
    local scenario = f:read("*l"); if scenario then scenario = scenario:gsub("%s+", "") end
    f:close()
    return role, arg, (scenario ~= nil and scenario ~= "") and scenario or "play"
end

local ROLE, ARG, SCENARIO = readRole()

-- Feature switches: ue4ss/Mods/PDCoopNet/features.txt, one "<name> = on|off" per line; missing = on.
-- itemstate (item fuel/charge/durability/health over the network), trunk (shared trunk), carstate (car part
-- health/fuel/battery follow the host), refuel (player 2's refuel/charge reach the host), invsave (player 2's
-- inventory saved on the host), downed (down instead of dead, revive, team death), worldrep (the host's generated
-- zone content: abandoned cars, props, barrels... replicated to player 2), doors (zone doors open / closed as on
-- the host, player 2's E on a door runs on the host), loot (lootable containers hold the host's items).
local FEATURES = { itemstate = true, trunk = true, carstate = true, refuel = true, invsave = true, downed = true,
                   worldrep = true, doors = true, loot = true, bodyanim = true, bodycolor = true, hazards = true }
do
    local f = io.open("ue4ss/Mods/PDCoopNet/features.txt", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(%a+)")
            if k and FEATURES[k] ~= nil then FEATURES[k] = (v:lower() == "on" or v:lower() == "true" or v == "1") end
        end
        f:close()
    end
end
local function feature(name) return FEATURES[name] == true end
local CAR_LIKE = (SCENARIO == "car" or SCENARIO == "rejoincar")
local BOTS = (SCENARIO ~= "play")       -- test bots: auto-open/connect, walking, nudges, the bot driver
local droppedOnce = false   -- rejoincar: the client disconnects itself once while riding
local CHARACTER_CLASS = "PDP_MainCharacter_C"
local CAR_CLASS = "BaseNewCar"    -- base class of every player car (BP_PlayerCarNew_C, BP_PlayerCar_Intro_C, ...)
local ROLE_AUTHORITY, ROLE_SIMULATED = 3, 1
local tick = 0
local spawnedFor = {}      -- PlayerController full name -> true
local dedupeState = {}     -- local duplicate car full name -> "destroy-tried" | "neutralized"
local reportedDupes = false
local walking = false

-- Destroyed actors stay findable until garbage collection; treat PendingKill objects as gone.
local baseCarClass = nil
local function isCar(o)
    if o == nil or not o:IsValid() then return false end
    baseCarClass = baseCarClass or StaticFindObject("/Script/PenDriverPro.BaseNewCar")
    local ok, r = pcall(function() return o:IsA(baseCarClass) end)
    return ok and r
end

local function valid(o)
    if o == nil or not o:IsValid() then return false end
    local ok, dead = pcall(function() return o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end)
    return not (ok and dead)
end
local function className(o) return o:GetClass():GetFName():ToString() end
-- the item instance of an item actor, or nil: a pooled (returned) item actor has none, and reading a field of the
-- missing instance crashes natively (access violation at 0x18, dev session 2026-10-22), which pcall cannot catch
local function instanceOf(actor)
    if actor == nil or not actor:IsValid() then return nil end
    local inst = nil
    pcall(function() inst = actor.Instance end)
    if inst == nil or not inst:IsValid() then return nil end
    return inst
end
local function objName(o) return valid(o) and o:GetFName():ToString() or "nil" end

local function inGameplayMap()
    local w = UEHelpers.GetWorld()
    return valid(w) and not w:GetFullName():find("RB_MainMenu", 1, true)
end

local function localController()
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and pc:IsLocalController() then return pc end
    end
end

local function fmtLoc(a)
    local ok, l = pcall(function() return a:K2_GetActorLocation() end)
    if not ok or not l then return "?" end
    return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
end

local function console(cmd)
    log("console: %s", cmd)
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(UEHelpers.GetWorldContextObject(), cmd, localController())
end

local function managers()
    return FindFirstOf("BP_MainCharacterManager_C"), FindFirstOf("BP_CarManager_C")
end

-- ---------------------------------------------------------------- status
-- Bodies. PDP_MainCharacter's mesh is the ALS mannequin with the invisible M_PlayerCharacter_Invist material.
-- Other players' characters get a real material on every machine; your own stays invisible (first person).
-- "Mine" is not "locally controlled": while driving, the host controls the car and its character has no
-- controller, so the old check showed the host its own body in the driver's seat. Mine = the pawn of my
-- controller or the character my BP_MainCharacterManager points at.
-- Characters sitting in a car are lowered (there is no sitting animation) and do not collide with the car.
local BODY_MATERIAL = "/Engine/EngineMaterials/DefaultMaterial.DefaultMaterial"     -- without PDCoopNet.pak
-- our body material (PDCoopNet.pak) with one colour per player: the host orange, player 2 blue, then green, purple
local BODY_COLOR_MATERIAL = "/Game/Mods/PDCoopNet/M_PDCoopBody.M_PDCoopBody"
local BODY_COLORS = { { R = 0.85, G = 0.35, B = 0.05, A = 1 }, { R = 0.1, G = 0.35, B = 0.9, A = 1 },
                      { R = 0.15, G = 0.7, B = 0.2, A = 1 }, { R = 0.55, G = 0.15, B = 0.75, A = 1 } }
local SEATED_DROP = 50       -- uu the mannequin mesh is lowered while sitting in a car
local bodies = {}            -- character full name -> body state
local bodySitting = function() return false end   -- set to BodyAnim.isSitting once bodyanim.lua is loaded
local bodyMat = nil
local bodyColorMat = nil     -- false: not in the pak
-- checked every time: nothing of ours references the loaded asset, so it is collected after a map change (exp132:
-- player 2 crashed after rejoining, a material instance made from the freed material)
local function bodyColorMaterial()
    if bodyColorMat and not valid(bodyColorMat) then bodyColorMat = nil end
    if bodyColorMat == nil then
        local m = StaticFindObject(BODY_COLOR_MATERIAL)
        if not valid(m) then
            local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
            pcall(function() m = arh:GetAsset({ ObjectPath = UEHelpers.FindOrAddFName(BODY_COLOR_MATERIAL) }) end)
        end
        bodyColorMat = valid(m) and m or false
        if not bodyColorMat then log("BODY %s not found: grey bodies", BODY_COLOR_MATERIAL) end
    end
    return bodyColorMat or nil
end
-- 1 = the host, 2.. = the other players by PlayerId
local function bodyColorIndex(ch)
    local host = false
    if ROLE == "host" then
        pcall(function() host = not (valid(ch.Controller) and not ch.Controller:IsLocalController()) end)
    else
        local okR, r = pcall(function() return ch.Role end)
        host = okR and r == 1
    end
    if host then return 1 end
    local pid = 0
    pcall(function() pid = ch.PlayerState.PlayerId end)
    return 2 + (pid % 3)
end

local function isMyCharacter(ch)
    local name = ch:GetFullName()
    local lpc = localController()
    if valid(lpc) and valid(lpc.Pawn) and lpc.Pawn:GetFullName() == name then return true end
    if ROLE == "client" then
        -- on a client the manager first points at the host's character (the first one that arrives, exp44);
        -- the client's own character is the autonomous proxy, also while it sits in the car
        local okR, r = pcall(function() return ch.Role end)
        return okR and r == 2
    end
    -- on the host every character not controlled by a remote player is the host's own (the parked driver has no
    -- controller; the manager briefly points at a newly spawned player 2, exp48)
    local okC, remote = pcall(function() return valid(ch.Controller) and not ch.Controller:IsLocalController() end)
    return not (okC and remote)
end

local function logBodyStates()
    for _, ch in ipairs(FindAllOf(CHARACTER_CLASS) or {}) do
        -- characters the body update has not seen yet (it runs every 200 ms) have no state to report
        if valid(ch) and not isMyCharacter(ch) and bodies[ch:GetFullName()] then
            local seated, hid, rendered, matName = false, "?", "?", "?"
            pcall(function() seated = isCar(ch:GetAttachParentActor()) end)
            pcall(function() hid = tostring(ch.bHidden) end)
            pcall(function() rendered = tostring(ch.Mesh:WasRecentlyRendered(0.5)) end)
            pcall(function() matName = ch.Mesh:GetMaterial(0):GetFName():ToString() end)
            log("BODYSTATE|%s|%s|seated=%s|hidden=%s|rendered=%s|mat=%s|%s", ROLE, objName(ch), tostring(seated), hid, rendered, matName, fmtLoc(ch))
        end
    end
end

local function updateBodies()
    for _, ch in ipairs(FindAllOf(CHARACTER_CLASS) or {}) do
        if valid(ch) then
            local key = ch:GetFullName()
            local mesh = ch.Mesh
            local b = bodies[key]
            if not b then
                local rl = mesh.RelativeLocation
                b = { orig0 = mesh:GetMaterial(0), orig1 = mesh:GetMaterial(1), rel = { X = rl.X, Y = rl.Y, Z = rl.Z },
                      state = "new", applied = 0 }
                bodies[key] = b
            end
            local mine = isMyCharacter(ch)
            if mine then
                if b.state == "shown" then
                    mesh:SetMaterial(0, b.orig0)
                    mesh:SetMaterial(1, b.orig1)
                    mesh:SetCastShadow(false)
                    log("BODY %s is mine: invisible again", objName(ch))
                end
                b.state = "own"
            else
                local cur = mesh:GetMaterial(0)
                -- the colour material belongs to the mesh it was made on
                local meshAddr = mesh:GetAddress()
                if b.midMesh ~= meshAddr then b.mid = nil end
                local want = b.mid
                if not valid(want) and FEATURES.bodycolor then
                    local base = bodyColorMaterial()
                    if base then
                        local okM, mid = pcall(function() return mesh:CreateDynamicMaterialInstance(0, base, UEHelpers.FindOrAddFName("None")) end)
                        if okM and valid(mid) then
                            local ci = bodyColorIndex(ch)
                            pcall(function() mid:SetVectorParameterValue(UEHelpers.FindOrAddFName("Color"), BODY_COLORS[ci]) end)
                            b.mid, b.midMesh, want = mid, meshAddr, mid
                            log("BODY %s colour %d", objName(ch), ci)
                        end
                    end
                end
                if not valid(want) then
                    bodyMat = bodyMat or LoadAsset(BODY_MATERIAL)
                    want = bodyMat
                end
                if not (valid(cur) and cur:GetFullName() == want:GetFullName()) then
                    mesh:SetMaterial(0, want)
                    mesh:SetMaterial(1, want)
                    mesh:SetCastShadow(true)
                    b.applied = b.applied + 1
                    log("BODY %s visible (%s), applied %d time(s)%s", objName(ch), want:GetFName():ToString(), b.applied,
                        b.applied > 1 and ": the game had reset it" or "")
                end
                b.state = "shown"
                local hid = false
                pcall(function() hid = ch.bHidden end)
                if hid then
                    ch:SetActorHiddenInGame(false)
                    b.unhid = (b.unhid or 0) + 1
                    if b.unhid == 1 or b.unhid % 30 == 0 then
                        log("BODY %s was hidden by the game: shown again (%d times)", objName(ch), b.unhid)
                    end
                end
                pcall(function() mesh:SetHiddenInGame(false, false) end)
                -- a sitting body shows its poseable copy instead (bodyanim.lua)
                if not (feature("bodyanim") and bodySitting(ch)) then pcall(function() mesh:SetVisibility(true, false) end) end
            end
            -- sitting in a car
            local seated = false
            pcall(function() seated = isCar(ch:GetAttachParentActor()) end)
            if seated and not mine and not b.lowered then
                mesh:K2_SetRelativeLocation({ X = b.rel.X, Y = b.rel.Y, Z = b.rel.Z - SEATED_DROP }, false, {}, true)
                b.lowered = true
                log("BODY %s seated: mesh lowered %d uu", objName(ch), SEATED_DROP)
            elseif not seated and b.lowered then
                mesh:K2_SetRelativeLocation({ X = b.rel.X, Y = b.rel.Y, Z = b.rel.Z }, false, {}, true)
                b.lowered = false
                log("BODY %s left the car: mesh back", objName(ch))
            end
            if seated and not b.collisionOff then
                ch:SetActorEnableCollision(false)
                b.collisionOff = true
                log("BODY %s seated: collision off (mine=%s)", objName(ch), tostring(mine))
            elseif not seated and b.collisionOff then
                ch:SetActorEnableCollision(true)
                b.collisionOff = false
                log("BODY %s left the car: collision on", objName(ch))
            end
        end
    end
end

-- in-game screenshot (HighResShot writes PNGs to <instance>/PenDriverPro/Saved/Screenshots/WindowsNoEditor)
local function screenshot(tagText)
    log("SHOT %s", tagText)
    console("HighResShot 1")
end

-- turn this machine's camera to the other player's character and take a screenshot
local hostShots = {}
local function lookAndShoot(key, tagText)
    if hostShots[key] then return end
    local lpc = localController()
    if not valid(lpc) then return end
    for _, ch in ipairs(FindAllOf(CHARACTER_CLASS) or {}) do
        if valid(ch) and not isMyCharacter(ch) then
            hostShots[key] = true
            local camLoc = lpc.PlayerCameraManager:GetCameraLocation()
            local target = ch:K2_GetActorLocation()
            local rot = UEHelpers.GetKismetMathLibrary():FindLookAtRotation(camLoc, target)
            lpc:SetControlRotation(rot)
            log("SHOT aiming at %s (%.0f uu away)", objName(ch), math.sqrt((camLoc.X - target.X) ^ 2 + (camLoc.Y - target.Y) ^ 2 + (camLoc.Z - target.Z) ^ 2))
            ExecuteInGameThreadWithDelay(400, function() screenshot(tagText) end)
            return
        end
    end
end
local function hostLookAndShoot(key, tagText) lookAndShoot(key, tagText) end

local function logCamRel(car, tagText)
    local lpc = localController()
    if not (valid(lpc) and isCar(car)) then return end
    local ok, err = pcall(function()
        local cam = lpc.PlayerCameraManager:GetCameraLocation()
        local rel = UEHelpers.GetKismetMathLibrary():InverseTransformLocation(car:GetTransform(), cam)
        log("CAMREL|%s|%s|%.0f,%.0f,%.0f", ROLE, tagText, rel.X, rel.Y, rel.Z)
    end)
    if not ok then log("CAMREL failed: %s", tostring(err)) end
end

local function shootForward(car, tagText)
    local lpc = localController()
    if not (valid(lpc) and isCar(car)) then return end
    lpc:SetControlRotation(car:K2_GetActorRotation())
    ExecuteInGameThreadWithDelay(400, function() screenshot(tagText) end)
end

-- loot probe: list every active world item (AItemWorldManifestation and subclasses, not the ones in a pool)
local function dumpLoot(tagText)
    local n, pooled, reps = 0, 0, 0
    local byArch = {}
    for _, a in ipairs(FindAllOf("ItemWorldManifestation") or {}) do
        if valid(a) then
            local okP, isPooled = pcall(function() return a:IsPooled() end)
            if okP and isPooled then
                pooled = pooled + 1
            else
                n = n + 1
                local arch = "?"
                pcall(function() local i = instanceOf(a); if i then arch = i.Archetype:GetFName():ToString() end end)
                local rep = "?"
                pcall(function() rep = tostring(a.bReplicates); if a.bReplicates then reps = reps + 1 end end)
                byArch[arch] = (byArch[arch] or 0) + 1
                log("LOOT|%s|%s|%s|%s|%s|rep=%s|role=%s", ROLE, tagText, className(a), arch, fmtLoc(a), rep, tostring(a.Role))
            end
        end
    end
    local spawners = #(FindAllOf("BaseItemSpawner") or {})
    log("LOOTSUM|%s|%s|active=%d pooled=%d replicated=%d archetypes=%d spawners=%d", ROLE, tagText, n, pooled, reps,
        (function() local c = 0; for _ in pairs(byArch) do c = c + 1 end; return c end)(), spawners)
end

local function dumpItemsDetailed(tagText)
    local n = 0
    for _, a in ipairs(FindAllOf("ItemWorldManifestation") or {}) do
        if valid(a) then
            n = n + 1
            local arch, pooled, hidden, inst = "?", "?", "?", "?"
            pcall(function() local i = instanceOf(a); if i then arch = i.Archetype:GetFName():ToString() end end)
            pcall(function() pooled = tostring(a:IsPooled()) end)
            pcall(function() hidden = tostring(a.bHidden) end)
            pcall(function() inst = objName(a.Instance) end)
            log("ITEM|%s|%s|%s|arch=%s|inst=%s|pooled=%s|hidden=%s|%s|rep=%s", tagText, objName(a), className(a), arch, inst,
                pooled, hidden, fmtLoc(a), tostring(a.bReplicates))
        end
    end
    log("ITEMSUM|%s|%d world item actors", tagText, n)
end

local TEST_ARCHETYPE = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
local function sampleArchetypes()
    local ok, a = pcall(LoadAsset, TEST_ARCHETYPE)
    log("ARCH LoadAsset ok=%s %s", tostring(ok), (ok and valid(a)) and a:GetFullName() or tostring(a))
    return (ok and valid(a)) and a or nil
end

local testItem = nil       -- the actor spawned by spawnTestItem
local function removeTestItem()
    if not valid(testItem) then log("TESTREMOVE nothing to remove"); return end
    local inst = testItem.Instance
    local ok, res = pcall(function() return inst:Remove(true) end)
    log("TESTREMOVE Instance:Remove(true) ok=%s result=%s actorStillValid=%s", tostring(ok), tostring(res), tostring(valid(testItem)))
end

local function giveTestItemToPlayer(arch)
    local mgr = FindFirstOf("BaseInventoryManager")
    if not (valid(mgr) and valid(arch)) then log("TESTGIVE missing inputs mgr=%s", objName(mgr)); return end
    local ok, err = pcall(function() mgr:GiveItemToPlayer(arch) end)
    log("TESTGIVE %s:GiveItemToPlayer ok=%s %s", objName(mgr), tostring(ok), ok and "" or tostring(err))
end

local function spawnTestItem(arch)
    local inv = FindFirstOf("InventorySystem")
    local lpc = localController()
    if not (valid(inv) and valid(arch) and valid(lpc) and valid(lpc.Pawn)) then log("TESTSPAWN missing inputs"); return end
    local l = lpc.Pawn:K2_GetActorLocation()
    local f = lpc.Pawn:GetActorForwardVector()
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = l.X + f.X * 150, Y = l.Y + f.Y * 150, Z = l.Z + 50 },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, res = pcall(function() return inv:SpawnItemActor(UEHelpers.GetWorldContextObject(), xf, arch, 0, 0) end)
    log("TESTSPAWN SpawnItemActor ok=%s actor=%s at %s", tostring(ok), ok and objName(res) or tostring(res), ok and valid(res) and fmtLoc(res) or "?")
    if ok and valid(res) then testItem = res end
end

local function status()
    tick = tick + 1
    local ksl = UEHelpers.GetKismetSystemLibrary()
    local world = UEHelpers.GetWorld()
    local isServer = "?"
    pcall(function() isServer = tostring(ksl:IsServer(UEHelpers.GetWorldContextObject())) end)
    local conns, serverConn = -1, "none"
    for _, d in ipairs(FindAllOf("IpNetDriver") or {}) do
        if valid(d) then
            pcall(function() conns = d.ClientConnections:GetArrayNum() end)
            pcall(function() if valid(d.ServerConnection) then serverConn = "yes" end end)
        end
    end
    local plist = {}
    local pawns = FindAllOf("Pawn") or {}
    for _, p in ipairs(pawns) do
        if valid(p) then
            local ctrl = valid(p.Controller) and (p.Controller:IsLocalController() and "local" or "remote") or "none"
            local hidden = ""
            pcall(function() if p.bHidden then hidden = "|hidden" end end)
            pcall(function()
                local par = p:GetAttachParentActor()
                if valid(par) then hidden = hidden .. "|att=" .. (objName(par):match("_(%d+)$") or "?") end
            end)
            table.insert(plist, string.format("%s:%s[%s|role=%s|%s%s]", className(p), objName(p):match("_(%d+)$") or "?",
                ctrl, tostring(p.Role), fmtLoc(p), hidden))
        end
    end
    local cm, carm = managers()
    local mgr = string.format("cmChar=%s carMgrCar=%s",
        valid(cm) and objName(cm.CharacterActor) or "nomgr", valid(carm) and objName(carm.NewCarActor) or "nomgr")
    log("PDNET|%s|t=%d|map=%s|server=%s|clientConns=%d|serverConn=%s|pcs=%d|pawns=%d|%s|%s",
        ROLE, tick * 5, valid(world) and world:GetFName():ToString() or "nil", isServer, conns, serverConn,
        #(FindAllOf("PlayerController") or {}), #pawns, mgr, table.concat(plist, " "))
end

-- ---------------------------------------------------------------- host side
local function logGameModeOnce()
    local gm = UEHelpers.GetGameModeBase()
    if not valid(gm) then return end
    local dpc, spect = "?", "?"
    pcall(function() dpc = gm.DefaultPawnClass:GetFName():ToString() end)
    pcall(function() spect = tostring(gm.bStartPlayersAsSpectators) end)
    log("GAMEMODE %s DefaultPawnClass=%s bStartPlayersAsSpectators=%s", className(gm), dpc, spect)
end

local function hostCharacter()
    local pc = localController()
    if valid(pc) and valid(pc.Pawn) and className(pc.Pawn) == CHARACTER_CLASS then return pc.Pawn end
    local cm = managers()
    if valid(cm) and valid(cm.CharacterActor) then return cm.CharacterActor end
end

-- set further down, once seatPassenger exists (Lua locals are only visible after their declaration)
local seatNewPlayerInCar = nil

-- A joining (or re-joining) player always appears next to whatever the host controls right now: the host's
-- character, or the car if the host is driving (then the new player is seated as a passenger). Saved
-- positions, the garage and the map's player start are never used for them.
local function spawnForRemotePlayers()
    local hostChar = hostCharacter()
    if not valid(hostChar) then return end
    local lpc = localController()
    -- the car the host is in: either possessed (driving) or the host character sits attached to it
    -- (the new game intro starts with the player already seated)
    local hostCar = nil
    if valid(lpc) and isCar(lpc.Pawn) then hostCar = lpc.Pawn end
    if not hostCar then
        local okP, par = pcall(function() return hostChar:GetAttachParentActor() end)
        if okP and isCar(par) then hostCar = par end
    end
    local anchor = hostCar or ((valid(lpc) and valid(lpc.Pawn)) and lpc.Pawn or hostChar)
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local key = valid(pc) and pc:GetFullName() or nil
        if key and not pc:IsLocalController() and not spawnedFor[key]
            and not (valid(pc.Pawn) and className(pc.Pawn) == CHARACTER_CLASS) then
            spawnedFor[key] = true
            local cm = managers()
            local before = valid(cm) and cm.CharacterActor or nil
            local l = anchor:K2_GetActorLocation()
            local r = { X = 0, Y = 1, Z = 0 }
            pcall(function() r = anchor:GetActorRightVector() end)
            local side = hostCar and 320 or 250
            local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                         Translation = { X = l.X + r.X * side, Y = l.Y + r.Y * side, Z = l.Z + 60 },
                         Scale3D = { X = 1, Y = 1, Z = 1 } }
            local gs = UEHelpers.GetGameplayStatics()
            local actor = gs:BeginDeferredActorSpawnFromClass(UEHelpers.GetWorldContextObject(), hostChar:GetClass(), xf, 2, nil)
            if valid(actor) then actor = gs:FinishSpawningActor(actor, xf) end
            if not valid(actor) then
                log("SPAWN FAILED for %s", objName(pc))
            else
                local old = pc.Pawn
                pc:Possess(actor)
                if valid(old) and className(old) ~= CHARACTER_CLASS then
                    pcall(function() old:K2_DestroyActor() end)
                end
                log("SPAWNED %s for %s at %s next to %s (%s), possessed=%s", objName(actor), objName(pc), fmtLoc(actor),
                    objName(anchor), fmtLoc(anchor), tostring(valid(pc.Pawn) and pc.Pawn:GetFullName() == actor:GetFullName()))
                if hostCar and seatNewPlayerInCar then
                    -- possession can make the game seat the character itself (intro: into the driver's seat,
                    -- on top of the host), so seat it as passenger once now and once a moment later
                    log("SPAWN host is in %s: seating %s as passenger", objName(hostCar), objName(actor))
                    pcall(updateBodies)
                    pcall(seatNewPlayerInCar, pc, hostCar)
                    local carName = hostCar:GetFullName()
                    ExecuteInGameThreadWithDelay(1500, function()
                        local c = StaticFindObject(carName)
                        if valid(pc) and isCar(c) then pcall(seatNewPlayerInCar, pc, c, true) end
                    end)
                end
            end
            -- The single-player managers keep one character reference: keep it on the host character.
            if valid(cm) and valid(before)
                and not (valid(cm.CharacterActor) and cm.CharacterActor:GetFullName() == before:GetFullName()) then
                log("host CharacterManager switched to %s, restoring %s", objName(cm.CharacterActor), objName(before))
                cm.CharacterActor = before
            end
        end
    end
end

-- ---------------------------------------------------------------- car: host drives, client rides
-- TempSocket_Seat (driver) sits at Y = -45.8 in BP_PlayerCarNew; the mirrored front passenger seat is Y = +45.8
local PASSENGER_SIDE_OFFSET = 91.6
local seated = {}          -- remote character full name -> car full name
local drive = { phase = "wait", t = 0, mode = "throttle", startLoc = nil, lastLoc = nil, frames = 0 }
local EAttachmentRule = { KeepRelative = 0, KeepWorld = 1, SnapToTarget = 2 }

local function playerCar()
    for _, c in ipairs(FindAllOf(CAR_CLASS) or {}) do
        if valid(c) and (ROLE ~= "client" or c.Role == ROLE_SIMULATED) then return c end
    end
end

local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---------------------------------------------------------------- channel (channel.lua)
local fastTick = 0           -- 200 ms ticks of the main loop
local Chan = require("channel")({
    log = log, valid = valid, objName = objName, UEHelpers = UEHelpers, role = ROLE,
    localController = function() return localController() end,
})
local CHAN_MAX, hostMsgHandlers = Chan.CHAN_MAX, Chan.hostMsgHandlers
local hostSend, hostSendLatest, sendCommand, myPlayerId = Chan.hostSend, Chan.hostSendLatest, Chan.sendCommand, Chan.myPlayerId

-- ---------------------------------------------------------------- shared world items (items.lua)
local ITEM_PREFIX = "/Game/Gameplay/Inventory/Items/"
local archCache = {}
local function archShort(path)
    if path:sub(1, #ITEM_PREFIX) == ITEM_PREFIX then return "~" .. path:sub(#ITEM_PREFIX + 1) end
    return path
end
local function archLoad(short)
    local path = (short:sub(1, 1) == "~") and (ITEM_PREFIX .. short:sub(2)) or short
    -- a loaded asset can be collected after a map change: load it again then
    if archCache[path] and not valid(archCache[path]) then archCache[path] = nil end
    if archCache[path] == nil then
        local ok, a = pcall(LoadAsset, path)
        archCache[path] = (ok and valid(a)) and a or false
    end
    return archCache[path] or nil
end

-- item state (fuel, charge, durability, health) carried with items (itemstate.lua)
local ItemState = require("itemstate")({ log = log, valid = valid, feature = feature })

-- game events the sync reacts to (events.lua)
local Events = require("events")({ log = log, valid = valid })
ExecuteInGameThread(function() Events.register() end)

-- shared trunk, car part state, player 2's inventory saved on the host (carsync.lua)
local CarSync = require("carsync")({
    ItemState = ItemState, Events = Events, feature = feature,
    role = function() return ROLE end,
    myPlayerId = function() return myPlayerId() end,
    log = log, valid = valid, UEHelpers = UEHelpers, objName = objName, CHAN_MAX = CHAN_MAX,
    hostSend = function(payload) hostSend(payload) end,
    hostSendLatest = function(payload) hostSendLatest(payload) end,
    sendCommand = function(cmd) sendCommand(cmd) end,
    hostMsgHandlers = hostMsgHandlers, archShort = archShort, archLoad = archLoad,
    playerCar = function() return playerCar() end,
})

-- down instead of dead, revive, team death (downed.lua)
local Downed = require("downed")({
    log = log, valid = valid, UEHelpers = UEHelpers,
    isMine = function(ch) return isMyCharacter(ch) end,
    enabled = function() return feature("downed") end,
    role = function() return ROLE end,
    localController = function() return localController() end,
    myPlayerId = function() return myPlayerId() end,
    sendCommand = function(cmd) sendCommand(cmd) end,
    hostSend = function(payload) hostSend(payload) end,
    hostSendLatest = function(payload) hostSendLatest(payload) end,
    hostMsgHandlers = hostMsgHandlers,
    keyOf = function(inst) return CarSync.keyOf(inst) end,
    addEntries = function(cont, text) return CarSync.addEntries(cont, text) end,
    clientsPresent = function()
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() then return true end
        end
        return false
    end,
})

-- the other player's body animation: walk, run, crouch, jump, lying when down, sitting (bodyanim.lua)
local BodyAnim = require("bodyanim")({
    log = log, valid = valid, UEHelpers = UEHelpers, isCar = isCar, Events = Events,
    isDown = function(ch) return feature("downed") and Downed.isDown(ch) end,
})
bodySitting = function(ch) return BodyAnim.isSitting(ch) end
local function bodyAnimTick()
    if not feature("bodyanim") then return end
    local others = {}
    for _, ch in ipairs(FindAllOf(CHARACTER_CLASS) or {}) do
        if valid(ch) then
            if isMyCharacter(ch) then BodyAnim.forget(ch) else others[#others + 1] = ch end
        end
    end
    BodyAnim.tick(others)
end

-- the host's generated zone content replicated to player 2 by the engine (worldrep.lua)
local WorldRep = require("worldrep")({
    log = log, valid = valid, isCar = isCar, UEHelpers = UEHelpers, CHAN_MAX = CHAN_MAX, Events = Events,
    enabled = function() return feature("worldrep") end,
    hostSend = function(payload) hostSend(payload) end,
    hostMsgHandlers = hostMsgHandlers,
})

-- lootable containers hold the host's items (worldloot.lua)
local WorldLoot = require("worldloot")({
    log = log, valid = valid, CarSync = CarSync, Events = Events,
    enabled = function() return feature("loot") end,
    role = function() return ROLE end,
    sendCommand = function(cmd) sendCommand(cmd) end,
    hostSend = function(payload) hostSend(payload) end,
    hostMsgHandlers = hostMsgHandlers,
})

-- hazards hurt player 2 in player 2's own game (hazards.lua)
local Hazards = require("hazards")({
    log = log, valid = valid, UEHelpers = UEHelpers, Events = Events,
    localController = function() return localController() end,
    enabled = function() return feature("hazards") end,
    hostSend = function(payload) hostSend(payload) end,
    hostMsgHandlers = hostMsgHandlers,
})

-- zone doors follow the host (worlddoors.lua)
local WorldDoors = require("worlddoors")({
    log = log, valid = valid, Events = Events, CHAN_MAX = CHAN_MAX,
    enabled = function() return feature("doors") end,
    role = function() return ROLE end,
    sendCommand = function(cmd) sendCommand(cmd) end,
    hostSend = function(payload) hostSend(payload) end,
    hostMsgHandlers = hostMsgHandlers,
})

-- the host's world items, local copies on the other players' machines (items.lua)
local Items = require("items")({
    log = log, valid = valid, UEHelpers = UEHelpers, ItemState = ItemState,
    archShort = archShort, archLoad = archLoad, instanceOf = instanceOf, className = className, objName = objName,
    dist = dist, role = function() return ROLE end, localController = function() return localController() end,
    hostSend = function(payload) hostSend(payload) end, sendCommand = function(cmd) sendCommand(cmd) end,
    hostMsgHandlers = hostMsgHandlers, refHandlers = Chan.refHandlers,
    hostSession = function() return Chan.hostSession() end, clientChannel = function() return Chan.clientChannel() end,
})

local function seatPassenger(pc, car, force)
    local ch = pc.Pawn
    if not valid(ch) or className(ch) ~= CHARACTER_CLASS then return end
    if seated[ch:GetFullName()] and not force then return end
    pcall(function() ch:K2_DetachFromActor(EAttachmentRule.KeepWorld, EAttachmentRule.KeepWorld, EAttachmentRule.KeepWorld) end)
    local seat = car:K2_GetActorLocation()
    pcall(function() seat = car.TempSocket_Seat:K2_GetComponentLocation() end)
    local right = car:GetActorRightVector()
    local target = { X = seat.X + right.X * PASSENGER_SIDE_OFFSET, Y = seat.Y + right.Y * PASSENGER_SIDE_OFFSET, Z = seat.Z + 10 }
    pcall(function() ch.CharacterMovement:DisableMovement() end)
    ch:SetActorEnableCollision(false)
    ch:K2_SetActorLocation(target, false, {}, true)
    ch:K2_AttachToActor(car, UEHelpers.FindOrAddFName("None"), EAttachmentRule.KeepWorld, EAttachmentRule.KeepWorld,
        EAttachmentRule.KeepWorld, false)
    seated[ch:GetFullName()] = car:GetFullName()
    local parent = ch:GetAttachParentActor()
    log("SEAT %s attached to %s (parent=%s) at %s", objName(ch), objName(car), objName(parent), fmtLoc(ch))
    pcall(updateBodies)
end

seatNewPlayerInCar = seatPassenger

local function unseatPassenger(pc, car)
    local ch = pc.Pawn
    if not valid(ch) or className(ch) ~= CHARACTER_CLASS then return end
    ch:K2_DetachFromActor(EAttachmentRule.KeepWorld, EAttachmentRule.KeepWorld, EAttachmentRule.KeepWorld)
    local l = car:K2_GetActorLocation()
    local r = car:GetActorRightVector()
    ch:K2_SetActorLocation({ X = l.X + r.X * 320, Y = l.Y + r.Y * 320, Z = l.Z + 80 }, false, {}, true)
    ch:SetActorEnableCollision(true)
    pcall(function() ch.CharacterMovement:SetMovementMode(1, 0) end)   -- MOVE_Walking
    seated[ch:GetFullName()] = nil
    log("UNSEAT %s detached from %s, now at %s (parent=%s)", objName(ch), objName(car), fmtLoc(ch), objName(ch:GetAttachParentActor()))
end

-- client commands, every scenario including play (called from the channel's ServerSend hook)
Chan.setCommandHandler(function(pc, cmd, seq)
    local kind, args = cmd:match("^([^,]+),?(.*)$")
    log("CMD received #%d %s from %s", seq, cmd:sub(1, 120), objName(pc))
    local car = playerCar()
    if valid(car) and kind == "SEAT" then seatPassenger(pc, car)
    elseif valid(car) and kind == "UNSEAT" then unseatPassenger(pc, car)
    elseif kind == "PICKUP" or kind == "DROP" then Items.hostCommand(kind, args, pc)
    elseif kind == "PINGBACK" then Chan.hostPingBack(args)
    elseif not CarSync.hostCommand(kind, args, pc) and not Downed.hostCommand(kind, args, pc)
        and not WorldDoors.hostCommand(kind, args) and not WorldLoot.hostCommand(kind, args) then
        log("CMD unknown %s", tostring(kind))
    end
end)

-- The game seats "the player" with PDP_MainCharacter_C.GetCarAttachTransformForCharacter (the driver's seat),
-- e.g. at the start of a new game it put player 2 into the driver's seat on top of the host (exp26).
-- 1) post-hook that function and move the result to the passenger side for player 2;
-- 2) a keeper on the host that re-seats player 2 if it still ends up inside the host.
local function isPlayerTwo(ch)
    local okC, localCtl = pcall(function() return valid(ch.Controller) and ch.Controller:IsLocalController() end)
    if not okC then return false end
    if ROLE == "host" then return valid(ch.Controller) and not localCtl end
    return localCtl == true
end

local seatHookDone = false
local seatHookCalls = 0
local function registerSeatHook()
    if seatHookDone then return end
    local any = FindFirstOf(CHARACTER_CLASS)
    if not valid(any) then return end
    seatHookDone = true
    local cls = any:GetClass():GetFullName():match("%s(%S+)$")
    local path = cls .. ":GetCarAttachTransformForCharacter"
    local ok, err = pcall(function()
        RegisterHook(path, function(ctx, transformParam)
            local ch = ctx:get()
            if not valid(ch) or not isPlayerTwo(ch) then return end
            local car = playerCar()
            if not valid(car) then return end
            local okT, errT = pcall(function()
                local t = transformParam:get()
                local r = car:GetActorRightVector()
                local before = string.format("%.0f,%.0f,%.0f", t.Translation.X, t.Translation.Y, t.Translation.Z)
                t.Translation.X = t.Translation.X + r.X * PASSENGER_SIDE_OFFSET
                t.Translation.Y = t.Translation.Y + r.Y * PASSENGER_SIDE_OFFSET
                transformParam:set(t)
                -- the game asks every frame while seated: log the first call and then every 600th
                seatHookCalls = seatHookCalls + 1
                if seatHookCalls % 600 == 1 then
                    local after = transformParam:get()
                    log("SEATHOOK %s driver seat %s -> passenger %.0f,%.0f,%.0f (call %d)", objName(ch), before,
                        after.Translation.X, after.Translation.Y, after.Translation.Z, seatHookCalls)
                end
            end)
            if not okT then log("SEATHOOK %s could not change the transform: %s", objName(ch), tostring(errT)) end
        end)
    end)
    log("SEATHOOK register %s ok=%s %s", path, tostring(ok), ok and "" or tostring(err))
end

local keeperStarted = false
local function startSeatKeeper()
    if keeperStarted or ROLE ~= "host" then return end
    keeperStarted = true
    LoopInGameThreadWithDelay(1000, function()
        local hostChar = hostCharacter()
        if not valid(hostChar) then return end
        local okP, par = pcall(function() return hostChar:GetAttachParentActor() end)
        local lpc = localController()
        local car = (okP and isCar(par)) and par or ((valid(lpc) and isCar(lpc.Pawn)) and lpc.Pawn or nil)
        if not car then return end
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() and valid(pc.Pawn) and className(pc.Pawn) == CHARACTER_CLASS then
                local d = dist(pc.Pawn:K2_GetActorLocation(), hostChar:K2_GetActorLocation())
                if d < 40 then
                    log("KEEPER %s is inside the host (%.0f uu), re-seating as passenger", objName(pc.Pawn), d)
                    pcall(seatPassenger, pc, car, true)
                end
            end
        end
    end)
end

local function carStateString(car)
    local _, carm = managers()
    local ign, gear, poss, engine = "?", "?", "?", "?"
    pcall(function() ign = tostring(carm.CarIgnitionState) end)
    pcall(function() gear = tostring(carm.MyCarGearBox) end)
    pcall(function() engine = tostring(car.EngineOn) end)
    pcall(function() local pc = localController(); poss = tostring(valid(pc.Pawn) and pc.Pawn:GetFullName() == car:GetFullName()) end)
    local sim, awake, att = "?", "?", "?"
    pcall(function() sim = tostring(car.Chassis:IsSimulatingPhysics(UEHelpers.FindOrAddFName("None"))) end)
    pcall(function() awake = tostring(car.Chassis:IsAnyRigidBodyAwake()) end)
    pcall(function()
        local list = {}
        car:GetAttachedActors(list, true)
        local names = {}
        for _, a in ipairs(list) do local o = (type(a) == "userdata" and a.get) and a:get() or a; table.insert(names, objName(o)) end
        att = #names .. ":" .. table.concat(names, ",")
    end)
    return string.format("ign=%s gear=%s engineOn=%s hostPossessesCar=%s chassisSim=%s awake=%s attached=%s", ign, gear, engine, poss, sim, awake, att)
end

-- Blueprint classes here often have a delegate property and a function with the same name
-- (CommandEnterCar); obj:Name() then resolves to the delegate. Call the UFunction object directly.
local function callBPFunction(obj, fname, ...)
    local cls = obj:GetClass():GetFullName():match("%s(%S+)$")
    local fn = StaticFindObject(cls .. ":" .. fname)
    if not valid(fn) then error("UFunction not found: " .. cls .. ":" .. fname) end
    return fn(obj, ...)
end

local function hostPossessesCar(car)
    local pc = localController()
    return valid(pc) and valid(pc.Pawn) and pc.Pawn:GetFullName() == car:GetFullName()
end

local function hostEnterAndStart(car)
    local cm = managers()
    log("DRIVE before enter: %s", carStateString(car))
    -- The manager only has a CommandEnterCar delegate; the real function lives on PDP_MainCharacter_C.
    local ok, err = pcall(function() callBPFunction(hostCharacter(), "CommandEnterCar", true, nil, false) end)
    log("DRIVE PDP_MainCharacter.CommandEnterCar ok=%s %s", tostring(ok), ok and "" or tostring(err))
    ExecuteInGameThreadWithDelay(2500, function()
            local car = playerCar(); if not valid(car) then return end
            if hostPossessesCar(car) then log("DRIVE host is in the car via CommandEnterCar"); return end
            local okD, errD = pcall(function()
                callBPFunction(car, "BndEvt__Highlight_EnterDoor_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature",
                    car.Highlight_EnterDoor, nil)
            end)
            log("DRIVE door interact fallback ok=%s %s", tostring(okD), okD and "" or tostring(errD))
    end)
    ExecuteInGameThreadWithDelay(5000, function()
            local car = playerCar(); if not valid(car) then return end
            if hostPossessesCar(car) then return end
            local pc = localController()
            local okP, errP = pcall(function() pc:Possess(car) end)
            local _, carm = managers()
            pcall(function() callBPFunction(carm, "Register Car Possessed", true) end)
            log("DRIVE Possess fallback ok=%s %s possessed=%s", tostring(okP), okP and "" or tostring(errP), tostring(hostPossessesCar(car)))
    end)
    pcall(function() car:SetReplicateMovement(true) end)
    ExecuteInGameThreadWithDelay(7000, function()
            local car = playerCar(); if not valid(car) then return end
            local ok2, err2 = pcall(function() car:ManualSetIgnition_NoAnim(2) end)
            local ok3, err3 = pcall(function() car:ManualActivate_Gearbox(1, true) end)
            pcall(function() car.VehicleController:SetParkingBrakeActive(false) end)
            log("DRIVE ignition ok=%s %s gearbox ok=%s %s -> %s", tostring(ok2), ok2 and "" or tostring(err2),
                tostring(ok3), ok3 and "" or tostring(err3), carStateString(car))
            drive.phase = "throttle"
            drive.startLoc = car:K2_GetActorLocation()
            drive.lastLoc = drive.startLoc
            drive.t = 0
    end)
end

-- Runs every frame while driving: forward 4 s, back 4 s, so the car stays inside the garage area.
local function driveFrame(car)
    drive.frames = drive.frames + 1
    local phaseFrames = 250
    local dir = (math.floor(drive.frames / phaseFrames) % 2 == 0) and 1.0 or -1.0
    if drive.mode == "throttle" then
        pcall(function() car:AccelerateBrake(dir) end)
        pcall(function() car:DriveControl(dir) end)
        pcall(function() car.VehicleController.ThrottleInput = dir end)
    end
end

local function hostCarTick()
    local car = playerCar()
    if not valid(car) then return end
    if drive.phase == "wait" then
        local any = false
        for _ in pairs(seated) do any = true end
        if any then drive.phase = "entering"; hostEnterAndStart(car) end
        return
    end
    if drive.phase ~= "throttle" and drive.phase ~= "push" then return end
    drive.t = drive.t + 5
    local loc = car:K2_GetActorLocation()
    local moved = dist(loc, drive.startLoc)
    log("DRIVE t=%d mode=%s carLoc=%s movedFromStart=%.0f %s", drive.t, drive.mode, fmtLoc(car), moved, carStateString(car))
    if drive.mode == "throttle" and drive.t == 10 and moved < 50 then
        -- maybe enum value 1 is not Drive: try the other gearbox state once
        local okG = pcall(function() car:ManualActivate_Gearbox(0, true) end)
        log("DRIVE no movement with gear=1, switched gearbox to 0 ok=%s -> %s", tostring(okG), carStateString(car))
    end
    if drive.mode == "throttle" and drive.t >= 20 and moved < 100 then
        drive.mode = "push"
        log("DRIVE throttle did not move the car (%.0f uu in 20 s); falling back to host-side physics impulses", moved)
    end
    if drive.mode == "push" then
        -- velocity-change impulse on the simulated chassis: the car rolls under physics, as in real driving
        local fwd = car:GetActorForwardVector()
        local s = (math.floor(drive.t / 20) % 2 == 0) and 400 or -400
        local okI, errI = pcall(function()
            car.Chassis:AddImpulse({ X = fwd.X * s, Y = fwd.Y * s, Z = 0 }, UEHelpers.FindOrAddFName("None"), true)
        end)
        if not okI then log("DRIVE impulse error: %s", tostring(errI)) end
        local v = { X = 0, Y = 0, Z = 0 }
        pcall(function() v = car:GetVelocity() end)
        log("DRIVE push impulse=%d speed=%.0f", s, math.sqrt(v.X * v.X + v.Y * v.Y))
    end
    drive.lastLoc = loc
end

local driveLoopStarted = false
local function ensureDriveLoop()
    if driveLoopStarted then return end
    driveLoopStarted = true
    -- game-thread loop: LoopAsync runs on its own thread and touched Lua state concurrently (client crash in exp9)
    LoopInGameThreadWithDelay(16, function()
        if drive.phase == "throttle" and drive.mode == "throttle" then
            local car = playerCar()
            if valid(car) then pcall(driveFrame, car) end
        end
    end)
end

local seatRequested = false
local charTicks = 0        -- status ticks the client has had its own character (walk test first, then ride)
local clientSeated = false
local rideTicks = 0
local unseatSent = false
local rideLoop = nil       -- per-frame loop that keeps the client's kinematic car on the replicated transform
local function clientCarTick()
    local pc = localController()
    if not valid(pc) or not valid(pc.Pawn) or className(pc.Pawn) ~= CHARACTER_CLASS then return end
    local ch = pc.Pawn
    local car = playerCar()
    local parent = ch:GetAttachParentActor()
    if valid(parent) and not clientSeated then
        -- Riding. The server attached us; on the client (1) stop our own movement component so it neither
        -- predicts nor gets corrected, and (2) make the replicated car kinematic so the client does not
        -- run its own physics against replication. The seat offset itself comes from the server's replicated
        -- attachment; re-seating locally computed the offset from a bad car transform read during the
        -- kinematic switch (exp17: passenger rode along at a constant 16506 uu from the car).
        clientSeated = true
        pcall(function() ch.CharacterMovement:DisableMovement() end)
        pcall(function() ch.CharacterMovement:SetComponentTickEnabled(false) end)
        pcall(function() ch:SetActorEnableCollision(false) end)
        local okK = pcall(function() parent.Chassis:SetSimulatePhysics(false) end)
        local okV = pcall(function() parent.VehicleController:SetComponentTickEnabled(false) end)
        -- put the now kinematic car on the replicated transform in this same frame (exp19: one sample with the
        -- car at a bogus position right after the switch)
        pcall(function()
            local rm = parent.ReplicatedMovement
            parent:K2_SetActorLocationAndRotation({ X = rm.Location.X, Y = rm.Location.Y, Z = rm.Location.Z },
                { Pitch = rm.Rotation.Pitch, Yaw = rm.Rotation.Yaw, Roll = rm.Rotation.Roll }, false, {}, true)
        end)
        -- and put ourselves at the server's attach offset in this frame too (exp21: one sample with the
        -- passenger at a bogus position right when the attachment arrived)
        local okA = pcall(function()
            local ar = ch.AttachmentReplication
            ch:K2_SetActorRelativeLocation({ X = ar.LocationOffset.X, Y = ar.LocationOffset.Y, Z = ar.LocationOffset.Z }, false, {}, true)
            ch:K2_SetActorRelativeRotation({ Pitch = ar.RotationOffset.Pitch, Yaw = ar.RotationOffset.Yaw, Roll = ar.RotationOffset.Roll }, false, {}, true)
        end)
        log("RIDE riding: carKinematic=%s vehicleTickOff=%s attachOffsetApplied=%s parent=%s", tostring(okK), tostring(okV), tostring(okA), objName(parent))
        -- A kinematic body ignores physics replication, so drive its transform from the replicated
        -- movement struct every frame (the host stays the only simulation of the car).
        rideLoop = LoopInGameThreadWithDelay(16, function()
            local car = playerCar()
            if not valid(car) then return end
            pcall(function()
                local rm = car.ReplicatedMovement
                car:K2_SetActorLocationAndRotation({ X = rm.Location.X, Y = rm.Location.Y, Z = rm.Location.Z },
                    { Pitch = rm.Rotation.Pitch, Yaw = rm.Rotation.Yaw, Roll = rm.Rotation.Roll }, false, {}, true)
            end)
        end)
    elseif not valid(parent) and clientSeated then
        -- the host detached us (UNSEAT): walk again
        clientSeated = false
        pcall(function() ch.CharacterMovement:SetComponentTickEnabled(true) end)
        pcall(function() ch:SetActorEnableCollision(true) end)
        pcall(function() ch.CharacterMovement:SetMovementMode(1, 0) end)
        log("RIDE left the car, walking at %s", fmtLoc(ch))
    elseif not valid(parent) and not seatRequested then
        charTicks = charTicks + 1
    end
    if CAR_LIKE and not droppedOnce and not valid(parent) and not seatRequested and charTicks >= 6 then
        seatRequested = true
        sendCommand("SEAT")
    end
    if valid(car) then
        log("RIDE parent=%s charLoc=%s carLoc=%s charToCar=%.0f", objName(parent), fmtLoc(ch), fmtLoc(car),
            dist(ch:K2_GetActorLocation(), car:K2_GetActorLocation()))
    end
    if valid(parent) then
        rideTicks = rideTicks + 1
        -- player 2 rides with a free camera (owner's rule): in the new-game intro its game locked the look input
        -- and sat it in the driver's seat (playtest 2026-10-21)
        pcall(function()
            if pc:IsLookInputIgnored() then
                pc:ResetIgnoreLookInput()
                log("RIDE look input was locked (cutscene?): unlocked")
            end
        end)
        if rideTicks <= 3 then
            local cm = managers()
            local oob, water, pct, carState = "?", "?", "?", "?"
            pcall(function() oob = tostring(cm.IsPlayerOutOfBounds) end)
            pcall(function() water = tostring(cm.InWater) end)
            pcall(function() pct = tostring(ch.PercentInCar) end)
            pcall(function() local _, carm = managers(); carState = tostring(carm.PlayerCarState) end)
            log("RIDEFX outOfBounds=%s inWater=%s percentInCar=%s playerCarState=%s", oob, water, pct, carState)
        end
        if rideTicks == 2 and BOTS then
            logCamRel(parent, "passenger")
            shootForward(parent, "client riding as passenger, looks forward")
        end
    end
    if SCENARIO == "rejoincar" and droppedOnce and not unseatSent and rideTicks >= 6 then
        unseatSent = true
        lookAndShoot("ride-client", "client riding as passenger, looks at the driver")
        log("UNSEATTEST riding again for %d s after the rejoin, asking to get out", rideTicks * 5)
        sendCommand("UNSEAT")
    end
    if SCENARIO == "rejoincar" and not droppedOnce and rideTicks >= 8 then
        droppedOnce = true
        log("DROPTEST riding for %d s, disconnecting on purpose", rideTicks * 5)
        console("disconnect")
    end
end

-- Player 2 pressing E at the car: its game runs CommandEnterCar locally and seats it in the driver's seat of its
-- copy of the car, with no way out (playtest 2026-10-21; reproduced in a dev session: attached to the car, driver's
-- view). The client undoes that with the game's own Exit Car and asks the host to seat it as passenger (SEAT);
-- pressing E again while riding asks to get out (UNSEAT). Player 2 is always the passenger.
local enterHookDone = false
local function registerEnterCarHook()
    if enterHookDone or ROLE ~= "client" then return end
    local any = FindFirstOf(CHARACTER_CLASS)
    if not valid(any) then return end
    enterHookDone = true
    local cls = any:GetClass():GetFullName():match("%s(%S+)$")
    local ok, err = pcall(function()
        RegisterHook(cls .. ":CommandEnterCar", function(ctx)
            local ch = ctx:get()
            if not valid(ch) or not isMyCharacter(ch) then return end
            local wasRiding = clientSeated
            ExecuteInGameThreadWithDelay(600, function()
                if not valid(ch) then return end
                local okX, errX = pcall(function() callBPFunction(ch, "Exit Car", false, false) end)
                if wasRiding then
                    sendCommand("UNSEAT")
                    log("ENTERCAR E while riding: local enter undone (ok=%s), UNSEAT sent", tostring(okX))
                else
                    sendCommand("SEAT")
                    log("ENTERCAR E at the car: local enter undone (ok=%s %s), SEAT sent", tostring(okX), okX and "" or tostring(errX))
                end
            end)
        end)
    end)
    log("ENTERCAR hook %s ok=%s %s", cls .. ":CommandEnterCar", tostring(ok), ok and "" or tostring(err))
end

local function nudgeHostPawn()
    local pc = localController()
    if not valid(pc) or not valid(pc.Pawn) then return end
    local l = pc.Pawn:K2_GetActorLocation()
    local dx = (tick % 2 == 0) and 150 or -150
    pc.Pawn:K2_SetActorLocation({ X = l.X + dx, Y = l.Y, Z = l.Z }, false, {}, true)
end

-- ---------------------------------------------------------------- client side
local function dedupeCar()
    local replicatedBy, locals = {}, {}
    for _, c in ipairs(FindAllOf(CAR_CLASS) or {}) do
        if valid(c) then
            if c.Role == ROLE_SIMULATED then replicatedBy[className(c)] = c
            elseif c.Role == ROLE_AUTHORITY then table.insert(locals, c) end
        end
    end
    local replicated = nil
    for _, c in pairs(replicatedBy) do replicated = c end
    if not valid(replicated) then return end
    -- only local copies of a class the host also replicates are duplicates
    local dupes = {}
    for _, c in ipairs(locals) do if replicatedBy[className(c)] then table.insert(dupes, c) end end
    locals = dupes
    for _, c in ipairs(locals) do
        local key = c:GetFullName()
        local state = dedupeState[key]
        if state == nil then
            log("DEDUPE destroying local %s at %s (replicated copy %s at %s)", objName(c), fmtLoc(c), objName(replicated), fmtLoc(replicated))
            dedupeState[key] = "destroy-tried"
            c:K2_DestroyActor()
            log("DEDUPE %s destroyed=%s", key:match("[^%.:]+$") or key, tostring(not valid(c)))
        elseif state == "destroy-tried" then
            dedupeState[key] = "checked"
            local pendingKill, root, hidden = "?", "?", "?"
            pcall(function() pendingKill = tostring(c:HasAnyInternalFlags(EInternalObjectFlags.PendingKill)) end)
            pcall(function() root = tostring(valid(c.RootComponent)) end)
            pcall(function() hidden = tostring(c.bHidden) end)
            log("DEDUPE after destroy: %s pendingKill=%s rootComponent=%s bHidden=%s", objName(c), pendingKill, root, hidden)
            -- Collect live components whatever container type the binding hands back.
            local comps = {}
            local ok, err = pcall(function()
                local arr = c:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
                if type(arr) == "table" then
                    for _, e in ipairs(arr) do
                        local comp = (type(e) == "userdata" and e.get) and e:get() or e
                        if valid(comp) then table.insert(comps, comp) end
                    end
                elseif arr and arr.ForEach then
                    arr:ForEach(function(_, e) local comp = e:get(); if valid(comp) then table.insert(comps, comp) end end)
                else
                    log("DEDUPE components container type=%s", type(arr))
                end
            end)
            if not ok then log("DEDUPE component scan error: %s", tostring(err)) end
            log("DEDUPE %s has %d live components", objName(c), #comps)
            -- Switch the duplicate off either way so it cannot render, collide or simulate.
            pcall(function() c:SetActorHiddenInGame(true) end)
            pcall(function() c:SetActorEnableCollision(false) end)
            pcall(function() c:SetActorTickEnabled(false) end)
            for _, comp in ipairs(comps) do
                pcall(function() comp:SetComponentTickEnabled(false) end)
                pcall(function() comp:SetSimulatePhysics(false) end)
            end
            pcall(function() hidden = tostring(c.bHidden) end)
            log("DEDUPE neutralized %s: bHidden=%s", objName(c), hidden)
        end
    end
    local _, carm = managers()
    if valid(carm) and not (valid(carm.NewCarActor) and carm.NewCarActor:GetFullName() == replicated:GetFullName()) then
        carm.NewCarActor = replicated
        log("client CarManager now points at %s", objName(replicated))
    end
end

local function bindClientCharacter()
    local pc = localController()
    if not valid(pc) or not valid(pc.Pawn) or className(pc.Pawn) ~= CHARACTER_CLASS then return false end
    local cm = managers()
    if valid(cm) and not (valid(cm.CharacterActor) and cm.CharacterActor:GetFullName() == pc.Pawn:GetFullName()) then
        cm.CharacterActor = pc.Pawn
        log("client CharacterManager now points at own %s", objName(pc.Pawn))
    end
    return true
end

local function reportLocalReplicatedActorsOnce()
    if reportedDupes then return end
    reportedDupes = true
    local counts = {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        local ok, rep = pcall(function() return valid(a) and a.bReplicates and a.Role == ROLE_AUTHORITY end)
        if ok and rep then
            local n = className(a); counts[n] = (counts[n] or 0) + 1
        end
    end
    local parts = {}
    for n, c in pairs(counts) do table.insert(parts, n .. "=" .. c) end
    table.sort(parts)
    log("CLIENT-LOCAL REPLICATED ACTORS (%d classes): %s", #parts, table.concat(parts, " "))
end

local function walkBurst()
    if walking then return end
    walking = true
    local frames = 0
    local handle
    handle = LoopInGameThreadWithDelay(16, function()
        frames = frames + 1
        local pc = localController()
        if valid(pc) and valid(pc.Pawn) and not seatRequested then
            -- alternate the direction so the bot does not stay against a wall (exp45)
            -- (not in "loot": there the bot must stay near the test items, exp51 walked 863 uu away)
            local dir = (SCENARIO ~= "loot" and math.floor(tick / 2) % 2 == 1) and -1 or 1
            pc.Pawn:AddMovementInput({ X = dir, Y = 0, Z = 0 }, 1.0, true)
        end
        if frames >= 180 then walking = false; CancelDelayedAction(handle) end
    end)
end

-- ---------------------------------------------------------------- wiring
-- ---------------------------------------------------------------- loot test (scenario "loot")
-- host: puts 3 steel scrap items in front of player 2, later picks one up itself (PDP_MainCharacter."Pickup Actor");
-- client: picks the nearest mirrored scrap up the same way and checks its own Inventory_Player.
local lootTest = { stage = "wait", t0 = 0, hostIds = {}, clientPicked = false, logged = false }
local SCRAP = "~Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"

local function hostLootTestTick()
    if lootTest.stage == "wait" then
        if tick < 24 then return end
        local remoteChar = nil
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() and valid(pc.Pawn) and className(pc.Pawn) == CHARACTER_CLASS then remoteChar = pc.Pawn end
        end
        if not valid(remoteChar) then return end
        local inv = FindFirstOf("InventorySystem")
        local arch = archLoad(SCRAP)
        local l = remoteChar:K2_GetActorLocation()
        local f = remoteChar:GetActorForwardVector()
        local r = remoteChar:GetActorRightVector()
        for i, side in ipairs({ -80, 0, 80 }) do
            local xf = UEHelpers.GetKismetMathLibrary():MakeTransform(
                { X = l.X + f.X * 200 + r.X * side, Y = l.Y + f.Y * 200 + r.Y * side, Z = l.Z + 20 }, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 })
            local act = inv:SpawnItemActor(UEHelpers.GetWorldContextObject(), xf, arch, 0, 0)
            if valid(act) then
                local id = act:GetFName():ToString() .. "#" .. act.Instance:GetFName():ToString()
                table.insert(lootTest.hostIds, { id = id, actor = act })
                log("LOOTTEST host spawned %s at %s", id, fmtLoc(act))
            end
        end
        lootTest.stage, lootTest.t0 = "spawned", tick
        ExecuteInGameThreadWithDelay(3000, function() lookAndShoot("loot-host", "host looks at player 2 next to the scrap") end)
    elseif lootTest.stage == "spawned" and tick >= lootTest.t0 + 8 then
        lootTest.stage = "hostpicked"
        local hostChar = hostCharacter()
        for _, e in ipairs(lootTest.hostIds) do
            if valid(e.actor) and e.actor:K2_GetActorContext() == 0 and valid(e.actor.Instance) then
                local ok, err = pcall(function() callBPFunction(hostChar, "Pickup Actor", e.actor, false) end)
                log("LOOTTEST host picks up %s itself ok=%s %s", e.id, tostring(ok), ok and "" or tostring(err))
                return
            end
        end
        log("LOOTTEST host found no test item left to pick up")
    end
end

local function clientLootTestTick()
    local scrap = {}
    for id, m in pairs(Items.mirror) do
        if valid(m.actor) and m.actor.Instance and valid(m.actor.Instance) then
            local okA, nm = pcall(function() return m.actor.Instance.Archetype:GetFName():ToString() end)
            if okA and nm == "IA_Resource_Raw_Scrap_Steel" then table.insert(scrap, { id = id, actor = m.actor }) end
        end
    end
    if #scrap >= 3 and not lootTest.logged then
        lootTest.logged = true
        lookAndShoot("loot-client", "client looks at the host")
        for _, e in ipairs(scrap) do log("LOOTTEST client mirror %s at %s", e.id, fmtLoc(e.actor)) end
    end
    if #scrap >= 3 and not lootTest.clientPicked then
        lootTest.clientPicked = true
        local me = localController().Pawn
        local best, bd = nil, 1e12
        for _, e in ipairs(scrap) do
            local d = dist(e.actor:K2_GetActorLocation(), me:K2_GetActorLocation())
            if d < bd then best, bd = e, d end
        end
        local ok, err = pcall(function() callBPFunction(me, "Pickup Actor", best.actor, false) end)
        log("LOOTTEST client picks up mirror %s (%.0f uu away) ok=%s %s", best.id, bd, tostring(ok), ok and "" or tostring(err))
        ExecuteInGameThreadWithDelay(1500, function()
            local mgr = FindFirstOf("BaseInventoryManager")
            local has = false
            pcall(function() has = valid(mgr.Inventory_Player:FindItemOfType(archLoad(SCRAP))) end)
            local hand = false
            pcall(function() hand = valid(mgr.Inventory_PlayerHand:FindItemOfType(archLoad(SCRAP))) end)
            log("LOOTTEST client inventory has scrap: player=%s hand=%s", tostring(has), tostring(hand))
        end)
    end
end

-- ---------------------------------------------------------------- map changes
-- Everything above caches per-map objects (controllers, characters, the car). Reset it when the world changes.
local lastWorld = nil
local mapTicks = 0          -- lootprobe: status ticks spent in the current map
-- client: after losing the host, retry "open <host>" every 30 s (a pending connection gives up after its
-- timeout while the host is still loading or re-hosting) until a gameplay map is reached again
local rejoin = { active = false, next = 0, tries = 0 }
local function applyNetTimeouts(where)
    for _, d in ipairs(FindAllOf("IpNetDriver") or {}) do
        pcall(function()
            d.InitialConnectTimeout = 180.0
            d.ConnectionTimeout = 120.0
            log("NETCFG %s live %s InitialConnectTimeout=%.0f ConnectionTimeout=%.0f", where, objName(d), d.InitialConnectTimeout, d.ConnectionTimeout)
        end)
    end
end
local function clientRejoinTick(worldName)
    if not rejoin.active then return end
    if worldName ~= "RB_MainMenu" then rejoin.active = false; log("REJOIN back in %s after %d tries", worldName, rejoin.tries); return end
    rejoin.next = rejoin.next - 1
    if rejoin.next > 0 then return end
    rejoin.tries, rejoin.next = rejoin.tries + 1, 6
    log("REJOIN try %d", rejoin.tries)
    console("open " .. (ARG or "127.0.0.1:7777"))
    ExecuteInGameThreadWithDelay(300, function() applyNetTimeouts("pending") end)
end
local gmLogged = false
local rehostedFor = {}       -- world name -> true (one re-host per arrival)
local function resetPerMapState(newWorld)
    log("MAPCHANGE %s -> %s", tostring(lastWorld), tostring(newWorld))
    lastWorld = newWorld
    spawnedFor, dedupeState, seated = {}, {}, {}
    -- the body states hold objects of the old world (materials): a character in the new world can have the same
    -- name (exp130: player 2 crashed after rejoining, a freed material set on the new body)
    bodies = {}
    reportedDupes, walking, seatRequested, clientSeated, charTicks, rideTicks = false, false, false, false, 0, 0
    drive.phase, drive.t, drive.mode, drive.startLoc, drive.lastLoc, drive.frames = "wait", 0, "throttle", nil, nil, 0
    if rideLoop then pcall(CancelDelayedAction, rideLoop); rideLoop = nil end
    gmLogged = false
    mapTicks = 0
    pcall(Downed.mapChanged, newWorld)
    pcall(WorldRep.reset)
    pcall(WorldDoors.reset)
    pcall(WorldLoot.reset)
    pcall(BodyAnim.reset)
    pcall(Items.reset)
    -- one re-host per ARRIVAL, not per map name: after a team death the host comes back to RB_Garage, which it had
    -- already re-hosted earlier in the session, and was left without a listen server (playtest 2026-10-21: player 2
    -- could not rejoin until the host pressed F8). No loop: after the re-host the world is not standalone.
    rehostedFor = {}
end

local function hookLogger(path)
    local ok, err = pcall(function()
        RegisterHook(path, function(ctx, ...)
            local args = {}
            for i, a in ipairs({ ... }) do
                local okA, v = pcall(function()
                    local x = a:get()
                    if type(x) == "userdata" and x.ToString then return x:ToString() end
                    if type(x) == "userdata" and x.GetFullName then return x:GetFullName() end
                    return tostring(x)
                end)
                args[i] = okA and v or "?"
            end
            log("HOOK %s ctx=%s args=[%s]", path:match("[^.]+$"), objName(ctx:get()), table.concat(args, ", "))
        end)
    end)
    log("hook %s registered=%s %s", path, tostring(ok), ok and "" or tostring(err))
end

-- ---------------------------------------------------------------- re-host after the game's own travel
local coopActive = false     -- the host has had remote players in this session
local hostingEnabled = false -- play: the host pressed F8
-- rehostedFor is declared above resetPerMapState, which clears it on every arrival

-- No world pause while players are connected. The host crashed natively (EXCEPTION_ACCESS_VIOLATION reading 0x178,
-- no Lua in the stack) when pressing Esc while driving, three times in the playtest of 2026-10-21, and the client
-- hung. Reproduced 2026-10-22 in a dev session: pausing and then unpausing the world with a client connected
-- crashes with the same address. So the world is never paused while a client is connected: a pre-hook on the
-- native SetGamePaused turns "pause" into "no pause" (the pause menu still opens, the world keeps running, as in
-- other online games).
local pauseHookDone = false
local function registerPauseHook()
    if pauseHookDone or ROLE ~= "host" then return end
    pauseHookDone = true
    local path = "/Script/Engine.GameplayStatics:SetGamePaused"
    local ok, err = pcall(function()
        RegisterHook(path, function(_, _, paused)
            local want = false
            pcall(function() want = paused:get() end)
            if not want then return end
            local remote = false
            for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
                if valid(pc) and not pc:IsLocalController() then remote = true end
            end
            if not remote then return end
            pcall(function() paused:set(false) end)
            log("PAUSE players connected: the world is not paused (menu open)")
        end)
    end)
    log("PAUSE hook %s ok=%s %s", path, tostring(ok), ok and "" or tostring(err))
    -- Not enough: opening the pause menu itself still crashed the host with the same address after an earlier
    -- open/close (dev session 2026-10-22, world not paused). While a client is connected the host's pause menu
    -- does not open (CanOpenPauseMenu answers no); a message says why.
    for _, cpath in ipairs({
        "/Game/Systems/Controller/BP_PlayerController_MainCharacter.BP_PlayerController_MainCharacter_C:CanOpenPauseMenu",
        "/Game/Systems/Controller/BP_Controller_PlayerCar.BP_Controller_PlayerCar_C:CanOpenPauseMenu",
    }) do
        local okC, errC = pcall(function()
            RegisterHook(cpath, function(_, canPause)
                local remote = false
                for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
                    if valid(pc) and not pc:IsLocalController() then remote = true end
                end
                if not remote then return end
                pcall(function() canPause:set(false) end)
                local wl = FindFirstOf("UMG_Feedback_WarningList_C")
                if valid(wl) then
                    pcall(function()
                        wl:SetVisibility(4)
                        wl["Add Message"](wl, FText("Co-op: the pause menu is off while your partner is connected (it crashes the game)."), 1, FName("PDCoopPause"), nil)
                    end)
                end
                log("PAUSE menu blocked: a partner is connected")
            end)
        end)
        log("PAUSE menu hook %s ok=%s %s", cpath, tostring(okC), okC and "" or tostring(errC))
    end
end
local function worldPackagePath(world)
    local full = world:GetFullName()            -- "World /Game/Maps/X/Y.Y"
    return (full:match("%s(%S+)%.") or full:match("%s(%S+)$"))
end

local function hostRehostTick(worldName)
    local ksl = UEHelpers.GetKismetSystemLibrary()
    local wco = UEHelpers.GetWorldContextObject()
    local ok, standalone = pcall(function() return ksl:IsStandalone(wco) end)
    if not ok then return end
    if not standalone then
        for _, d in ipairs(FindAllOf("IpNetDriver") or {}) do
            local okC, n = pcall(function() return d.ClientConnections:GetArrayNum() end)
            if okC and n > 0 then coopActive = true end
        end
        return
    end
    if (coopActive or hostingEnabled) and worldName ~= "RB_MainMenu" and not rehostedFor[worldName] then
        rehostedFor[worldName] = true
        local path = worldPackagePath(UEHelpers.GetWorld())
        log("REHOST game travelled to %s without listen; servertravel %s?listen", worldName, tostring(path))
        console("servertravel " .. path .. "?listen")
    end
end

-- Before the game's own (native) travel the host removes remote players' characters: tearing down RB_Garage
-- with a second PDP_MainCharacter present crashed the host (exp14, access violation in game code right after
-- "World NetDriver shutdown"). Clients are dropped by the native travel anyway and rejoin after the re-host.
local function prepareForNativeTravel(reason)
    if ROLE ~= "host" then return end
    local n = 0
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() then
            local pawn = pc.Pawn
            pcall(function() pc:UnPossess() end)
            if valid(pawn) then pcall(function() pawn:K2_DestroyActor() end); n = n + 1 end
        end
    end
    log("PRETRAVEL %s: removed %d remote character(s)", reason, n)
end

local function registerTravelHooks()
    local okQ, errQ = pcall(function()
        RegisterHook("/Script/PenDriverPro.BaseSaveGameManager:QuitToMenu", function() prepareForNativeTravel("QuitToMenu") end)
    end)
    local okT, errT = pcall(function()
        RegisterHook("/Script/PenDriverPro.BaseRouteState:TravelTo", function(ctx, dest, reason)
            local d, r = "?", "?"
            pcall(function() d = dest:get():GetFullName() end)
            pcall(function() r = tostring(reason:get()) end)
            log("ROUTE TravelTo pre: route=%s dest=%s reason=%s", objName(ctx:get()), d, r)
            prepareForNativeTravel("TravelTo")
        end, function(ctx, dest, reason)
            log("ROUTE TravelTo post: route=%s", objName(ctx:get()))
        end)
    end)
    log("travel hooks: QuitToMenu=%s %s TravelTo=%s %s", tostring(okQ), okQ and "" or tostring(errQ), tostring(okT), okT and "" or tostring(errT))
end

-- travel scenario: host ServerTravels to a zone map, then later uses the game's own QuitToMenu
local travel = { stage = "garage", t = 0 }
local TRAVEL_MAP = "/Game/Maps/Wilderness/Forest/Wilderness_Forest_01"
-- gametravel scenario: only the game's own (native) travels: QuitToMenu, then UserNewGame from the menu
local gtravel = { stage = "garage", t = 0, ready = 0 }
local function hostGameTravelTick(worldName)
    gtravel.t = gtravel.t + 5
    if gtravel.stage == "garage" and worldName == "RB_Garage" then
        for _, p in ipairs(FindAllOf(CHARACTER_CLASS) or {}) do
            if valid(p) and valid(p.Controller) and not p.Controller:IsLocalController() then gtravel.ready = gtravel.ready + 5; break end
        end
        if gtravel.ready >= 20 then
            gtravel.stage = "quit"; gtravel.t = 0
            log("GAMETRAVEL QuitToMenu (native travel to the menu)")
            pcall(function() StaticFindObject("/Script/PenDriverPro.Default__BaseSaveGameManager"):QuitToMenu(UEHelpers.GetWorldContextObject()) end)
        end
    elseif gtravel.stage == "quit" and worldName == "RB_MainMenu" and gtravel.t >= 15 then
        gtravel.stage = "newgame"; gtravel.t = 0
        local mgr = nil
        for _, m in ipairs(FindAllOf("BaseSaveGameManager") or {}) do if valid(m) then mgr = m end end
        local ok, res = pcall(function() return mgr:UserNewGame(5, 1) end)
        log("GAMETRAVEL UserNewGame(slot 5, STORY) mgr=%s ok=%s result=%s", objName(mgr), tostring(ok), tostring(res))
    elseif gtravel.stage == "newgame" and worldName ~= "RB_MainMenu" then
        gtravel.stage = "arrived"
        log("GAMETRAVEL host arrived in %s", worldName)
    end
end

local function hostTravelTick(worldName)
    travel.t = travel.t + 5
    if travel.stage == "garage" then
        local remoteChar = false
        for _, p in ipairs(FindAllOf(CHARACTER_CLASS) or {}) do
            if valid(p) and valid(p.Controller) and not p.Controller:IsLocalController() then remoteChar = true end
        end
        if remoteChar then travel.ready = (travel.ready or 0) + 5 end
        if (travel.ready or 0) >= 20 then
            travel.stage = "servertravel"; travel.t = 0
            log("TRAVEL servertravel %s", TRAVEL_MAP)
            console("servertravel " .. TRAVEL_MAP)
        end
    elseif travel.stage == "servertravel" and worldName:find("Wilderness", 1, true) then
        travel.stage = "zone"; travel.t = 0
        log("TRAVEL host arrived in %s", worldName)
    elseif travel.stage == "zone" and SCENARIO == "lootprobe" then
        if travel.t >= 40 and not travel.dumped then travel.dumped = true; dumpLoot(worldName) end
    elseif travel.stage == "zone" and travel.t >= 45 then
        travel.stage = "quit"; travel.t = 0
        log("TRAVEL calling game QuitToMenu")
        local ok, err = pcall(function()
            StaticFindObject("/Script/PenDriverPro.Default__BaseSaveGameManager"):QuitToMenu(UEHelpers.GetWorldContextObject())
        end)
        log("TRAVEL QuitToMenu ok=%s %s", tostring(ok), ok and "" or tostring(err))
    end
end

log("loaded v4, role=%s arg=%s scenario=%s", ROLE, tostring(ARG), SCENARIO)
if ROLE == "off" then return end

-- Zone maps take ~20 s to load on the host while clients wait on a pending connection with the default
-- 20 s timeout (exp12: ConnectionTimeout during ServerTravel). Raise the timeouts on the net driver CDOs
-- so every driver created later (listen server, pending client connection) gets them.
for _, cdoPath in ipairs({ "/Script/OnlineSubsystemUtils.Default__IpNetDriver", "/Script/Engine.Default__NetDriver" }) do
    local ok, err = pcall(function()
        local cdo = StaticFindObject(cdoPath)
        cdo.InitialConnectTimeout = 180.0
        cdo.ConnectionTimeout = 120.0
        log("NETCFG %s InitialConnectTimeout=%.0f ConnectionTimeout=%.0f", cdoPath, cdo.InitialConnectTimeout, cdo.ConnectionTimeout)
    end)
    if not ok then log("NETCFG %s failed: %s", cdoPath, tostring(err)) end
end

if ROLE == "host" then registerTravelHooks() end

if SCENARIO == "travel" or SCENARIO == "gametravel" then
    for _, path in ipairs({
        "/Script/PenDriverPro.DrivingGameInstance:PreLoadMap",
        "/Script/PenDriverPro.DrivingGameInstance:PostLoadMapWithWorld",
        "/Script/PenDriverPro.DrivingGameInstance:OnGameplayStateChanged",
        "/Script/Engine.PlayerController:ClientTravel",
        "/Script/Engine.PlayerController:ClientTravelInternal",
        "/Script/Engine.GameplayStatics:OpenLevel",
    }) do hookLogger(path) end
end

if BOTS and ROLE == "host" then
    ExecuteInGameThreadWithDelay(40000, function() console("open " .. (ARG or "/Game/Maps/RunProto/RB_Garage") .. "?listen") end)
elseif BOTS and ROLE == "client" then
    ExecuteInGameThreadWithDelay(90000, function()
        console("open " .. (ARG or "127.0.0.1:7777"))
        -- the host may still be loading (exp80: the garage took 2 min with a bigger save): keep trying
        ExecuteInGameThreadWithDelay(45000, function()
            local w = UEHelpers.GetWorld()
            if valid(w) and w:GetFullName():find("RB_MainMenu", 1, true) and not rejoin.active then
                log("REJOIN first connect failed, will keep reconnecting")
                rejoin.active, rejoin.next = true, 1
            end
        end)
    end)
end

-- keys (all scenarios; they are what a player uses in "play")
local function onGameThread(fn)
    return function()
        ExecuteInGameThread(function()
            local ok, e = pcall(fn)
            if not ok then log("key error: %s", tostring(e)) end
        end)
    end
end
if ROLE == "host" then
    RegisterKeyBind(Key.F8, onGameThread(function()
        hostingEnabled = true
        local wco = UEHelpers.GetWorldContextObject()
        local standalone = UEHelpers.GetKismetSystemLibrary():IsStandalone(wco)
        local w = UEHelpers.GetWorld()
        local name = w:GetFName():ToString()
        if not standalone then log("KEY F8: already hosting %s", name); return end
        if name == "RB_MainMenu" then log("KEY F8: hosting will start when a game is loaded"); return end
        rehostedFor[name] = true
        log("KEY F8: hosting %s", name)
        console("servertravel " .. worldPackagePath(w) .. "?listen")
    end))
elseif ROLE == "client" then
    RegisterKeyBind(Key.F8, onGameThread(function()
        log("KEY F8: connecting to %s", tostring(ARG))
        console("open " .. (ARG or "127.0.0.1:7777"))
    end))
    RegisterKeyBind(Key.F6, onGameThread(function() sendCommand("SEAT") end))
    RegisterKeyBind(Key.F7, onGameThread(function() sendCommand("UNSEAT") end))
end
-- E also counts for the revive (a fallback if the game does not report it as held); only a timestamp here,
-- the key hook runs outside the game thread
RegisterKeyBind(Key.E, function() Downed.keyPressed() end)

LoopInGameThreadWithDelay(200, function()
    fastTick = fastTick + 1
    if not inGameplayMap() then return end
    do  -- every 200 ms: a new body gets its material within one tick (exp49: one sample before the 1 s update)
        local okB, errB = pcall(updateBodies)
        if not okB then log("bodies error: %s", tostring(errB)) end
        okB, errB = pcall(bodyAnimTick)
        if not okB then log("bodyanim error: %s", tostring(errB)) end
        if ROLE == "host" or ROLE == "client" then
            local okL, errL = pcall(CarSync.lockTick)
            if not okL then log("trunklock error: %s", tostring(errL)) end
            local okD, errD = pcall(Downed.tick, 0.2)
            if not okD then log("downed error: %s", tostring(errD)) end
            if ROLE == "host" and fastTick % 5 == 1 then
                okD, errD = pcall(Downed.hostAfterDeathTick)
                if not okD then log("downed error: %s", tostring(errD)) end
            end
            -- doors: find them every 5 s; the host sends changed ones every second, player 2 applies them as they
            -- arrive and checks every 5 s
            local okW, errW = true, nil
            if fastTick % 25 == 13 then okW, errW = pcall(WorldDoors.discover) end
            if okW and ((ROLE == "host" and fastTick % 5 == 2) or (ROLE == "client" and fastTick % 25 == 2)) then
                okW, errW = pcall(ROLE == "host" and WorldDoors.hostTick or WorldDoors.clientTick)
            end
            if not okW then log("doors error: %s", tostring(errW)) end
            -- lootable containers: hooks every 5 s, changes every second
            okW, errW = true, nil
            if fastTick % 25 == 17 then okW, errW = pcall(WorldLoot.discover) end
            if okW and fastTick % 25 == 19 and ROLE == "client" then okW, errW = pcall(WorldLoot.clientCleanup) end
            if okW and fastTick % 5 == 4 then
                okW, errW = pcall(ROLE == "host" and WorldLoot.hostTick or WorldLoot.clientTick)
            end
            if not okW then log("loot error: %s", tostring(errW)) end
        end
    end
    if ROLE == "host" then
        local ok, err = true, nil
        if fastTick % 5 == 0 then
            ok, err = pcall(Items.hostTick)
            if not ok then log("items error: %s", tostring(err)) end
            ok, err = pcall(CarSync.hostTick)
            if not ok then log("carsync error: %s", tostring(err)) end
        end
        if fastTick % 25 == 3 then   -- every 5 s: zone generation spawns over time, and storms spawn more
            ok, err = pcall(WorldRep.hostTick)
            if not ok then log("worldrep error: %s", tostring(err)) end
            ok, err = pcall(Hazards.hostTick)
            if not ok then log("hazards error: %s", tostring(err)) end
        end
        ok, err = pcall(Chan.hostTick)
        if not ok then log("chan error: %s", tostring(err)) end
    elseif ROLE == "client" then
        local ok, err = pcall(Items.clientFollow)
        if not ok then log("items error: %s", tostring(err)) end
        if fastTick % 10 == 6 then   -- standalone: no replicated actors, nothing matches
            ok, err = pcall(WorldRep.clientPlaceTick)
            if not ok then log("worldrep error: %s", tostring(err)) end
        end
        if fastTick % 25 == 8 then
            ok, err = pcall(WorldRep.clientTick)
            if not ok then log("worldrep error: %s", tostring(err)) end
        end
        if fastTick % 5 == 0 then
            ok, err = pcall(Items.clientTick)
            if not ok then log("items error: %s", tostring(err)) end
            pcall(Chan.clientChannel)
            ok, err = pcall(CarSync.clientTick, Chan.hostSession(), fastTick)
            if not ok then log("carsync error: %s", tostring(err)) end
        end
        ok, err = pcall(Chan.clientTick)
        if not ok then log("cmd error: %s", tostring(err)) end
    end
end)

LoopInGameThreadWithDelay(5000, function()
    do
        local function step(name, fn)
            local ok, err = pcall(fn)
            if not ok then log("%s error: %s", name, tostring(err)) end
        end
        local gameplay = inGameplayMap()
        local world = UEHelpers.GetWorld()
        local worldName = valid(world) and world:GetFName():ToString() or "nil"
        if worldName ~= lastWorld then
            -- a client that was in a gameplay map and lands in the main menu lost the host: rejoin
            if ROLE == "client" and lastWorld and lastWorld ~= "RB_MainMenu" and worldName == "RB_MainMenu" then
                log("REJOIN lost the host in %s, will keep reconnecting", lastWorld)
                rejoin.active, rejoin.next = true, 2
            end
            step("mapchange", function() resetPerMapState(worldName) end)
        end
        if ROLE == "host" and gameplay then
            if not gmLogged then gmLogged = true; step("gamemode", logGameModeOnce) end
            step("spawn", spawnForRemotePlayers)
            if BOTS and SCENARIO == "rejoincar" then
                if tick >= 22 and drive.phase == "wait" then step("shot1", function() hostLookAndShoot("walk", "host looks at player 2 walking") end) end
                if drive.phase == "throttle" and drive.t == 25 then step("shot2", function() hostLookAndShoot("ride", "host looks at the passenger") end) end
                if drive.phase == "throttle" and drive.t == 20 then step("camrel", function() logCamRel(playerCar(), "driver") end) end
            end
            step("seathook", registerSeatHook)
            step("seatkeeper", startSeatKeeper)
            if SCENARIO == "channel" and tick >= 24 then step("chantest", Chan.queueTest) end
            if SCENARIO == "loot" then step("loottest", hostLootTestTick) end
            if CAR_LIKE then
                step("car", hostCarTick)
                step("driveloop", ensureDriveLoop)
            elseif SCENARIO == "travel" then
                step("travel", function() hostTravelTick(worldName) end)
            end
        end
        if ROLE == "host" or ROLE == "client" then step("events", Events.register) end
        if ROLE == "host" then
            step("rehost", function() hostRehostTick(worldName) end)
            step("pausehook", registerPauseHook)
            if SCENARIO == "gametravel" or SCENARIO == "lootprobe" then step("gametravel", function() hostGameTravelTick(worldName) end) end
        end
        if ROLE == "client" then step("rejoin", function() clientRejoinTick(worldName) end) end
        if ROLE == "host" and not gmLogged and gameplay then step("netcfg", function() applyNetTimeouts("listen") end) end
        if gameplay and SCENARIO == "itemprobe" and ROLE == "host" then
            mapTicks = mapTicks + 1
            if mapTicks == 6 then step("itemdump1", function() dumpItemsDetailed("before") end) end
            if mapTicks == 7 then step("archspawn", function() spawnTestItem(sampleArchetypes()) end) end
            if mapTicks == 8 then step("itemdump2", function() dumpItemsDetailed("after-spawn") end) end
            if mapTicks == 9 then step("remove", removeTestItem) end
            if mapTicks == 10 then step("itemdump3", function() dumpItemsDetailed("after-remove") end) end
            if mapTicks == 11 then step("give", function() giveTestItemToPlayer(sampleArchetypes()) end) end
        end
        if gameplay and SCENARIO == "lootprobe" then
            mapTicks = mapTicks + 1
            if mapTicks == 8 then step("lootdump", function() dumpLoot(worldName) end) end
        end
        if ROLE == "client" and gameplay then
            step("dedupe", dedupeCar)
            if SCENARIO == "loot" then step("loottest", clientLootTestTick) end
            step("seathook", registerSeatHook)
            step("enterhook", registerEnterCarHook)
            local bound = false
            step("bind", function() bound = bindClientCharacter() end)
            if tick >= 30 then step("report", reportLocalReplicatedActorsOnce) end
            local riding = false
            pcall(function() riding = valid(localController().Pawn:GetAttachParentActor()) end)
            if BOTS and bound and not riding and (not seatRequested or unseatSent) and tick % 2 == 0 then step("walk", walkBurst) end
            if bound then step("ride", clientCarTick) end
        end
        step("status", status)
        if gameplay then step("bodystate", logBodyStates) end
        -- the nudge teleports the host pawn, so stop it once the host is getting into the car
        if BOTS and ROLE == "host" and gameplay and drive.phase == "wait" then step("nudge", nudgeHostPawn) end
    end
end)
