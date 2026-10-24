-- PDCoopNet hazards: what hazards do to player 2 is computed by player 2's own game (owner's decision 2026-10-23:
-- reactions that would wait for the host run locally).
-- Loaded by main.lua: require("hazards")(ctx).
--
-- Landmines: the host's mines reach player 2 by worldrep (they are item actors without item data, replicated). A
-- mine explodes on the host (BP_Hazard_Landmine: StartExplode -> OnExplode -> DetonationFX, then it is gone, also
-- on player 2's side); the host zeroes damage to characters that are not its own (one health per process), so the
-- explosion never hurt player 2 (exp152). The host now sends "BOOM|x,y,z" when a mine starts exploding; player 2's
-- game spawns its own mine there and explodes it: its own effects and its own damage to player 2.
--
-- Car crashes: the car's damage controller (BP_CarDispatchController) works out the player's share of every hit on
-- the car (in the car, not in the garage, limited over time) and hands it to "the player" as damage messages
-- (MSG_Damage_Physical_Impact, 0.04-0.5 each, ~20 per crash; exp215 in a zone) - on the host that is always the
-- host, so player 2 riding along took nothing (owner's playtest 2026-10-24). While player 2 rides, each message the
-- host's player receives from the car goes to player 2 as "CRASH|<message class>|<damage>", and player 2's game
-- hands the same message to its player (its own resistances apply). Player 2's copy of the car cannot work it out
-- itself: its controller's evaluation stops at once on a replicated car (exp215).
return function(ctx)
    local log, valid, UEHelpers = ctx.log, ctx.valid, ctx.UEHelpers
    local M = {}
    local MINE = "/Game/Gameplay/Hazards/Landmine/BP_Hazard_Landmine.BP_Hazard_Landmine_C"

    local function mineClass()
        local c = StaticFindObject(MINE)
        if not valid(c) then
            local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
            pcall(function() c = arh:GetAsset({ ObjectPath = UEHelpers.FindOrAddFName(MINE) }) end)
        end
        return valid(c) and c or nil
    end

    local RECEIVER = "/Game/Characters/Player/Components/AC_PlayerHealthReceiverHelper.AC_PlayerHealthReceiverHelper_C"
    local MSG_DIR = "/Game/Systems/Messages/"
    local function shortClass(path)
        local n = path:match("^" .. MSG_DIR:gsub("%p", "%%%0") .. "([%w_]+)%.%1_C$")
        return n or path
    end
    local function classPath(short)
        if short:sub(1, 1) == "/" then return short end
        return MSG_DIR .. short .. "." .. short .. "_C"
    end
    local function hookCrashes()
        if not valid(StaticFindObject(RECEIVER)) then return end
        ctx.Events.hookFunction(RECEIVER .. ":MessageBind_MSG_Base_Damage_C", function(selfp, msgp, srcp)
            if not ctx.passengerRiding() then return end
            local okM, cls, dmg = pcall(function()
                local src = srcp:get()
                if not src:GetClass():GetFName():ToString():find("CarDispatchController", 1, true) then return nil end
                if not ctx.isMine(selfp:get():GetOwner()) then return nil end
                local m = msgp:get()
                return m:GetClass():GetFullName():match("%s(%S+)$"), m.Damage
            end)
            if okM and cls and type(dmg) == "number" and dmg > 0 then
                ctx.hostSend(string.format("CRASH|%s|%.3f", shortClass(cls), dmg))
            end
        end)
    end

    -- host: every 5 s the hooks are in place (the mine class loads with a zone that has mines)
    function M.hostTick()
        if not ctx.enabled() then return end
        hookCrashes()
        if not valid(StaticFindObject(MINE)) then return end
        ctx.Events.hookFunction(MINE .. ":StartExplode", function(selfp)
            local okL, l = pcall(function() return selfp:get():K2_GetActorLocation() end)
            if okL and l then
                ctx.hostSend(string.format("BOOM|%.0f,%.0f,%.0f", l.X, l.Y, l.Z))
                log("HAZARD mine exploding at %.0f,%.0f,%.0f: sent to player 2", l.X, l.Y, l.Z)
            end
        end)
    end

    -- player 2: the explosion's effects from a mine of its own at that spot, and the damage to player 2 computed
    -- here. A mine spawned on player 2's machine runs StartExplode / OnExplode but not the rest (no effects, no
    -- damage: exp153, the chain stops where it needs the server), so the damage goes through the game's own player
    -- damage path (as PDCoopDev "lethal" does): measured on the host, a mine 150 uu away took 20 health, 400 uu away
    -- nothing (exp153) -> MAX * (1 - d / RADIUS).
    local RADIUS, MAX_DAMAGE = 360, 35
    local DAMAGE_MSG = "/Game/Systems/Messages/MSG_Damage_Physical.MSG_Damage_Physical_C"
    local function damageMe(amount)
        local pawn = nil
        pcall(function() pawn = ctx.localController().Pawn end)
        if not valid(pawn) then return false end
        local cls = StaticFindObject(DAMAGE_MSG)
        if not valid(cls) then pcall(function() cls = LoadAsset(DAMAGE_MSG) end) end
        if not valid(cls) then return false end
        return pcall(function()
            local msg = StaticConstructObject(cls, FindFirstOf("InventorySystem"))
            msg.Damage = amount
            pawn.AC_PlayerHealthReceiverHelper:MessageBind_MSG_Base_Damage_C(msg, pawn, pawn)
        end)
    end
    ctx.hostMsgHandlers["BOOM"] = function(rest)
        if not ctx.enabled() then return end
        local x, y, z = rest:match("^(-?%d+),(-?%d+),(-?%d+)$")
        if not x then return end
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        -- effects
        local cls = mineClass()
        if cls then
            local m = nil
            pcall(function() m = UEHelpers.GetWorld():SpawnActor(cls, { X = x, Y = y, Z = z }, {}) end)
            if valid(m) then
                pcall(function() m:DetonationFX() end)
                ExecuteInGameThreadWithDelay(3000, function()
                    if valid(m) then pcall(function() m:K2_DestroyActor() end) end
                end)
            end
        end
        -- damage
        local d = nil
        pcall(function()
            local l = ctx.localController().Pawn:K2_GetActorLocation()
            d = math.sqrt((l.X - x) ^ 2 + (l.Y - y) ^ 2 + (l.Z - z) ^ 2)
        end)
        if d and d < RADIUS then
            local amount = MAX_DAMAGE * (1 - d / RADIUS)
            local ok = damageMe(amount)
            log("HAZARD mine of the host exploded %.0f uu from player 2: %.1f damage here ok=%s", d, amount, tostring(ok))
        else
            log("HAZARD mine of the host exploded at %s (%s uu away): effects only", rest, d and string.format("%.0f", d) or "?")
        end
    end

    -- player 2: its share of a crash of the host's car, handed to player 2's player as the same message from player
    -- 2's copy of the car's damage controller
    local crashLogged = 0
    ctx.hostMsgHandlers["CRASH"] = function(rest)
        if not ctx.enabled() then return end
        local short, dmg = rest:match("^([^|]+)|([%d%.]+)$")
        if not short then return end
        local cls = StaticFindObject(classPath(short))
        local car = ctx.playerCar()
        local pawn = nil
        pcall(function() pawn = ctx.localController().Pawn end)
        if not (valid(cls) and valid(car) and valid(pawn)) then return end
        local ok, err = pcall(function()
            local msg = StaticConstructObject(cls, FindFirstOf("InventorySystem"))
            msg.Damage = tonumber(dmg)
            pawn.AC_PlayerHealthReceiverHelper:MessageBind_MSG_Base_Damage_C(msg, car.DamageDispatchController, pawn)
        end)
        if crashLogged < 5 or not ok then
            crashLogged = crashLogged + 1
            log("HAZARD crash of the host's car: %s damage to player 2 (%s) ok=%s %s", dmg, short, tostring(ok), ok and "" or tostring(err))
        end
    end

    return M
end
