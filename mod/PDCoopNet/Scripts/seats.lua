-- PDCoopNet seats: you sit down by pressing E while looking at a free front seat through its open door; E on a door
-- only opens or shuts it (owner, 2026-10-25: every door can be opened, you sit with E on the seat; "variant a":
-- the seat's door has to be open). Items lying on the passenger seat are ignored (owner: sit as if nothing is
-- there).
--
-- The game: E on a door part ends in its Highlight's events. On the driver's door (door location 0) event 1 opens
-- a shut door and enters once the door passes FrontDoorAngleOfEnter (StartEntry(true), ReceiveTick), or enters at
-- once when it is open (StartEntry(false) -> EnterCar(false)); other doors only toggle (events 0 / 2). With the
-- driver's door FrontDoorAngleOfEnter out of reach (set on every machine), its E toggles too. Sitting calls the
-- door's own EnterCar(false): the game's entry through that door (CommandEnterCar(false, door) on the character).
--
-- Seats are a table so rear seats / more players can be added: { name, door, side }. Now: the host takes the
-- driver's seat, player 2 the passenger's (the host drives); the host keeps who sits where (SEAT / UNSEAT).
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local M = {}
    local NO_ENTRY_ANGLE = 999
    local SEATS = {
        { name = "driver", door = "fl", side = -1 },
        { name = "passenger", door = "fr", side = 1 },
    }
    local LOOK_RANGE, LOOK_COS = 260, math.cos(math.rad(22))
    local hinting = nil
    local angleSet = {}            -- door part full name -> true once its entry angle is out of reach

    -- the car's door parts by name (fl fr rl rr), as cardoors.lua names them
    local function doors(car)
        local out = {}
        local carName = car:GetFullName()
        local c, f, r = car:K2_GetActorLocation(), car:GetActorForwardVector(), car:GetActorRightVector()
        for _, d in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
            local okP, par = pcall(function() return d:GetAttachParentActor() end)
            if okP and valid(par) and par:GetFullName() == carName then
                local l = d:K2_GetActorLocation()
                local dx, dy = l.X - c.X, l.Y - c.Y
                local fwd, right = dx * f.X + dy * f.Y, dx * r.X + dy * r.Y
                if math.abs(right) >= 40 then out[(fwd > 70 and "f" or "r") .. (right < 0 and "l" or "r")] = d end
            end
        end
        return out
    end
    local function isOpen(d, car)
        local mf, cf = d.MainMesh:GetForwardVector(), car:GetActorForwardVector()
        return mf.X * cf.X + mf.Y * cf.Y + mf.Z * cf.Z < 0.966      -- more than 15 degrees
    end
    local function seatPoint(car, seat)
        local s = car:K2_GetActorLocation()
        pcall(function() s = car.TempSocket_Seat:K2_GetComponentLocation() end)
        if seat.side < 0 then return s end
        local r = car:GetActorRightVector()
        local off = ctx.passengerOffset
        return { X = s.X + r.X * off, Y = s.Y + r.Y * off, Z = s.Z }
    end
    -- the seat this player may take: its own (host: driver, player 2: passenger)
    local function mySeat()
        return ctx.role() == "host" and SEATS[1] or SEATS[2]
    end
    -- looking at my seat, close enough, its door open?
    local function lookingAtMySeat(car, ds)
        local pc = ctx.localController()
        if not valid(pc) then return nil end
        local cam = pc.PlayerCameraManager
        local okC, cl = pcall(function() return cam:GetCameraLocation() end)
        local okR, cr = pcall(function() return cam:GetCameraRotation() end)
        if not okC or not okR then return nil end
        local seat = mySeat()
        local p = seatPoint(car, seat)
        local dx, dy, dz = p.X - cl.X, p.Y - cl.Y, p.Z - cl.Z
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dist > LOOK_RANGE or dist < 1 then return nil end
        local yaw, pitch = math.rad(cr.Yaw), math.rad(cr.Pitch)
        local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
        if (fx * dx + fy * dy + fz * dz) / dist < LOOK_COS then return nil end
        local d = ds[seat.door]
        if not valid(d) then return nil end
        local okO, open = pcall(isOpen, d, car)
        return seat, d, okO and open
    end
    local function say(text)
        local wl = FindFirstOf("UMG_Feedback_WarningList_C")
        if not valid(wl) then return end
        pcall(function()
            wl:SetVisibility(4)
            wl["Close Message"](wl, FName("PDCoopSeat"))
            if text then wl["Add Message"](wl, FText(text), 1, FName("PDCoopSeat"), nil) end
        end)
    end

    -- every second: the driver's door no longer enters by itself; a hint while looking at my seat
    function M.tick()
        if not ctx.enabled() then return end
        local car = ctx.playerCar()
        if not valid(car) then return end
        local ds = doors(car)
        local fl = ds.fl
        if valid(fl) and not angleSet[fl:GetFullName()] then
            local ok = pcall(function() fl.FrontDoorAngleOfEnter = NO_ENTRY_ANGLE end)
            angleSet[fl:GetFullName()] = ok
            log("SEATS the driver's door enters no more by itself (E opens / shuts it) ok=%s", tostring(ok))
        end
        local text = nil
        if not ctx.seated() then
            local seat, _, open = lookingAtMySeat(car, ds)
            if seat then text = open and "E: sit down" or "Open the door to sit down" end
        end
        if text ~= hinting then
            hinting = text
            say(text)
        end
    end

    -- an Interact press that used nothing (main.lua's HighlightPress hook): sit down if I look at my seat
    function M.pressed()
        if not ctx.enabled() or ctx.seated() then return false end
        local car = ctx.playerCar()
        if not valid(car) then return false end
        local seat, d, open = lookingAtMySeat(car, doors(car))
        if not seat then return false end
        if not open then
            log("SEATS E at the %s seat: its door is shut", seat.name)
            return true
        end
        local ok, err = pcall(function() d:EnterCar(false) end)
        log("SEATS E at the %s seat: entering through its door ok=%s %s", seat.name, tostring(ok), ok and "" or tostring(err))
        hinting = nil
        say(nil)
        return true
    end

    -- E on a door part (its Highlight events, after their own body: an open door has just started to shut). The
    -- door's interaction covers the whole doorway, so looking at the seat through an open door hits the door
    -- (exp289): that press sits down instead - the door opens again and the game's entry through it starts.
    local lastPress = -99
    function M.doorPressed(part)
        if not ctx.enabled() or ctx.seated() or os.clock() - lastPress < 1 then return end
        local car = ctx.playerCar()
        if not valid(car) or not valid(part) then return end
        local seat, d, open = lookingAtMySeat(car, doors(car))
        if not seat or not valid(d) or d:GetFullName() ~= part:GetFullName() or not open then
            log("SEATS door press, no sitting: looking at my seat=%s, its door=%s, open=%s", tostring(seat and seat.name),
                tostring(valid(d) and d:GetFullName() == part:GetFullName()), tostring(open))
            return
        end
        lastPress = os.clock()
        local ok, err = pcall(function()
            d:AttemptOpen()
            d:EnterCar(false)
        end)
        log("SEATS E at the %s seat through its open door: entering ok=%s %s", seat.name, tostring(ok), ok and "" or tostring(err))
        hinting = nil
        say(nil)
    end

    function M.reset() angleSet, hinting = {}, nil end
    return M
end
