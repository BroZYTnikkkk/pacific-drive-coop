-- PDCoopNet downed: a player who would die is "down" instead; the other player can revive them.
-- Owner's rules (2026-10-20):
--   down: lies (cannot move), takes no damage, 60 s until the team dies; both down at once -> the team dies.
--   revive: the other player holds E within 2 m for 5 s; with a first aid item (one is used up) the downed player
--           gets 60 % health, without one 20 %. Both directions (host revives player 2 and player 2 the host).
--   team death: the game's own death on the host (garage, losses by biome, tombstone); player 2 loses items by the
--           same rule (the host records the arguments the game used for its own RemoveRandomItems calls, player 2's
--           game runs RemoveRandomItems with them), and player 2's lost items go into the host's tombstone.
-- How "down" works: the game applies player damage in AC_PlayerHealthReceiverHelper; its CheckForLifesaver has an
-- out parameter UpdatedDMG (negative = damage) that a post-hook can change. Damage that would leave less than
-- 1 HP is cut to leave 1 HP and the player goes down; while down, damage is set to 0. Verified in
-- Wilderness_Forest_01 (dev session 2026-10-20): three 500-damage hits in a row left 1.0 HP, the player alive.
-- The garage protects the player (playerProtected), so it can only be tested in a zone.
-- Messages on screen use the HUD's UMG_Feedback_WarningList "Add Message" (not yet confirmed visible by a human).
return function(ctx)
    local log, valid, UEHelpers = ctx.log, ctx.valid, ctx.UEHelpers
    local M = {}
    local DOWN_SECONDS = 60
    local REVIVE_SECONDS = 5
    local REVIVE_RANGE = 200          -- uu (2 m)
    local REVIVE_KEY = "E"
    local HP_WITH_KIT, HP_WITHOUT = 0.60, 0.20
    local LIFESAVER = "/Game/Characters/Player/Components/AC_PlayerHealthReceiverHelper.AC_PlayerHealthReceiverHelper_C:CheckForLifesaver"
    local REMOVE_RANDOM = "/Game/Systems/ScriptingLibraries/BFL_ItemPropertyUtilityFns.BFL_ItemPropertyUtilityFns_C:RemoveRandomItems"

    local me = { down = false, since = 0, dying = false, hooked = false, tries = 0 }
    local host = { down = {}, teamDeathId = 0, penalty = nil, penaltySentFor = "", lost = {}, dyingSince = nil }
    local revive = { held = 0, target = nil, lastMsg = "" }
    local clock = os.clock

    local function playerHealth()
        local rm = FindFirstOf("BP_ResourceManager_C")
        local g = nil
        if valid(rm) then pcall(function() g = rm.PlayerHealth end) end
        return valid(g) and g or nil
    end
    local function localPc() return ctx.localController() end

    -- ------------------------------------------------------------ screen messages
    local shown = {}
    local function say(category, text)
        if shown[category] == text then return end
        shown[category] = text
        local wl = FindFirstOf("UMG_Feedback_WarningList_C")
        if valid(wl) then
            pcall(function()
                wl:SetVisibility(4)
                wl["Close Message"](wl, FName(category))
                wl["Add Message"](wl, FText(text), 1, FName(category), nil)
            end)
        end
        log("DOWNED screen [%s] %s", category, text)
    end
    local function unsay(category)
        if not shown[category] then return end
        shown[category] = nil
        local wl = FindFirstOf("UMG_Feedback_WarningList_C")
        if valid(wl) then pcall(function() wl["Close Message"](wl, FName(category)) end) end
    end

    -- ------------------------------------------------------------ local player
    -- down: no walking and no jumping (playtest: the downed friend could still jump)
    local function setMovementLocked(locked)
        local pc = localPc()
        if valid(pc) then pcall(function() pc:SetIgnoreMoveInput(locked) end) end
        local ch = nil
        pcall(function() ch = pc.Pawn end)
        if valid(ch) then
            pcall(function()
                local mv = ch.CharacterMovement
                if locked then mv:DisableMovement() else mv:SetMovementMode(1, 0) end   -- 1 = walking
            end)
        end
    end
    local function goDown()
        if me.down then return end
        me.down, me.since = true, clock()
        setMovementLocked(true)
        log("DOWNED this player is down (would have died)")
        if ctx.role() == "client" then ctx.sendCommand("DOWN") else M.hostPlayerDown("host") end
    end
    local function standUp(pct)
        local g = playerHealth()
        if valid(g) then
            local target = g.Maximum * pct
            pcall(function() g:Adjust(localPc(), target - g.Current) end)
        end
        me.down = false
        setMovementLocked(false)
        unsay("PDCoopSelf")
        log("DOWNED this player was revived with %d%% health", math.floor(pct * 100 + 0.5))
    end

    local function registerHooks()
        if me.hooked or me.tries > 30 then return end
        me.tries = me.tries + 1
        if not StaticFindObject(LIFESAVER) then return end
        local ok, err = pcall(function()
            RegisterHook(LIFESAVER, function(selfp, incoming, updated)
                -- Player health is one resource per process (BP_ResourceManager.PlayerHealth), but every machine has
                -- two characters, each with this receiver: damage to the other player's character here (a fall seen
                -- through replicated movement, a hit) was taken from this player's health ("one HP for two",
                -- playtest 2026-10-21). That character's own machine computes its damage; here it takes none.
                local recv, owner = nil, nil
                pcall(function() recv = selfp:get() end)
                pcall(function() owner = recv:GetOwner() end)
                if valid(owner) and not ctx.isMine(owner) then
                    pcall(function() updated:set(0) end)
                    return
                end
                if not ctx.enabled() then return end
                if me.dying then
                    -- player 2 must not die in its own game while the team death runs (it would leave the session);
                    -- the host dies through Adjust, which does not come through here
                    if ctx.role() == "client" then pcall(function() updated:set(0) end) end
                    return
                end
                local g = playerHealth()
                if not g then return end
                local d = updated:get()
                if type(d) ~= "number" then return end
                if me.down then
                    updated:set(0)
                elseif d < 0 and g.Current + d <= 1.001 then
                    -- also when the game's own one-time protection (magic health point) already cut the hit to
                    -- leave 1 HP: exp70 never went down because the hit arrived here as "leave 1"
                    local inc = nil
                    pcall(function() inc = incoming:get() end)
                    log("DOWNED lethal hit: health %.1f, damage %.1f (incoming %s)", g.Current, d, tostring(inc))
                    updated:set(math.min(0, 1 - g.Current))
                    goDown()
                end
            end)
        end)
        if ok then
            me.hooked = true
            log("DOWNED hooked CheckForLifesaver (lethal damage -> down)")
        else
            log("DOWNED hook failed: %s", tostring(err))
        end
        -- host: record the arguments of the game's own item removal on death
        if ctx.role() == "host" and StaticFindObject(REMOVE_RANDOM) then
            pcall(function()
                RegisterHook(REMOVE_RANDOM, function(_, container, rate, keepCrafted, mode, _, removed)
                    if not host.dyingSince then return end
                    local c = container:get()
                    local cname = valid(c) and c:GetFName():ToString() or "?"
                    local args = { rate = rate:get(), keep = keepCrafted:get(), mode = mode:get() }
                    local n, left = "?", "?"
                    pcall(function() n = removed:get():GetArrayNum() end)
                    pcall(function() left = c:GetNumItems() end)
                    log("DOWNED the game removed items on death: container %s rate %.3f keepCrafted %s mode %s: removed %s, left %s",
                        cname, args.rate, tostring(args.keep), tostring(args.mode), tostring(n), tostring(left))
                    -- the host's own pockets give the rule for player 2's pockets; send it at once, while both are
                    -- still in the zone (the rule depends on the map: run in the garage it removed nothing, exp71)
                    local im = FindFirstOf("BP_InventoryManager_C")
                    local pockets = nil
                    pcall(function() pockets = im.Inventory_Player end)
                    if valid(pockets) and valid(c) and c:GetFullName() == pockets:GetFullName() and not host.penaltySent then
                        host.penalty = args
                        host.penaltySent = true
                        ctx.hostSend(string.format("PENALTY|%d|%.4f|%s|%d", host.teamDeathId, args.rate or 0, tostring(args.keep), args.mode or 0))
                        log("DOWNED penalty arguments sent to player 2 (still in the zone)")
                    end
                end)
            end)
        end
    end

    -- ------------------------------------------------------------ team logic (host)
    local function anyoneUp()
        if not host.down.host then return true end
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() then
                local ok, pid = pcall(function() return pc.PlayerState.PlayerId end)
                if ok and not host.down[pid] then return true end
            end
        end
        return false
    end
    function M.hostPlayerDown(who)
        if host.down[who] then return end
        host.down[who] = clock()
        log("DOWNED host: %s is down", tostring(who))
    end
    local function teamDeath(reason)
        if host.dyingSince then return end
        host.dyingSince = clock()
        host.teamDeathId = host.teamDeathId + 1
        host.penaltySent = false
        log("DOWNED TEAM DEATH (%s): the game's own death runs on the host", reason)
        ctx.hostSend("TEAMDEATH|" .. host.teamDeathId)
        me.dying = true
        me.down = false
        setMovementLocked(false)
        local g = playerHealth()
        if valid(g) then pcall(function() g:Adjust(localPc(), -10 * g.Maximum) end) end
    end
    local function revivePlayer(who, pct)
        if not host.down[who] then return end
        host.down[who] = nil
        log("DOWNED host: %s revived (%d%%)", tostring(who), math.floor(pct * 100 + 0.5))
        if who == "host" then standUp(pct) else ctx.hostSend("REVIVED|" .. tostring(who) .. "|" .. pct) end
    end

    function M.hostCommand(kind, args, pc)
        if kind == "DOWN" then
            local pid = pc.PlayerState.PlayerId
            M.hostPlayerDown(pid)
            return true
        elseif kind == "REVIVE" then         -- player 2 revived the host
            local pct = tonumber(args) or HP_WITHOUT
            revivePlayer("host", pct)
            return true
        elseif kind == "LOST" then           -- player 2's lost items for the tombstone
            host.lost[#host.lost + 1] = args
            log("DOWNED player 2's lost items received (%d bytes)", #args)
            return true
        end
        return false
    end

    -- ------------------------------------------------------------ messages from the host (client)
    ctx.hostMsgHandlers["DOWNST"] = function(rest)
        -- "<who>=<seconds left>;..." who: host | <PlayerId>
        local mine = ctx.myPlayerId()
        local parts = {}
        for who, left in rest:gmatch("([^;=]+)=(%d+)") do
            if who ~= tostring(mine) then parts[#parts + 1] = "Your partner is down: " .. left .. " s" end
            if who == tostring(mine) then say("PDCoopSelf", "You are down: " .. left .. " s until the team dies. Wait for your partner.") end
        end
        if #parts > 0 then say("PDCoopOther", table.concat(parts, ", ") .. ". Hold " .. REVIVE_KEY .. " next to them to revive.")
        else unsay("PDCoopOther") end
        M.otherDown = {}
        for who in rest:gmatch("([^;=]+)=") do M.otherDown[who] = true end
    end
    ctx.hostMsgHandlers["REVIVED"] = function(rest)
        local who, pct = rest:match("^([^|]+)|([%d.]+)$")
        if who == tostring(ctx.myPlayerId()) then standUp(tonumber(pct) or HP_WITHOUT) end
        unsay("PDCoopOther")
    end
    ctx.hostMsgHandlers["TEAMDEATH"] = function(rest)
        log("DOWNED TEAM DEATH announced by the host (#%s)", rest)
        me.dying = true          -- until the next map: no more downs
        me.down = false
        setMovementLocked(false)
        unsay("PDCoopSelf"); unsay("PDCoopOther")
        say("PDCoopTeam", "Your team is dead. Back to the garage.")
        M.pendingTeamDeath = rest
        -- player 2 does not die in its own game (that would take it out of the session); it comes back like the
        -- host does after a death (the game gave the host 20 HP in the garage, dev session 2026-10-20)
        local g = playerHealth()
        if valid(g) then pcall(function() g:Adjust(localPc(), g.Maximum * 0.2 - g.Current) end) end
    end
    ctx.hostMsgHandlers["PENALTY"] = function(rest)
        -- "<id>|<rate>|<keepCrafted>|<mode>": run the game's own removal on player 2's inventory with the host's arguments
        local id, rate, keep, mode = rest:match("^(%d+)|(%-?[%d.]+)|(%a+)|(%-?%d+)$")
        if not id or M.penaltyDone == id then return end
        M.penaltyDone = id
        local lib = StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ItemPropertyUtilityFns.Default__BFL_ItemPropertyUtilityFns_C")
        local im = FindFirstOf("BP_InventoryManager_C")
        local lostKeys = {}
        for _, cname in ipairs({ "Inventory_Player", "Inventory_PlayerHand" }) do
            local cont = nil
            pcall(function() cont = im[cname] end)
            if valid(lib) and valid(cont) then
                local removed = {}
                local ok, err = pcall(function()
                    lib:RemoveRandomItems(cont, tonumber(rate), keep == "true", tonumber(mode), UEHelpers.GetWorldContextObject(), removed)
                end)
                local n = 0
                if ok and removed.Removed then
                    pcall(function()
                        removed.Removed:ForEach(function(_, e)
                            local inst = e:get()
                            local key = ctx.keyOf(inst)
                            if key then lostKeys[#lostKeys + 1] = key; n = n + 1 end
                        end)
                    end)
                end
                log("DOWNED penalty on %s: ok=%s removed %d item(s) %s", cname, tostring(ok), n, ok and "" or tostring(err))
            end
        end
        if #lostKeys > 0 then
            local counts = {}
            for _, k in ipairs(lostKeys) do counts[k] = (counts[k] or 0) + 1 end
            local parts = {}
            for k, n in pairs(counts) do parts[#parts + 1] = k .. "*" .. n end
            ctx.sendCommand("LOST," .. table.concat(parts, ";"))
        end
        say("PDCoopTeam", string.format("You lost %d item(s). They are in the tombstone with the host's.", #lostKeys))
    end

    -- ------------------------------------------------------------ ticks
    -- revive: the local player holds E next to a downed partner
    local function reviveTick(dt, downedChars)
        local pc = localPc()
        if not (valid(pc) and valid(pc.Pawn)) or me.down or me.dying then revive.held = 0; return end
        local myLoc = pc.Pawn:K2_GetActorLocation()
        local best = nil
        for who, ch in pairs(downedChars) do
            local l = ch:K2_GetActorLocation()
            local d = math.sqrt((l.X - myLoc.X) ^ 2 + (l.Y - myLoc.Y) ^ 2 + (l.Z - myLoc.Z) ^ 2)
            if d <= REVIVE_RANGE then best = who end
        end
        local holding = false
        pcall(function() holding = pc:IsInputKeyDown({ KeyName = FName(REVIVE_KEY) }) end)
        -- fallback if the game does not report the key as held: every press of E (UE4SS key hook, main.lua)
        -- counts for 0.6 s, so holding or tapping E both work
        if not holding and M.lastKeyPress and clock() - M.lastKeyPress < 0.6 then holding = true end
        -- dev tools (PDCoopDev "holdrevive on") stand in for the key in automated tests
        if not holding then pcall(function() holding = ModRef:GetSharedVariable("PDCoopDev_HoldRevive") == true end) end
        if best and holding then
            if revive.target ~= best then revive.target, revive.held = best, 0 end
            revive.held = revive.held + dt
            say("PDCoopRevive", string.format("Reviving... %d / %d s", math.floor(revive.held), REVIVE_SECONDS))
            if revive.held >= REVIVE_SECONDS then
                revive.held = 0
                unsay("PDCoopRevive")
                local pct = M.useFirstAid() and HP_WITH_KIT or HP_WITHOUT
                log("DOWNED revived %s (%d%%)", tostring(best), math.floor(pct * 100 + 0.5))
                if ctx.role() == "host" then revivePlayer(best, pct) else ctx.sendCommand("REVIVE," .. pct) end
            end
        else
            if revive.held > 0 then unsay("PDCoopRevive") end
            revive.held, revive.target = 0, nil
        end
    end

    -- uses one first aid item of this player; true if there was one
    local FIRST_AID = "/Game/Gameplay/Inventory/GenericItemProperties/IP_FirstAid.IP_FirstAid"
    function M.keyPressed() M.lastKeyPress = clock() end

    function M.useFirstAid()
        local st = StaticFindObject(FIRST_AID)
        local im = FindFirstOf("BP_InventoryManager_C")
        if not (valid(st) and valid(im)) then return false end
        for _, cname in ipairs({ "Inventory_PlayerHand", "Inventory_Player" }) do
            local cont = nil
            pcall(function() cont = im[cname] end)
            local found = nil
            if valid(cont) then
                pcall(function()
                    cont.Slots:ForEach(function(_, e)
                        if found then return end
                        local slot = e:get()
                        slot.Items:ForEach(function(_, it)
                            local inst = it:get()
                            if not found and valid(inst) and inst:HasProperties(st) then found = inst end
                        end)
                    end)
                end)
            end
            if found then
                local name = found.Archetype:GetFName():ToString()
                pcall(function() cont:RemoveItem(found) end)
                log("DOWNED used %s for the revive", name)
                return true
            end
        end
        return false
    end

    function M.tick(dt)
        registerHooks()          -- always: the hook also keeps damage of the other character off this player's health
        if not ctx.enabled() then return end
        if ctx.role() == "host" then
            if host.dyingSince then return end
            -- a downed player who left the session is no longer down here (no team death for an empty seat)
            local present = {}
            for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
                local ok, pid = pcall(function() return pc.PlayerState.PlayerId end)
                if ok and valid(pc) and not pc:IsLocalController() then present[pid] = true end
            end
            for who in pairs(host.down) do
                if who ~= "host" and not present[who] then
                    host.down[who] = nil
                    log("DOWNED host: %s left while down", tostring(who))
                end
            end
            -- downed characters for the host's revive: remote players that are down
            local chars = {}
            local status = {}
            for who, since in pairs(host.down) do
                local left = math.max(0, DOWN_SECONDS - math.floor(clock() - since))
                status[#status + 1] = tostring(who) .. "=" .. left
                if left <= 0 then teamDeath(tostring(who) .. " was not revived in " .. DOWN_SECONDS .. " s"); return end
                if who ~= "host" then
                    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
                        local ok, pid = pcall(function() return pc.PlayerState.PlayerId end)
                        if ok and pid == who and valid(pc.Pawn) then chars[who] = pc.Pawn end
                    end
                end
            end
            if next(host.down) and not anyoneUp() then teamDeath("everyone is down"); return end
            local text = table.concat(status, ";")
            if text ~= revive.lastMsg then
                revive.lastMsg = text
                ctx.hostSendLatest("DOWNST|" .. text)
                -- the host's own screen
                local mineLeft = nil
                local others = {}
                for who, since in pairs(host.down) do
                    local left = math.max(0, DOWN_SECONDS - math.floor(clock() - since))
                    if who == "host" then mineLeft = left else others[#others + 1] = "Your partner is down: " .. left .. " s" end
                end
                if mineLeft then say("PDCoopSelf", "You are down: " .. mineLeft .. " s until the team dies. Wait for your partner.") else unsay("PDCoopSelf") end
                if #others > 0 then say("PDCoopOther", table.concat(others, ", ") .. ". Hold " .. REVIVE_KEY .. " next to them to revive.") else unsay("PDCoopOther") end
            end
            reviveTick(dt, chars)
        else
            -- client: the host's character, if the host is down
            local chars = {}
            if M.otherDown and M.otherDown.host then
                for _, ch in ipairs(FindAllOf("PDP_MainCharacter_C") or {}) do
                    local ok, r = pcall(function() return ch.Role end)
                    if ok and r == 1 and valid(ch) then chars.host = ch end
                end
            end
            reviveTick(dt, chars)
        end
    end

    -- a new map: the team death is over (garage), downs are possible again
    function M.mapChanged(worldName)
        if me.dying then log("DOWNED new map %s after the team death", tostring(worldName)) end
        me.dying, me.down = false, false
        host.down = {}
        revive.lastMsg = ""
        setMovementLocked(false)
        for c in pairs(shown) do unsay(c) end
        host.dyingSince = nil
        M.otherDown = nil
    end

    -- host: after the team death, once player 2 is back, send the penalty arguments; put player 2's lost items in
    -- the tombstone when they arrive
    function M.hostAfterDeathTick()
        if not ctx.enabled() then return end
        if #host.lost > 0 then
            local cont = nil
            for _, leg in ipairs(FindAllOf("BP_LegStateBase_C") or {}) do
                local xf, c = {}, {}
                pcall(function() leg:GetTombstoneInfo(xf, c) end)
                local cc = c.Container
                if valid(cc) then cont = cc end
            end
            if cont then
                for _, text in ipairs(host.lost) do
                    local n = ctx.addEntries(cont, text)
                    log("DOWNED put %d of player 2's lost item(s) into the tombstone", n)
                end
            else
                log("DOWNED no tombstone found for player 2's lost items: they are gone (logged): %s", table.concat(host.lost, " | "))
            end
            host.lost = {}
        end
    end

    return M
end
