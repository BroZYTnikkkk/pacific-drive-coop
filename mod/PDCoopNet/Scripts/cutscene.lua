-- PDCoopNet cutscene: the new-game opening (the story title cards) is skipped with E, for both players.
--
-- The intro map's level script skips the opening itself: on Interact (E), while its CanSkip is set, it moves the
-- opening sequence to its end (SkipCutScene, frame 2017; exp232). The player controller binds Interact too and
-- consumes the key, and it comes before the level script in the input stack, so in co-op the press never reached
-- the level (owner's playtest: "nobody could skip the opening"; calling the level's Interact event directly skipped
-- it at once, exp232). The mod hands an E press during the opening to the level's own Interact event, and the
-- skip is an event for both: "SKIPCUT" (host -> player 2) / "SKIPCUT" command (player 2 -> host, played and
-- passed on), so the opening ends on both machines at the same moment.
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local M = {}
    local INTERACT = "InpActEvt_Interact_K2Node_InputActionEvent_0"

    -- the level script that can skip its opening right now
    local function skippableLevel()
        for _, l in ipairs(FindAllOf("LevelScriptActor") or {}) do
            if valid(l) then
                local ok, can = pcall(function() return l.CanSkip end)
                if ok and can == true then return l end
            end
        end
        return nil
    end
    -- the level's own skip, as its E press does it
    local function skipHere(why)
        local l = skippableLevel()
        if not l then return false end
        local ok, err = pcall(function() l[INTERACT](l, { KeyName = FName("E") }) end)
        log("CUTSCENE opening skipped here (%s) ok=%s %s", why, tostring(ok), ok and "" or tostring(err))
        return ok
    end

    -- this player pressed E (main.lua's key bind, on the game thread)
    function M.keyPressed()
        if not ctx.enabled() or not skippableLevel() then return end
        if ctx.role() == "host" then
            if skipHere("E") then ctx.hostSend("SKIPCUT|") end
        elseif ctx.role() == "client" then
            skipHere("E")
            ctx.sendCommand("SKIPCUT")
        end
    end
    -- host: player 2 skipped
    function M.hostCommand(kind)
        if kind ~= "SKIPCUT" then return false end
        skipHere("player 2's E")
        ctx.hostSend("SKIPCUT|")
        return true
    end
    -- player 2: the host (or player 2 itself, passed back) skipped
    ctx.hostMsgHandlers["SKIPCUT"] = function()
        if ctx.enabled() then skipHere("the host's skip") end
    end
    return M
end
