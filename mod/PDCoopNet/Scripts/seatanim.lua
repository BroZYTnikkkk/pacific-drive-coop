-- PDCoopNet seatanim: player 2 getting in / out of the car, as the host sees it.
--
-- Player 2's own game plays the entry (about 2 s: to the passenger door's entrance point, then onto the seat) and
-- the exit; its character is not moved by its movement component meanwhile, so the host had it standing at the door
-- and then on the seat at once when SEAT came 2.1 s later, and outside at once on UNSEAT (owner: "on the host it
-- jumps into the seat and back"). Now player 2 sends "ENTERING" the moment its entry starts and the host moves its
-- body the same way every frame (relative to the car), ending where SEAT attaches it; the host's movement checks of
-- that character are off meanwhile (no corrections pulling player 2 around during its own animation). On UNSEAT
-- the character itself stands outside at once, as before (moving the actor out instead threw the car aside when
-- the host then replayed player 2's own moves, exp257-260); only its visible mesh moves there from the seat.
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local M = {}
    local GLIDE_IN, GLIDE_OUT = { 0.8, 1.9 }, { 0.4, 1.1 }   -- seconds: at the door's entrance point, at the end
    local glides = {}        -- character full name -> { ch, car, kind, t0, times, pts (car-relative), yaw0, yaw1 }
    local loopStarted = false

    local function carRel(car, l)
        local c, f, r = car:K2_GetActorLocation(), car:GetActorForwardVector(), car:GetActorRightVector()
        local dx, dy, dz = l.X - c.X, l.Y - c.Y, l.Z - c.Z
        return { dx * f.X + dy * f.Y, dx * r.X + dy * r.Y, dz }
    end
    local function carWorld(car, p)
        local c, f, r = car:K2_GetActorLocation(), car:GetActorForwardVector(), car:GetActorRightVector()
        return { X = c.X + f.X * p[1] + r.X * p[2], Y = c.Y + f.Y * p[1] + r.Y * p[2], Z = c.Z + p[3] }
    end
    local function flags(ch, on)
        pcall(function() ch.CharacterMovement.bIgnoreClientMovementErrorChecksAndCorrection = on end)
        if on then
            pcall(function() ch.CharacterMovement:DisableMovement() end)
            pcall(function() ch:SetActorEnableCollision(false) end)
        end
    end
    local function frame()
        for key, g in pairs(glides) do
            local ch, car = g.ch, g.car
            if not valid(ch) or not valid(car) then
                glides[key] = nil
            elseif not g.done and not (g.kind == "in" and os.clock() - g.t0 > 6) then
                -- getting in, the body stays on the seat (moving with the car) until SEAT attaches it
                local t = os.clock() - g.t0
                local a, b, u
                if t < g.times[1] then a, b, u = g.pts[1], g.pts[2], t / g.times[1]
                elseif t < g.times[2] then a, b, u = g.pts[2], g.pts[3], (t - g.times[1]) / (g.times[2] - g.times[1])
                else a, b, u = g.pts[3], g.pts[3], 1 end
                u = u * u * (3 - 2 * u)        -- ease in / out
                local p = { a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u, a[3] + (b[3] - a[3]) * u }
                if g.mesh then
                    -- the mesh where the actor would be, keeping its own offset to the actor
                    local w, l = carWorld(car, p), ch:K2_GetActorLocation()
                    pcall(function()
                        g.mesh:K2_SetRelativeLocation({ X = g.rel0.X, Y = g.rel0.Y, Z = g.rel0.Z }, false, {}, true)
                        local m = g.mesh:K2_GetComponentLocation()
                        g.mesh:K2_SetWorldLocation({ X = m.X + w.X - l.X, Y = m.Y + w.Y - l.Y, Z = m.Z + w.Z - l.Z }, false, {}, true)
                    end)
                else
                    pcall(function() ch:K2_SetActorLocation(carWorld(car, p), false, {}, true) end)
                    local k = math.min(1, t / g.times[2])
                    local dyaw = ((g.yaw1 - g.yaw0 + 180) % 360) - 180
                    pcall(function() ch:K2_SetActorRotation({ Pitch = 0, Yaw = g.yaw0 + dyaw * k, Roll = 0 }, true) end)
                end
                if t >= g.times[2] and g.after then
                    g.done = true
                    pcall(g.after)
                end
            elseif g.kind == "in" then
                -- no SEAT after the entry (player 2's entry stopped): back on its feet where the glide ended
                glides[key] = nil
                flags(ch, false)
                if not ctx.isSeated(key) then
                    ctx.standOnFeet(ch)
                    log("SEATANIM %s: no SEAT after its entry, standing again", ctx.objName(ch))
                end
            end
        end
    end
    local function ensureLoop()
        if loopStarted then return end
        loopStarted = true
        LoopInGameThreadWithDelay(16, function()
            if next(glides) then pcall(frame) end
        end)
    end
    local function start(ch, car, kind, pts, times, yaw1, after)
        glides[ch:GetFullName()] = { ch = ch, car = car, kind = kind, t0 = os.clock(), times = times, pts = pts,
            yaw0 = ch:K2_GetActorRotation().Yaw, yaw1 = yaw1, after = after }
        flags(ch, true)
        ensureLoop()
    end
    local function doorPoint(car, near)
        local door = ctx.passengerDoorOf(car)
        local ep = door and ctx.nearestEntryPoint(door, near)
        return ep and ep:K2_GetComponentLocation() or near
    end

    -- the body is being moved by a glide: the seat keeper leaves it alone
    function M.busy(ch) return glides[ch:GetFullName()] ~= nil end

    -- host: player 2's entry started on its machine ("ENTERING")
    function M.getIn(ch, car, seat)
        if not ctx.enabled() then return end
        local from = ch:K2_GetActorLocation()
        local mid = doorPoint(car, from)
        start(ch, car, "in", { carRel(car, from), carRel(car, { X = mid.X, Y = mid.Y, Z = from.Z }), carRel(car, seat) },
            GLIDE_IN, car:K2_GetActorRotation().Yaw)
        log("SEATANIM %s gets in: from %s past the door to the seat", ctx.objName(ch), ctx.fmtLoc(ch))
    end
    -- host: SEAT arrived; the glide (if any) has the body on the seat already
    function M.seated(ch)
        local g = glides[ch:GetFullName()]
        if not g then return false end
        glides[ch:GetFullName()] = nil
        flags(ch, false)
        log("SEATANIM %s: SEAT %.1f s after its entry started", ctx.objName(ch), os.clock() - g.t0)
        return true
    end
    -- host: UNSEAT; the character stands at spot already (found by the engine's check); its mesh walks there from
    -- seatAt, past the door
    function M.getOut(ch, car, seatAt, spot)
        if not ctx.enabled() then return end
        local mesh = ch.Mesh
        if not valid(mesh) then return end
        local rel = mesh.RelativeLocation
        local rel0 = { X = rel.X, Y = rel.Y, Z = rel.Z }
        local final = { X = spot.X, Y = spot.Y, Z = spot.Z }
        local mid = doorPoint(car, final)
        glides[ch:GetFullName()] = { ch = ch, car = car, kind = "out", t0 = os.clock(), times = GLIDE_OUT, mesh = mesh, rel0 = rel0,
            pts = { carRel(car, seatAt), carRel(car, { X = mid.X, Y = mid.Y, Z = (seatAt.Z + final.Z) / 2 }), carRel(car, final) },
            after = function()
                glides[ch:GetFullName()] = nil
                pcall(function() mesh:K2_SetRelativeLocation(rel0, false, {}, true) end)
            end }
        ensureLoop()
        log("SEATANIM %s gets out: its mesh from the seat to %.0f,%.0f,%.0f", ctx.objName(ch), final.X, final.Y, final.Z)
    end
    function M.reset() glides = {} end
    return M
end
