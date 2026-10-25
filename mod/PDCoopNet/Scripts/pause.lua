-- PDCoopNet pause: a real pause in co-op, the same for both players (owner: "pause for real, not a block").
--
-- The game pauses through BP_UIManager.PauseGame(reason, paused): it keeps PauseStates (reason -> bool) and calls
-- GameplayStatics.SetGamePaused(any reason true); the pause menu ('pausemenu') shows only when that succeeds.
-- Reasons in the game: 'pausemenu' and 'pauseforlogbook' (the logbook, with the "pause in menus" setting).
-- - Host: the world pauses while the host's or player 2's pause menu is open (our reason 'PDCoopPartner' for player
--   2's menu); the logbook does not pause the world while a partner is connected. A paused host world replicates
--   nothing (actors wait for the world time), so the host sends the change itself: "PAUSE|1|host" / "PAUSE|0|".
-- - Player 2: SetGamePaused always fails on a client (no game mode), so its pause menu never opened. Its menu now
--   opens (the call reports success) and sends "PAUSE,1" / "PAUSE,0"; its own world pauses from the host's
--   message (WorldSettings.PauserPlayerState set locally, the engine's own paused state) with a note on screen.
-- UE4SS runs the Lua callback of a Blueprint function after its body (PauseStates already updated, Success
-- already written: the callback can still change it), and the callback of a native function before it.
-- SetGamePaused fails when the world already is in the asked state, so with a partner the pause menu's call always
-- reports success (on both machines).
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local M = {}
    local UIM = "/Game/Systems/Managers/BP_UIManager.BP_UIManager_C"
    local PARTNER = "PDCoopPartner"
    local NOTE = "PDCoopPause"
    local hostHooked = false
    local partnerWants = false      -- host: player 2's pause menu is open
    local sentState = nil           -- host: last "PAUSE|..." sent
    local resendAt = 0
    local lastCmd = nil             -- player 2: last PAUSE command sent
    local applied, appliedWho = false, nil  -- player 2: the host's pause applied here, whose menu
    local myMenu = false            -- player 2: its own pause menu is open

    local function uiManager() return FindFirstOf("BP_UIManager_C") end
    local function gs() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    -- reason -> bool from BP_UIManager.PauseStates
    local function reasons()
        local r = {}
        local u = uiManager()
        if valid(u) then
            pcall(function() u.PauseStates:ForEach(function(k, v) r[k:get():ToString():lower()] = v:get() end) end)
        end
        return r
    end
    local function say(text)
        local wl = FindFirstOf("UMG_Feedback_WarningList_C")
        if not valid(wl) then return end
        pcall(function()
            wl:SetVisibility(4)
            wl["Close Message"](wl, FName(NOTE))
            if text then wl["Add Message"](wl, FText(text), 1, FName(NOTE), nil) end
        end)
    end
    -- this machine's world settings (the persistent level's; streamed sublevels and a leftover WorldSettings_0
    -- in the same level have their own)
    local function worldSettings()
        local ws = nil
        pcall(function() ws = ctx.UEHelpers.GetWorld().PersistentLevel.WorldSettings end)
        return valid(ws) and ws or nil
    end

    -- ---------------------------------------------------------------- host
    local function hostState()
        local r = reasons()
        local host, p2 = r.pausemenu == true, r[PARTNER:lower()] == true
        local who = (host and p2) and "both" or (host and "host" or (p2 and "p2" or ""))
        return string.format("PAUSE|%d|%s", (host or p2) and 1 or 0, who)
    end
    local function hostBroadcast(force)
        local st = hostState()
        if st ~= sentState or force then
            if st ~= sentState then log("PAUSE state %s", st) end
            sentState = st
            ctx.hostSend(st)
        end
    end
    local function setPartner(want)
        partnerWants = want
        local u = uiManager()
        if not valid(u) then return end
        local ok, err = pcall(function() u:PauseGame(FName(PARTNER), want, {}) end)
        log("PAUSE partner %s ok=%s %s", want and "paused" or "resumed", tostring(ok), ok and "" or tostring(err))
        hostBroadcast()
    end
    local function onPauseGame(_, reason, _, success)
        if not ctx.enabled() or not ctx.clientsPresent() then return end
        -- the engine reports failure when the world already is in that state (the partner's menu keeps it
        -- paused): the host's menu then neither opened nor closed (exp246)
        local r = ""
        pcall(function() r = reason:get():ToString():lower() end)
        if r == "pausemenu" then pcall(function() success:set(true) end) end
        hostBroadcast()
    end
    local function hostHooks()
        if hostHooked then return end
        hostHooked = true
        -- the world pause itself: with a partner connected only the two pause menus count
        RegisterHook("/Script/Engine.GameplayStatics:SetGamePaused", function(_, _, paused)
            if not ctx.enabled() or not ctx.clientsPresent() then return end
            local r = reasons()
            local want = r.pausemenu == true or r[PARTNER:lower()] == true
            local asked = false
            pcall(function() asked = paused:get() end)
            if asked ~= want then
                pcall(function() paused:set(want) end)
                log("PAUSE world pause %s -> %s (pause menus: host %s, player 2 %s)", tostring(asked), tostring(want),
                    tostring(r.pausemenu == true), tostring(r[PARTNER:lower()] == true))
            end
        end)
        log("PAUSE host hook on SetGamePaused in place")
    end
    function M.hostTick()
        if not ctx.enabled() then return end
        hostHooks()
        ctx.Events.hookFunction(UIM .. ":PauseGame", onPauseGame)
        if partnerWants and not ctx.clientsPresent() then
            log("PAUSE player 2 left with its pause menu open")
            setPartner(false)
        end
        -- while paused, now and then again (a player who joined, a lost message)
        if sentState and sentState:sub(1, 7) == "PAUSE|1" and os.time() >= resendAt then
            resendAt = os.time() + 5
            hostBroadcast(true)
        end
    end
    function M.hostCommand(kind, args)
        if kind ~= "PAUSE" then return false end
        if ctx.enabled() then setPartner(args == "1") end
        return true
    end

    -- ---------------------------------------------------------------- player 2
    local function applyLocal(paused, who)
        local ws = worldSettings()
        if not valid(ws) then return end
        local ps = nil
        if paused then
            for _, p in ipairs(FindAllOf("PlayerState") or {}) do if valid(p) and not ps then ps = p end end
        end
        local ok, err = pcall(function() ws.PauserPlayerState = ps end)
        applied, appliedWho = paused, who
        log("PAUSE here %s (%s) ok=%s %s", paused and "paused" or "resumed", who, tostring(ok), ok and "" or tostring(err))
        if paused and (who == "host" or who == "both") and not myMenu then
            say("Co-op: your partner paused the game.")
        else
            say(nil)
        end
    end
    local function onMyPauseGame(_, reason, paused, success)
        if not ctx.enabled() then return end
        local r = ""
        pcall(function() r = reason:get():ToString():lower() end)
        if r ~= "pausemenu" then return end
        local want = false
        pcall(function() want = paused:get() end)
        -- the menu opens / closes only on success; the world pause itself comes from the host
        pcall(function() success:set(true) end)
        myMenu = want
        local cmd = want and "1" or "0"
        if cmd ~= lastCmd then
            lastCmd = cmd
            ctx.sendCommand("PAUSE," .. cmd)
            log("PAUSE my pause menu %s", want and "opened" or "closed")
        end
        if want then say(nil)
        elseif applied and (appliedWho == "host" or appliedWho == "both") then say("Co-op: your partner paused the game.") end
    end
    function M.clientTick()
        if not ctx.enabled() then return end
        ctx.Events.hookFunction(UIM .. ":PauseGame", onMyPauseGame)
    end
    ctx.hostMsgHandlers["PAUSE"] = function(payload)
        if not ctx.enabled() then return end
        local p, who = payload:match("^([01])|?(.*)$")
        local want = p == "1"
        who = who or ""
        if want ~= applied or who ~= appliedWho then applyLocal(want, who) end
    end

    -- a new map: nothing paused, hooks again (Blueprint classes are loaded again)
    function M.reset()
        if applied then pcall(applyLocal, false, "map change") end
        applied, appliedWho, myMenu, lastCmd, partnerWants, sentState = false, nil, false, nil, false, nil
    end
    return M
end
