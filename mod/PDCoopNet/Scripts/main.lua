-- PDCoopNet v4: Pacific Drive co-op experiments.
-- Role comes from ue4ss/Mods/PDCoopNet/role.txt (line 1: host|client|off, line 2: map or address,
-- line 3: scenario play|car|rejoincar|travel|gametravel, default play).
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
-- Client -> host command channel: the stock reliable Server RPC ServerChangeName carries a tagged string;
-- the host reads it back from the remote PlayerState name. No new RPCs are needed.
local CMD_PREFIX = "PDCOOP:"
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

local cmdSeq = 0
local function sendCommand(cmd)
    local pc = localController()
    if not valid(pc) then return end
    cmdSeq = cmdSeq + 1
    pc:ServerChangeName(CMD_PREFIX .. cmd .. ":" .. cmdSeq)
    log("CMD sent %s #%d", cmd, cmdSeq)
end

local lastCmd = {}          -- PlayerController full name -> last command string acted on
local function remoteCommands()
    local out = {}
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() and valid(pc.PlayerState) then
            local ok, name = pcall(function() return pc.PlayerState:GetPlayerName():ToString() end)
            if ok and name and name:sub(1, #CMD_PREFIX) == CMD_PREFIX and lastCmd[pc:GetFullName()] ~= name then
                -- PlayerState:SetPlayerName did not clear the name (exp21: each command ran every 5 s), so
                -- remember the last command string per controller instead
                lastCmd[pc:GetFullName()] = name
                table.insert(out, { pc = pc, cmd = (name:sub(#CMD_PREFIX + 1):match("^([^:]+)")) or "" })
            end
        end
    end
    return out
end

local function seatPassenger(pc, car, force)
    local ch = pc.Pawn
    if not valid(ch) or className(ch) ~= CHARACTER_CLASS then return end
    if seated[ch:GetFullName()] and not force then return end
    pcall(function() ch:K2_DetachFromActor(EAttachmentRule.KeepWorld, EAttachmentRule.KeepWorld, EAttachmentRule.KeepWorld) end)
    local seat = car:K2_GetActorLocation()
    pcall(function() seat = car.TempSocket_Seat:K2_GetComponentLocation() end)
    local right = car:GetActorRightVector()
    local target = { X = seat.X + right.X * 70, Y = seat.Y + right.Y * 70, Z = seat.Z + 10 }
    pcall(function() ch.CharacterMovement:DisableMovement() end)
    ch:SetActorEnableCollision(false)
    ch:K2_SetActorLocation(target, false, {}, true)
    ch:K2_AttachToActor(car, UEHelpers.FindOrAddFName("None"), EAttachmentRule.KeepWorld, EAttachmentRule.KeepWorld,
        EAttachmentRule.KeepWorld, false)
    seated[ch:GetFullName()] = car:GetFullName()
    local parent = ch:GetAttachParentActor()
    log("SEAT %s attached to %s (parent=%s) at %s", objName(ch), objName(car), objName(parent), fmtLoc(ch))
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

-- client commands, every scenario including play
local function hostCommandsTick()
    local cmds = remoteCommands()
    if #cmds == 0 then return end
    local car = playerCar()
    for _, rc in ipairs(cmds) do
        log("CMD received %s from %s", rc.cmd, objName(rc.pc))
        if valid(car) and rc.cmd == "SEAT" then seatPassenger(rc.pc, car)
        elseif valid(car) and rc.cmd == "UNSEAT" then unseatPassenger(rc.pc, car) end
    end
end

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
                t.Translation.X = t.Translation.X + r.X * 70
                t.Translation.Y = t.Translation.Y + r.Y * 70
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
    if valid(parent) then rideTicks = rideTicks + 1 end
    if SCENARIO == "rejoincar" and droppedOnce and not unseatSent and rideTicks >= 6 then
        unseatSent = true
        log("UNSEATTEST riding again for %d s after the rejoin, asking to get out", rideTicks * 5)
        sendCommand("UNSEAT")
    end
    if SCENARIO == "rejoincar" and not droppedOnce and rideTicks >= 8 then
        droppedOnce = true
        log("DROPTEST riding for %d s, disconnecting on purpose", rideTicks * 5)
        console("disconnect")
    end
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
            pc.Pawn:AddMovementInput({ X = 1, Y = 0, Z = 0 }, 1.0, true)
        end
        if frames >= 180 then walking = false; CancelDelayedAction(handle) end
    end)
end

-- ---------------------------------------------------------------- wiring
-- ---------------------------------------------------------------- map changes
-- Everything above caches per-map objects (controllers, characters, the car). Reset it when the world changes.
local lastWorld = nil
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
local function resetPerMapState(newWorld)
    log("MAPCHANGE %s -> %s", tostring(lastWorld), tostring(newWorld))
    lastWorld = newWorld
    spawnedFor, dedupeState, seated = {}, {}, {}
    reportedDupes, walking, seatRequested, clientSeated, charTicks, rideTicks = false, false, false, false, 0, 0
    drive.phase, drive.t, drive.mode, drive.startLoc, drive.lastLoc, drive.frames = "wait", 0, "throttle", nil, nil, 0
    if rideLoop then pcall(CancelDelayedAction, rideLoop); rideLoop = nil end
    gmLogged = false
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
local rehostedFor = {}       -- world name -> true (one re-host per arrival)
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
    ExecuteInGameThreadWithDelay(90000, function() console("open " .. (ARG or "127.0.0.1:7777")) end)
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
            step("commands", hostCommandsTick)
            step("seathook", registerSeatHook)
            step("seatkeeper", startSeatKeeper)
            if CAR_LIKE then
                step("car", hostCarTick)
                step("driveloop", ensureDriveLoop)
            elseif SCENARIO == "travel" then
                step("travel", function() hostTravelTick(worldName) end)
            end
        end
        if ROLE == "host" then
            step("rehost", function() hostRehostTick(worldName) end)
            if SCENARIO == "gametravel" then step("gametravel", function() hostGameTravelTick(worldName) end) end
        end
        if ROLE == "client" then step("rejoin", function() clientRejoinTick(worldName) end) end
        if ROLE == "host" and not gmLogged and gameplay then step("netcfg", function() applyNetTimeouts("listen") end) end
        if ROLE == "client" and gameplay then
            step("dedupe", dedupeCar)
            step("seathook", registerSeatHook)
            local bound = false
            step("bind", function() bound = bindClientCharacter() end)
            if tick >= 30 then step("report", reportLocalReplicatedActorsOnce) end
            local riding = false
            pcall(function() riding = valid(localController().Pawn:GetAttachParentActor()) end)
            if BOTS and bound and not riding and (not seatRequested or unseatSent) and tick % 2 == 0 then step("walk", walkBurst) end
            if bound then step("ride", clientCarTick) end
        end
        step("status", status)
        -- the nudge teleports the host pawn, so stop it once the host is getting into the car
        if BOTS and ROLE == "host" and gameplay and drive.phase == "wait" then step("nudge", nudgeHostPawn) end
    end
end)
