-- PDCoopNet cardoors: the car's doors and trunk lid open and shut on both machines as events (owner's rule: play the
-- event, the state is only the check afterwards).
--
-- Car parts are not replicated: every machine has its own door parts on its own copy of the car. A door that starts
-- opening or shutting (the part's AttemptOpen / AttemptShut: E on it goes through them, exp187) is sent as a tiny
-- event "CD|<door><o|s>" (door: fl fr rl rr t, where the part sits on the car) and the other machine calls the same
-- event on its part, so the door swings the same way at the same moment (AttemptOpen swings a door of player 2's car
-- copy too). The host is the truth: player 2's own door events go to the host as "CD,<door><o|s>"; the host plays
-- them on its car and passes them on. Every 5 s the host compares each door's angle with what it sent (a bump can
-- shut a door without an event). Player 2 asks for every door ("CD,?") once its car's doors are there (the host's
-- answer at the moment of the join came before player 2 had its car, exp188).
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local EV = ctx.Events
    local M = {}
    local BASE = "/Game/Gameplay/Inventory/Items/Car/Doors/BP_CarPart_Door_Base.BP_CarPart_Door_Base_C"
    local applying = false      -- this machine is playing the other machine's event: its own hooks stay quiet
    local lastSent = {}         -- host: door -> "o" / "s" as last sent
    local lastAt = {}           -- host: door -> os.clock() of its last event (still swinging: not checked)
    local asked = false         -- player 2: asked for the host's doors on this map
    local localAt = {}          -- player 2: door -> os.clock() of its own last event there
    local swing = {}            -- door -> { to = "o" / "s", at = os.clock() }: the last event played on this machine
    local ticks = 0

    -- the car's door parts by where they sit on it (exp187, wagon: front doors 131 uu ahead of the car's origin,
    -- rear doors 8, both 94 to the side; the trunk lid 194 behind, in the middle)
    local function doorName(car, part)
        local l, c = part:K2_GetActorLocation(), car:K2_GetActorLocation()
        local f, r = car:GetActorForwardVector(), car:GetActorRightVector()
        local dx, dy, dz = l.X - c.X, l.Y - c.Y, l.Z - c.Z
        local fwd, right = dx * f.X + dy * f.Y + dz * f.Z, dx * r.X + dy * r.Y + dz * r.Z
        if math.abs(right) < 40 then return "t" end
        return (fwd > 70 and "f" or "r") .. (right < 0 and "l" or "r")
    end
    local function doors()
        local car = ctx.playerCar()
        local out = {}
        if not valid(car) then return out end
        local carName = car:GetFullName()
        for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
            if valid(d) then
                local ok, par = pcall(function() return d:GetAttachParentActor() end)
                if ok and valid(par) and par:GetFullName() == carName then
                    local okN, name = pcall(doorName, car, d)
                    if okN then out[name] = d end
                end
            end
        end
        return out
    end
    -- open: the door's mesh turned away from the car's forward direction (doors swing ~50 degrees, the trunk lid ~78;
    -- the part's DoorOpen stayed false for an open door, exp187)
    local function isOpen(d)
        local car = ctx.playerCar()
        local mf, cf = d.MainMesh:GetForwardVector(), car:GetActorForwardVector()
        return mf.X * cf.X + mf.Y * cf.Y + mf.Z * cf.Z < 0.966      -- more than 15 degrees
    end
    local function play(name, what)
        local d = doors()[name]
        if not d then return false end
        applying = true
        local ok, err = pcall(function()
            if what == "o" then d:AttemptOpen() else d:AttemptShut() end
        end)
        applying = false
        if ok then swing[name] = { to = what, at = os.clock() } end
        if not ok then log("CARDOOR %s %s failed: %s", name, what, tostring(err)) end
        return ok
    end

    -- a door of this machine starts to open / shut (E, the game): tell the other side
    local function onEvent(what)
        return function(selfp)
            if applying or not ctx.enabled() then return end
            local part = selfp:get()
            if not valid(part) then return end
            local partName = part:GetFullName()
            for name, d in pairs(doors()) do
                if d:GetFullName() == partName then
                    if ctx.role() == "host" then
                        ctx.hostSend("CD|" .. name .. what)
                        lastSent[name], lastAt[name] = what, os.clock()
                    elseif ctx.role() == "client" then
                        ctx.sendCommand("CD," .. name .. what)
                        localAt[name] = os.clock()
                    end
                    swing[name] = { to = what, at = os.clock() }
                    log("CARDOOR %s %s here: sent", name, what == "o" and "opens" or "shuts")
                    return
                end
            end
        end
    end
    local hooked = false
    local function hook()
        if hooked then return end
        local okO = EV.hookFunction(BASE .. ":AttemptOpen", onEvent("o"))
        local okS = EV.hookFunction(BASE .. ":AttemptShut", onEvent("s"))
        hooked = okO and okS
    end

    -- host: player 2 opened / shut a door of its car
    local function sendAll()
        for name, d in pairs(doors()) do
            local okO, open = pcall(isOpen, d)
            if okO then
                lastSent[name] = open and "o" or "s"
                ctx.hostSend("CD|" .. name .. lastSent[name])
            end
        end
    end
    function M.hostCommand(kind, args)
        if kind ~= "CD" then return false end
        if args == "?" then sendAll(); return true end
        local name, what = args:match("^(%a+)([os])$")
        if name and play(name, what) then
            ctx.hostSend("CD|" .. name .. what)
            lastSent[name], lastAt[name] = what, os.clock()
            log("CARDOOR %s %s by player 2: played, passed on", name, what)
        end
        return true
    end
    -- player 2: the host's door event (or the state check / join state, which repeats a state: nothing to play
    -- when the door is there already)
    ctx.hostMsgHandlers["CD"] = function(rest)
        if not ctx.enabled() then return end
        local name, what = rest:match("^(%a+)([os])$")
        local d = name and doors()[name]
        if not d then return end
        -- the host passes player 2's own events back: an older one arriving after player 2's next one re-opened a
        -- door player 2 had just shut (exp191: E to get in opens and shuts the door within a second)
        if os.clock() - (localAt[name] or -99) < 2 then return end
        -- a door still swinging is where its last event sends it: a door that has only just started to open is
        -- under 15 degrees and looked shut, so the host's "shut" right after was dropped (review of 2026-10-24)
        local sw = swing[name]
        if sw and os.clock() - sw.at < 3 then
            if sw.to == what then return end
        else
            local okO, open = pcall(isOpen, d)
            if okO and open == (what == "o") then return end
        end
        if play(name, what) then log("CARDOOR %s %s by the host: played", name, what) end
    end

    -- host, every second: hooks; every 5 s a door whose angle no longer matches what was sent is sent again
    function M.hostTick()
        if not ctx.enabled() then return end
        hook()
        ticks = ticks + 1
        if ticks % 5 ~= 0 then return end
        for name, d in pairs(doors()) do
            local okO, open = pcall(isOpen, d)
            local what = open and "o" or "s"
            local swinging = os.clock() - (lastAt[name] or -99) < 3
            if okO and lastSent[name] ~= what and not swinging then
                ctx.hostSend("CD|" .. name .. what)
                lastSent[name] = what
            end
        end
    end
    function M.clientTick()
        if not ctx.enabled() then return end
        hook()
        if not asked and next(doors()) ~= nil then
            asked = true
            ctx.sendCommand("CD,?")
        end
    end
    function M.reset() lastSent, lastAt, localAt, swing, asked, hooked = {}, {}, {}, {}, false, false end
    return M
end
