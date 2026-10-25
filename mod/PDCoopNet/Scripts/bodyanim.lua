-- PDCoopNet bodyanim: the other player's body moves like a player: walk, run, sprint, crouch (also in a jump: the
-- game keeps the crouch in the air), jump / fall, lying when down, sitting in the car.
-- Loaded by main.lua: require("bodyanim")(ctx), tick() every 200 ms.
--
-- The game ships the Advanced Locomotion System v3 animations for its mannequin (ALS_Mannequin_Skeleton, the same
-- skeleton as the player character's mesh). The body's mesh is switched to single-animation mode and the clip
-- follows the character's replicated state: velocity, bIsCrouched, falling, attached to a car, down (downed.lua).
-- Walking, running, crouching and jumping (switch alsloco, on): the mesh keeps its own animation blueprint
-- instead, the game's ALS Mannequin_AnimBP, which still reads the character's ALS variables (velocity, direction,
-- stance; computed for the other player's character too, exp276: host sees player 2 walk at 170-375, player 2 the
-- host at 375, crouch reaches its ALS_Stance) and blends between its states and directions itself. Single clips
-- jumped from one to the next (owner's playtest: "walk F -> walk R snaps"). Lying and sitting stay clips.
-- There is no sitting clip in the game. Sitting: a PoseableMeshComponent added to the character copies the idle
-- pose of the body every tick with the legs bent (thigh -90, calf +90 about the mesh's X axis, component space;
-- exp157), and is shown instead of the body; main.lua lowers both into the seat.
--
-- Footsteps: the clips' Footstep_AnimNotify posts the game's Wwise footstep events on the mesh's owner; those
-- events are 2D (made for one's own steps), so the other player's steps sounded as if one walked oneself
-- (playtest). The other characters' Wwise emitter is muted (output bus volume 0: all of their "own player"
-- sounds), and each footstep notify on them plays the ALS footstep cue at their feet with SA_PDCoopSteps (pak):
-- spatial, fading out over 25 m.
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local M = {}
    local BASE = "/Game/AdvancedLocomotionV3/Characters/Mannequin/Animations/"
    local CLIPS = {
        idle = "Idles/ALS_N_Idle_Pose", crouchIdle = "Idles/ALS_CLF_Idle_Pose",
        walk_F = "Locomotion/ALS_N_Walk_F", walk_B = "Locomotion/ALS_N_Walk_B",
        walk_FL = "Locomotion/ALS_N_Walk_FL", walk_FR = "Locomotion/ALS_N_Walk_FR",
        walk_BL = "Locomotion/ALS_N_Walk_BL", walk_BR = "Locomotion/ALS_N_Walk_BR",
        run_F = "Locomotion/ALS_N_Run_F", run_B = "Locomotion/ALS_N_Run_B",
        run_FL = "Locomotion/ALS_N_Run_FL", run_FR = "Locomotion/ALS_N_Run_FR",
        run_BL = "Locomotion/ALS_N_Run_BL", run_BR = "Locomotion/ALS_N_Run_BR",
        sprint = "Locomotion/ALS_N_Sprint_F",
        crouch_F = "Locomotion/ALS_CLF_Walk_F", crouch_B = "Locomotion/ALS_CLF_Walk_B",
        crouch_L = "Locomotion/ALS_CLF_Walk_L", crouch_R = "Locomotion/ALS_CLF_Walk_R",
        jump = "InAir/ALS_N_Jump", fall = "InAir/ALS_N_FallLoop", sit = "Idles/ALS_N_Idle_Pose",
        lying = "GettingUp/ALS_CLF_GetUpFromBack",
    }
    -- uu/s each clip was made for (play rate = speed / this, clamped)
    local SPEED = { walk = 165, run = 375, sprint = 600, crouch = 150 }
    local LOOP = { idle = true, crouchIdle = true, sprint = true, fall = true, sit = true }
    local SIT_BEND = { thigh = -90, calf = 90 }
    local posing = {}        -- character full name -> its PoseableMeshComponent while it sits
    local cache = {}
    local STEP_SOUND = "/Game/AdvancedLocomotionV3/Audio/Footsteps/Footstep_Cue.Footstep_Cue"
    local STEP_ATTENUATION = "/Game/Mods/PDCoopNet/SA_PDCoopSteps.SA_PDCoopSteps"
    local STEP_NOTIFY = "/Game/AdvancedLocomotionV3/Blueprints/AnimNotifys/Footstep_AnimNotify.Footstep_AnimNotify_C:Received_Notify"
    local assets = {}            -- path -> loaded object (checked before use: collected after a map change)
    local function asset(path)
        if assets[path] and not ctx.Events.same(assets[path], path:match("^(.-)%.") ) then assets[path] = nil end
        if not assets[path] then
            local a = StaticFindObject(path)
            if not valid(a) then
                local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
                pcall(function() a = arh:GetAsset({ ObjectPath = ctx.UEHelpers.FindOrAddFName(path) }) end)
            end
            assets[path] = valid(a) and a or nil
        end
        return assets[path]
    end
    local muted = {}             -- AkComponent full name -> true
    local state = {}         -- character full name -> { clip, rate }
    local missingLogged = {}

    local function clip(name)
        -- a clip nobody plays any more can be collected (map change): load it again
        if cache[name] and not ctx.Events.same(cache[name], BASE .. CLIPS[name]) then cache[name] = nil end
        if cache[name] == nil then
            local path = BASE .. CLIPS[name]
            local short = path:match("[^/]+$")
            local a = nil
            pcall(function() a = LoadAsset(path .. "." .. short) end)
            if not valid(a) then
                local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
                pcall(function() a = arh:GetAsset({ ObjectPath = ctx.UEHelpers.FindOrAddFName(path .. "." .. short) }) end)
            end
            cache[name] = valid(a) and a or false
            if not cache[name] and not missingLogged[name] then
                missingLogged[name] = true
                log("BODYANIM clip %s not found (%s)", name, path)
            end
        end
        return cache[name] or nil
    end

    -- F, FR, BR, B, BL, FL (6 ways) or F, R, B, L (4 ways) from the movement direction relative to the facing
    local function direction(ch, v, ways)
        local yaw = ch:K2_GetActorRotation().Yaw
        local mv = math.deg(math.atan(v.Y, v.X))
        local d = (mv - yaw + 540) % 360 - 180        -- -180..180, 0 = forward, + = right
        if ways == 4 then
            if math.abs(d) <= 45 then return "F" elseif math.abs(d) >= 135 then return "B" end
            return d > 0 and "R" or "L"
        end
        if math.abs(d) <= 22.5 then return "F" elseif math.abs(d) >= 157.5 then return "B" end
        if d > 0 then return d < 90 and "FR" or "BR" end
        return d > -90 and "FL" or "BL"
    end

    -- which clip and play rate this character needs now
    local function pick(ch)
        if ctx.isDown(ch) then return "lying", 0 end
        local seated = false
        pcall(function() seated = ctx.isCar(ch:GetAttachParentActor()) end)
        if seated then return "sit", 1 end
        local v = ch:GetVelocity()
        local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
        local crouched, falling = false, false
        pcall(function() crouched = ch.bIsCrouched end)
        pcall(function() falling = ch.CharacterMovement:IsFalling() end)
        if crouched then
            if falling or speed < 10 then return "crouchIdle", 1 end
            return "crouch_" .. direction(ch, v, 4), math.max(0.5, math.min(1.6, speed / SPEED.crouch))
        end
        if falling then return v.Z > 50 and "jump" or "fall", 1 end
        if speed < 10 then return "idle", 1 end
        if speed > 520 then return "sprint", math.max(0.7, math.min(1.4, speed / SPEED.sprint)) end
        local kind = speed > 260 and "run" or "walk"
        return kind .. "_" .. direction(ch, v, 6), math.max(0.5, math.min(1.6, speed / SPEED[kind]))
    end

    local F = function(s) return ctx.UEHelpers.FindOrAddFName(s) end
    local function sitPose(ch, on)
        local key = ch:GetFullName()
        local comp = posing[key]
        local mesh = ch.Mesh
        if not on then
            if valid(comp) then pcall(function() comp:SetVisibility(false, false) end) end
            return
        end
        if not valid(comp) then
            local K = ctx.UEHelpers.GetKismetMathLibrary()
            pcall(function()
                comp = ch:AddComponentByClass(StaticFindObject("/Script/Engine.PoseableMeshComponent"), false,
                    K:MakeTransform({ X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }), false)
                comp:SetSkeletalMesh(mesh.SkeletalMesh, true)
                comp:K2_AttachToComponent(mesh, F("None"), 0, 0, 0, false)
                comp:K2_SetRelativeLocationAndRotation({ X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true)
            end)
            if not valid(comp) then return end
            posing[key] = comp
            log("BODYANIM %s: sitting pose added", ch:GetFName():ToString())
        end
        pcall(function()
            for i = 0, 1 do comp:SetMaterial(i, mesh:GetMaterial(i)) end
            comp:CopyPoseFromSkeletalComponent(mesh)
            local K = ctx.UEHelpers.GetKismetMathLibrary()
            for _, side in ipairs({ "l", "r" }) do
                for bone, angle in pairs({ thigh = SIT_BEND.thigh, calf = SIT_BEND.calf }) do
                    local name = F(bone .. "_" .. side)
                    local cur = comp:GetBoneRotationByName(name, 1)
                    comp:SetBoneRotationByName(name, K:ComposeRotators(cur, { Pitch = 0, Yaw = 0, Roll = angle }), 1)
                end
            end
            comp:SetVisibility(true, false)
            mesh:SetVisibility(false, false)
        end)
    end
    -- main.lua keeps the body visible, except while it sits (the poseable copy is shown then)
    function M.isSitting(ch)
        local s = state[ch:GetFullName()]
        return s ~= nil and s.clip == "sit" and valid(posing[ch:GetFullName()])
    end

    -- the other characters' Wwise emitter: muted
    local AKCLASS = nil
    local function muteWwise(ch)
        AKCLASS = (AKCLASS and valid(AKCLASS)) and AKCLASS or StaticFindObject("/Script/AkAudio.AkComponent")
        if not valid(AKCLASS) then return end
        for _, e in ipairs(ch:K2_GetComponentsByClass(AKCLASS) or {}) do
            local c = e:get()
            local name = c:GetFullName()
            if not muted[name] then
                local ok = pcall(function() c:SetOutputBusVolume(0.0) end)
                muted[name] = true
                log("BODYANIM %s: its Wwise sounds muted (ok=%s)", ch:GetFName():ToString(), tostring(ok))
            end
        end
    end
    -- a footstep of the other character: the cue at its feet. The notify can run off the game thread (exp161/162:
    -- calling game functions in the hook hung player 2's game at the first step): the hook only queues the mesh, a
    -- 50 ms game-thread loop plays the sound.
    local stepQueue = {}
    local stepsLogged = {}       -- character full name -> footsteps played (the first few are logged)
    local function onFootstep(_, meshp)
        local okM, mesh = pcall(function() return meshp:get() end)
        if okM and mesh and #stepQueue < 16 then stepQueue[#stepQueue + 1] = mesh end
    end
    local function playStep(mesh)
        if not valid(mesh) then return end
        local owner = mesh:GetOwner()
        if not (valid(owner) and state[owner:GetFullName()]) then return end      -- only the bodies animated here
        local snd, att = asset(STEP_SOUND), asset(STEP_ATTENUATION)
        if not snd then return end
        local ok, err = pcall(function()
            local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            GS:SpawnSoundAtLocation(owner, snd, mesh:K2_GetComponentLocation(), {}, 0.8, 1.0, 0.0, att, nil, true)
        end)
        local key = owner:GetFullName()
        stepsLogged[key] = (stepsLogged[key] or 0) + 1
        if stepsLogged[key] <= 3 or not ok then
            log("BODYANIM %s: footstep %d at its feet (attenuation %s) ok=%s %s", owner:GetFName():ToString(), stepsLogged[key],
                tostring(att ~= nil), tostring(ok), ok and "" or tostring(err))
        end
    end

    LoopInGameThreadWithDelay(50, function()
        if #stepQueue == 0 then return end
        local batch = stepQueue
        stepQueue = {}
        for _, mesh in ipairs(batch) do
            local ok, err = pcall(playStep, mesh)
            if not ok then log("BODYANIM footstep error: %s", tostring(err)) end
        end
    end)

    function M.tick(characters)
        ctx.Events.hookFunction(STEP_NOTIFY, onFootstep)
        for _, ch in ipairs(characters) do
            pcall(muteWwise, ch)
            local key = ch:GetFullName()
            local name, rate = pick(ch)
            local s = state[key]
            local mesh = ch.Mesh
            if ctx.alsLoco() and name ~= "lying" and name ~= "sit" then
                -- locomotion by the mesh's own ALS animation blueprint
                if mesh and (not s or s.clip ~= "als") then
                    local ok, err = pcall(function() mesh:SetAnimationMode(0) end)   -- EAnimationMode::AnimationBlueprint
                    local n = (s and s.changes or 0) + 1
                    if n <= 40 or not ok then log("BODYANIM %s: ALS locomotion ok=%s %s", ch:GetFName():ToString(), tostring(ok), ok and "" or tostring(err)) end
                    state[key] = { clip = "als", rate = 1, changes = n }
                    pcall(sitPose, ch, false)
                end
                name = nil
            end
            local a = name and clip(name)
            if a and mesh then
                if not s or s.clip ~= name then
                    local ok, err = pcall(function()
                        mesh:SetAnimationMode(1)                 -- EAnimationMode::AnimationSingleNode
                        mesh:PlayAnimation(a, LOOP[name] or not (name == "jump" or name == "lying"))
                        if name == "lying" then mesh:SetPosition(0.0, false) end
                        mesh:SetPlayRate(rate)
                    end)
                    if not ok then log("BODYANIM %s -> %s failed: %s", ch:GetFName():ToString(), name, tostring(err)) end
                    -- the first 40 changes per body, then only lying (for the tests and reports)
                    local n = (s and s.changes or 0) + 1
                    if n <= 40 or name == "lying" or (s and s.clip == "lying") then
                        log("BODYANIM %s: %s (rate %.2f)", ch:GetFName():ToString(), name, rate)
                    end
                    state[key] = { clip = name, rate = rate, changes = n }
                elseif math.abs(s.rate - rate) > 0.1 then
                    pcall(function() mesh:SetPlayRate(rate) end)
                    s.rate = rate
                end
                local ok, err = pcall(sitPose, ch, name == "sit")
                if not ok then log("BODYANIM sitting pose error: %s", tostring(err)) end
            end
        end
    end

    -- my own character again (or gone): forget it, the game's animation takes over
    function M.forget(ch)
        local key = ch:GetFullName()
        if state[key] then
            state[key] = nil
            pcall(function() ch.Mesh:SetAnimationMode(0) end)      -- EAnimationMode::AnimationBlueprint
        end
        if valid(posing[key]) then pcall(function() posing[key]:SetVisibility(false, false) end) end
    end

    function M.reset() state = {}; cache = {}; posing = {}; muted = {} end
    return M
end
