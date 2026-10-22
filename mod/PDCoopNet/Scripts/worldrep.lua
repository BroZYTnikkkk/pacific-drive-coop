-- PDCoopNet worldrep: the host's generated world content is replicated to player 2 by the engine.
--
-- Experiment exp93 (2026-10-22, docs/WORLD_SYNC.md): in a zone the game's spawners run only with authority, so on
-- player 2's machine the generated content did not exist at all (host 7794 actors, client 1146: no abandoned cars,
-- barrels, props). Turning on replication of those host actors makes the engine create them on the client: 205 gas
-- barrels -> 206 on the client, 198 in the same 50 uu cell; then every generated class, e.g. abandoned cars with
-- their parts, seen on the client's screen.
--
-- What is replicated: every actor of the host's world that was spawned at runtime (no RF_WasLoaded: level actors
-- exist on the client already), except players and their controllers/states, game mode/state, managers, HUD,
-- cameras, effects, and item actors (world items are synced by main.lua's item mirror).
-- Settings per actor: movement replicated, 2 updates per second (default 100: thousands of mostly static actors),
-- relevant up to 1.5 km (outside it the engine removes them on the client and sends them again when near).
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local M = {}
    local RF_WasLoaded = 0x00080000
    local CULL_SQ = 1.5e5 * 1.5e5          -- (1.5 km in uu)^2
    local seen = {}                         -- actor full name -> true (handled once)
    local SKIP_EXACT = { WorldSettings = true, GameNetworkManager = true, NiagaraActor = true, Emitter = true,
                         AmbientSound = true, SpectatorPawn = true, DefaultPawn = true }
    local SKIP_PART = { "Controller", "PlayerState", "GameMode", "GameState", "HUD", "Character", "Camera",
                        "Manager", "Director", "NavData", "NavMesh", "Navigation" }
    local total = 0

    local function skipClass(c)
        if SKIP_EXACT[c] then return true end
        for _, p in ipairs(SKIP_PART) do if c:find(p, 1, true) then return true end end
        return false
    end

    -- Placement of attached actors. The engine sends an attached actor as "attached to <the root actor of its
    -- attachment chain>, at <its offset to its immediate parent>", and the immediate parent component of the
    -- prefab "folder" actors (SetDressing, Layout, DOORS...) is created at runtime, not net addressable
    -- (FNetGUIDCache::SupportsObject warnings), so the client puts the actor at root * offset (exp101: doors
    -- 500-900 uu off; the host's prediction root * offset matched the client's spot within 3 uu). Making those
    -- components replicated broke the chain further (client copies with other names). So the host computes where
    -- the client will put each such actor and sends "class, that spot -> the right transform"; the client keeps the
    -- table and moves every matching replicated actor, also when it comes back into relevance.
    local K = nil
    local fixes = {}            -- host: list of { c = class, s = entry text, x, y, z, sent }; client: cell -> entries
    local fixCount, sentKey = 0, ""
    local placeErrLogged = false
    local function rootOf(a)
        local r, depth = a, 0
        while depth < 10 do
            local okP, p = pcall(function() return r:GetAttachParentActor() end)
            if not (okP and p and p:IsValid()) then break end
            r, depth = p, depth + 1
        end
        return r, depth
    end
    -- each newly replicated actor is looked at now and once more 2 host ticks (~10 s) later: a prefab can still
    -- move or re-attach its content after spawning it (exp104: a door's fix from its spawn moment never matched)
    local recheck, hostTicks = {}, 0
    local lastFix = {}          -- actor full name -> entry text sent for it
    local function hostPlacement(a, c)
        local key = a:GetFullName()
        if not lastFix[key] then recheck[#recheck + 1] = { a = a, c = c, due = hostTicks + 2 } end
        lastFix[key] = lastFix[key] or ""
        local r, depth = rootOf(a)
        if depth == 0 then return end
        local rc = a.RootComponent
        local parent = rc:GetAttachParent()
        if parent and parent:IsValid() and parent:GetAddress() == r.RootComponent:GetAddress() then return end
        K = K or ctx.UEHelpers.GetKismetMathLibrary()
        -- the root as the client gets it: ReplicatedMovement rounds the location to whole units and sends each
        -- rotation axis in 8 bits (360/256 degrees); 1.4 degrees at 13 m is 30 uu (exp105: the last door's fix did
        -- not match). Raising the precision on the host is not an option: the client reads the movement with its
        -- own default and the stream breaks (exp106: "Failed to receive property ReplicatedMovement", disconnect).
        local rl, rr = r:K2_GetActorLocation(), r:K2_GetActorRotation()
        local function q(v) return (math.floor(v * 256 / 360 + 0.5) % 256) * 360 / 256 end
        local function rnd(v) return math.floor(v + 0.5) end
        local rootRot = { Pitch = q(rr.Pitch), Yaw = q(rr.Yaw), Roll = q(rr.Roll) }
        local rootXf = K:MakeTransform({ X = rnd(rl.X), Y = rnd(rl.Y), Z = rnd(rl.Z) }, rootRot, r:GetActorScale3D())
        local p = K:TransformLocation(rootXf, rc.RelativeLocation)
        local w = a:K2_GetActorLocation()
        local wr = a:K2_GetActorRotation()
        local pr = K:ComposeRotators(rc.RelativeRotation, rootRot)
        local dr = K:NormalizedDeltaRotator(pr, wr)
        local dLoc = math.abs(p.X - w.X) + math.abs(p.Y - w.Y) + math.abs(p.Z - w.Z)
        local dRot = math.abs(dr.Yaw) + math.abs(dr.Pitch) + math.abs(dr.Roll)
        if dLoc < 3 and dRot < 1 then return end
        -- "where the client puts it" + the move to the right spot (small numbers) + yaw [+ pitch, roll]
        local s = string.format("%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f", p.X, p.Y, p.Z, w.X - p.X, w.Y - p.Y, w.Z - p.Z, wr.Yaw)
        if math.abs(wr.Pitch) > 0.05 or math.abs(wr.Roll) > 0.05 then s = s .. string.format(",%.1f,%.1f", wr.Pitch, wr.Roll) end
        if s == lastFix[key] then return end
        lastFix[key] = s
        fixes[#fixes + 1] = { c = c, s = s, x = w.X, y = w.Y, z = w.Z, sent = false }
        fixCount = fixCount + 1
    end
    local function hostRecheck()
        hostTicks = hostTicks + 1
        local keep, n = {}, 0
        for _, e in ipairs(recheck) do
            if e.due > hostTicks then keep[#keep + 1] = e
            elseif valid(e.a) then
                local before = fixCount
                pcall(hostPlacement, e.a, e.c)
                if fixCount > before then n = n + 1 end
            end
        end
        recheck = keep
        if n > 0 then log("WORLDREP placement: %d actor(s) moved after spawning, fixes updated", n) end
    end
    local function remotePlayers()
        local keys, at = {}, {}
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() then
                keys[#keys + 1] = pc:GetFullName()
                pcall(function() if valid(pc.Pawn) then at[#at + 1] = pc.Pawn:K2_GetActorLocation() end end)
            end
        end
        table.sort(keys)
        return table.concat(keys, ";"), at
    end
    -- host: everything to a new set of clients, then what is new; nearest to player 2 first; several classes per
    -- message up to 7 KB (exp102: one class per message made 154 messages, the channel does about 2 a second)
    local function hostSendFixes()
        local key, at = remotePlayers()
        if key == "" then sentKey = ""; return end
        local fresh = key ~= sentKey
        sentKey = key
        if fresh then ctx.hostSend("WFIXRESET|") end
        local pending = {}
        for _, f in ipairs(fixes) do
            if fresh or not f.sent then
                local d = 1e12
                for _, l in ipairs(at) do d = math.min(d, (f.x - l.X) ^ 2 + (f.y - l.Y) ^ 2 + (f.z - l.Z) ^ 2) end
                f.d = d; pending[#pending + 1] = f
            end
        end
        if #pending == 0 then return end
        table.sort(pending, function(a, b) return a.d < b.d end)
        local msgs, bytes = 0, 0
        local groups, order, size = {}, {}, 0
        local function flush()
            if #order == 0 then return end
            local parts = {}
            for _, c in ipairs(order) do parts[#parts + 1] = c .. "|" .. table.concat(groups[c], ";") end
            local m = "WFIX|" .. table.concat(parts, "#")
            ctx.hostSend(m); msgs = msgs + 1; bytes = bytes + #m
            groups, order, size = {}, {}, 0
        end
        for _, f in ipairs(pending) do
            local add = #f.s + 1 + (groups[f.c] and 0 or #f.c + 2)
            if size + add > 7000 then flush() end
            if not groups[f.c] then groups[f.c] = {}; order[#order + 1] = f.c end
            table.insert(groups[f.c], f.s); size = size + add
            f.sent = true
        end
        flush()
        log("WORLDREP placement: %d message(s), %d bytes (%d fixes known)", msgs, bytes, fixCount)
    end

    local FIXCELL = 50
    local fixedOnClient = {}    -- client actor full name -> true
    local function fixKey(c, x, y, z) return string.format("%s|%d|%d|%d", c, math.floor(x / FIXCELL), math.floor(y / FIXCELL), math.floor(z / FIXCELL)) end
    ctx.hostMsgHandlers["WFIXRESET"] = function() fixes, fixedOnClient, fixCount = {}, {}, 0 end
    ctx.hostMsgHandlers["WFIX"] = function(rest)
        local n = 0
        for group in rest:gmatch("[^#]+") do
            local c, body = group:match("^([^|]+)|(.*)$")
            if c then
                for e in body:gmatch("[^;]+") do
                    local v = {}
                    for num in e:gmatch("[^,]+") do v[#v + 1] = tonumber(num) end
                    if #v == 7 or #v == 9 then
                        -- stored as px, py, pz, wx, wy, wz, pitch, yaw, roll
                        local r = { v[1], v[2], v[3], v[1] + v[4], v[2] + v[5], v[3] + v[6], v[8] or 0, v[7], v[9] or 0 }
                        local k = fixKey(c, r[1], r[2], r[3])
                        fixes[k] = fixes[k] or {}
                        table.insert(fixes[k], r)
                        n = n + 1
                    end
                end
            end
        end
        fixCount = fixCount + n
    end
    -- client: move replicated actors that sit where the host said the engine would put them
    local function clientPlacement()
        if fixCount == 0 then return 0 end
        local moved = 0
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            if valid(a) then
                local okR, role = pcall(function() return a.Role end)
                if okR and role == 1 then
                    local name = a:GetFullName()
                    local l = a:K2_GetActorLocation()
                    local put = fixedOnClient[name]
                    -- moved again since (the engine re-applies the attachment when it changes on the host)?
                    if put and math.abs(put[1] - l.X) + math.abs(put[2] - l.Y) + math.abs(put[3] - l.Z) > 3 then
                        put = nil
                    end
                    if not put then
                        local c = a:GetClass():GetFName():ToString()
                        local best, bestD, bestList, bestI = nil, 8, nil, nil
                        for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
                            local list = fixes[fixKey(c, l.X + dx * FIXCELL, l.Y + dy * FIXCELL, l.Z + dz * FIXCELL)]
                            if list then
                                for i, v in ipairs(list) do
                                    local d = math.abs(v[1] - l.X) + math.abs(v[2] - l.Y) + math.abs(v[3] - l.Z)
                                    -- <=: of two fixes for one spot the later one (the host's recheck) wins
                                    if d <= bestD then best, bestD, bestList, bestI = v, d, list, i end
                                end
                            end
                        end end end
                        if best then
                            local okM = pcall(function()
                                a:K2_SetActorLocationAndRotation({ X = best[4], Y = best[5], Z = best[6] },
                                    { Pitch = best[7], Yaw = best[8], Roll = best[9] }, false, {}, true)
                            end)
                            if okM then fixedOnClient[name] = { best[4], best[5], best[6] }; moved = moved + 1 end
                        end
                    end
                end
            end
        end
        return moved
    end

    function M.reset()
        seen, total, fixes, fixCount, sentKey, fixedOnClient = {}, 0, {}, 0, "", {}
        recheck, hostTicks, lastFix = {}, 0, {}
    end

    -- Client: some prefabs (roads, shrubs, fences under a PrefabSettingsActor) are built by the client game too, in
    -- the same places as the host's replicated ones, and nothing on the host tells them apart (exp96: 694 local
    -- runtime actors on the client, e.g. BP_Destruct_ChainFence_Large_01_C 16 host -> 32 client). The host's copy is
    -- the truth (it breaks, moves, opens there): the client's own copy with a replicated twin of the same class
    -- within CELL is removed. Only local runtime actors (role authority, not loaded with the level) are touched.
    local CELL = 60
    local function cellKey(c, l, dx, dy, dz)
        return string.format("%s|%d|%d|%d", c, math.floor(l.X / CELL) + dx, math.floor(l.Y / CELL) + dy,
                             math.floor(l.Z / CELL) + dz)
    end
    -- every 2 s: an actor coming into relevance stands at the wrong spot until this moves it
    function M.clientPlaceTick()
        if not ctx.enabled() then return end
        local okP, moved = pcall(clientPlacement)
        if not okP then log("WORLDREP placement error: %s", tostring(moved))
        elseif moved > 0 then log("WORLDREP client: moved %d attached actor(s) to the host's spot", moved) end
    end

    function M.clientTick()
        if not ctx.enabled() then return end
        local own = {}
        for _, cls in ipairs({ "ItemWorldManifestation", "Pawn" }) do
            for _, a in ipairs(FindAllOf(cls) or {}) do if valid(a) then own[a:GetFullName()] = true end end
        end
        local twins, locals = {}, {}
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            if valid(a) then
                local okR, role = pcall(function() return a.Role end)
                local okL, loaded = pcall(function() return a:HasAnyFlags(RF_WasLoaded) end)
                if okR and okL and not loaded then
                    local c = a:GetClass():GetFName():ToString()
                    local l = a:K2_GetActorLocation()
                    if role == 1 then
                        local k = cellKey(c, l, 0, 0, 0)
                        twins[k] = (twins[k] or 0) + 1
                    elseif role == 3 and not skipClass(c) and not own[a:GetFullName()] then
                        locals[#locals + 1] = { a = a, c = c, l = l }
                    end
                end
            end
        end
        local n, byClass = 0, {}
        for _, e in ipairs(locals) do
            local hit = nil
            for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
                local k = cellKey(e.c, e.l, dx, dy, dz)
                if not hit and (twins[k] or 0) > 0 then hit = k end
            end end end
            if hit then
                twins[hit] = twins[hit] - 1
                if pcall(function() e.a:K2_DestroyActor() end) then
                    n = n + 1; byClass[e.c] = (byClass[e.c] or 0) + 1
                end
            end
        end
        if n > 0 then
            local parts = {}
            for k, v in pairs(byClass) do parts[#parts + 1] = k .. "=" .. v end
            table.sort(parts)
            log("WORLDREP client: removed %d own copies of the host's actors: %s", n, table.concat(parts, " "))
        end
    end

    local worldAddr = nil
    function M.hostTick()
        if not ctx.enabled() then return end
        -- the re-host (servertravel <same map>?listen) builds a new world with the same name, and actors placed by
        -- name (BP_Hazard_Landmine_8) get their old names back: forget the old world by its address, not its name
        -- (exp94: 236 landmines skipped as already handled)
        local okW, addr = pcall(function() return ctx.UEHelpers.GetWorld():GetAddress() end)
        if okW and addr ~= worldAddr then worldAddr = addr; M.reset() end
        -- items (main.lua mirrors them), pawns and the player car (synced by the mod) stay as they are
        local own = {}
        for _, cls in ipairs({ "ItemWorldManifestation", "Pawn" }) do
            for _, a in ipairs(FindAllOf(cls) or {}) do if valid(a) then own[a:GetFullName()] = true end end
        end
        local n, byClass = 0, {}
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            if valid(a) then
                local key = a:GetFullName()
                if not seen[key] then
                    seen[key] = true
                    local okL, loaded = pcall(function() return a:HasAnyFlags(RF_WasLoaded) end)
                    local c = a:GetClass():GetFName():ToString()
                    -- the player car and what hangs on it (exp94: its BP_CarPart_Interactive_C doubled 53 -> 106
                    -- on the client, which has its own car); abandoned BP_Template_* cars are not cars to the game
                    -- and what hangs on a level actor: the client builds it itself from its own copy of the level,
                    -- in the same place (exp95: 230 StaticMeshActors under level actors, all on the host's spots)
                    local clientBuilds, p = false, a
                    for depth = 1, 8 do
                        if p == nil or not p:IsValid() then break end
                        if ctx.isCar(p) then clientBuilds = true; break end
                        if depth > 1 then
                            local okA, lv = pcall(function() return p:HasAnyFlags(RF_WasLoaded) end)
                            if okA and lv then clientBuilds = true; break end
                        end
                        local okP, pp = pcall(function() return p:GetAttachParentActor() end)
                        p = okP and pp or nil
                    end
                    -- a child actor (ChildActorComponent) is created again on the client by its replicated parent
                    -- (exp94: BP_Destruct_ChainFence_Large_01_C 16 on the host -> 32 on the client)
                    local child = false
                    pcall(function() local pa = a:GetParentActor(); child = pa ~= nil and pa:IsValid() end)
                    local already = false
                    pcall(function() already = a.bReplicates end)
                    if okL and not loaded and not own[key] and not clientBuilds and not child and not already
                        and not skipClass(c) then
                        local ok = pcall(function()
                            a:SetReplicates(true)
                            a:SetReplicateMovement(true)
                            a.NetCullDistanceSquared = CULL_SQ
                            a.NetUpdateFrequency = 2.0
                            a.MinNetUpdateFrequency = 0.5
                        end)
                        if ok then
                            n = n + 1; byClass[c] = (byClass[c] or 0) + 1
                            local okF, errF = pcall(hostPlacement, a, c)
                            if not okF and not placeErrLogged then
                                placeErrLogged = true; log("WORLDREP placement error: %s", tostring(errF))
                            end
                        end
                    end
                end
            end
        end
        if n > 0 then
            total = total + n
            local top = {}
            for k, v in pairs(byClass) do top[#top + 1] = { k, v } end
            table.sort(top, function(x, y) return x[2] > y[2] end)
            local parts = {}
            for i = 1, math.min(6, #top) do parts[#parts + 1] = top[i][1] .. "=" .. top[i][2] end
            log("WORLDREP %d new generated actor(s) replicated (%d total): %s", n, total, table.concat(parts, " "))
        end
        hostRecheck()
        hostSendFixes()
    end

    return M
end
