-- PDCoopNet bodyanim: the other player's body moves like a player: walk, run, sprint, crouch (also in a jump: the
-- game keeps the crouch in the air), jump / fall, lying when down, sitting in the car.
-- Loaded by main.lua: require("bodyanim")(ctx), tick() every 200 ms.
--
-- The game ships the Advanced Locomotion System v3 animations for its mannequin (ALS_Mannequin_Skeleton, the same
-- skeleton as the player character's mesh). The body's mesh is switched to single-animation mode and the clip
-- follows the character's replicated state: velocity, bIsCrouched, falling, attached to a car, down (downed.lua).
-- There is no sitting clip in the game: the crouched idle pose, with the mesh lowered into the seat by main.lua.
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
        jump = "InAir/ALS_N_Jump", fall = "InAir/ALS_N_FallLoop",
        lying = "GettingUp/ALS_CLF_GetUpFromBack",
    }
    -- uu/s each clip was made for (play rate = speed / this, clamped)
    local SPEED = { walk = 165, run = 375, sprint = 600, crouch = 150 }
    local LOOP = { idle = true, crouchIdle = true, sprint = true, fall = true }
    local cache = {}
    local state = {}         -- character full name -> { clip, rate }
    local missingLogged = {}

    local function clip(name)
        -- a clip nobody plays any more can be collected (map change): load it again
        if cache[name] and not valid(cache[name]) then cache[name] = nil end
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
        if seated then return "crouchIdle", 1 end
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

    function M.tick(characters)
        for _, ch in ipairs(characters) do
            local key = ch:GetFullName()
            local name, rate = pick(ch)
            local a = clip(name)
            local s = state[key]
            local mesh = ch.Mesh
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
    end

    function M.reset() state = {}; cache = {} end
    return M
end
