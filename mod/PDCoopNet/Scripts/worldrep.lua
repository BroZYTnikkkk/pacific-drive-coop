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
    -- every replicated actor is looked at when it is replicated and then again in a rolling pass (RECHECK per host
    -- tick, all of them in about a minute): a prefab can still move or attach its content later (exp104: a door's
    -- fix from its spawn moment never matched; exp110: 6 doors attached after a single recheck at 10 s)
    local RECHECK = 400
    local tracked, cursor = {}, 1
    local lastFix = {}          -- actor full name -> entry text sent for it
    local lastEntry = {}        -- actor full name -> { root x, y, z, offset x, y, z, yaw, pitch, roll } of its last fix
    -- no fix needed (any more): a fix sent before is taken back with an entry "offset -> the same offset" for the
    -- same root and offset, the client keeps the latest entry per key (exp117: a door got a fix while its parent
    -- was not replicated yet; once it was, the parent's fix moved it too, twice the offset off)
    local function retract(key, c, a)
        local e = lastEntry[key]
        if not e then return end
        lastEntry[key] = nil
        local s = string.format("%d,%d,%d,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f", e[1], e[2], e[3], e[4], e[5], e[6],
            e[4], e[5], e[6], e[7])
        if math.abs(e[8]) > 0.05 or math.abs(e[9]) > 0.05 then s = s .. string.format(",%.1f,%.1f", e[8], e[9]) end
        lastFix[key] = ""
        local w = a:K2_GetActorLocation()
        fixes[#fixes + 1] = { c = c, s = s, x = w.X, y = w.Y, z = w.Z, sent = false }
        fixCount = fixCount + 1
        if c:sub(1, 7) == "BP_Door" then log("WORLDREP placement fix %s %s taken back", c, a:GetFName():ToString()) end
    end
    local function hostPlacement(a, c)
        local key = a:GetFullName()
        if not lastFix[key] then tracked[#tracked + 1] = { a = a, c = c } end
        lastFix[key] = lastFix[key] or ""
        local r, depth = rootOf(a)
        if depth == 0 then retract(key, c, a); return end
        -- the chain root always relevant: an attached actor that comes into relevance before its root cannot be
        -- attached and stays at 0,0,0 on the client (exp118). Roots are few (prefab roots, abandoned cars)
        pcall(function() if r.bReplicates and not r.bAlwaysRelevant then r.bAlwaysRelevant = true end end)
        local rc = a.RootComponent
        local parent = rc:GetAttachParent()
        if parent and parent:IsValid() and parent:GetAddress() == r.RootComponent:GetAddress() then
            retract(key, c, a); return
        end
        -- an immediate parent the client can resolve: a component of a replicated actor that is part of its class
        -- (CreationMethod Native 0 / construction script 1; the folders' roots are 3, added at runtime). Then the
        -- client attaches to it with the right offset, and the parent's own fix moves both (exp111: the sliding doors
        -- hang on BP_PrefabSelfDeletor_* roots, which resolve; a fix computed against the chain root never matched)
        local okA, resolvable = pcall(function()
            local o = parent:GetOwner()
            local cm = parent.CreationMethod
            return o and o:IsValid() and o.bReplicates and (cm == 0 or cm == 1)
        end)
        if okA and resolvable then retract(key, c, a); return end
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
        -- The fix is relative to the chain root, not a world spot: the client's root can still move after the fix
        -- (a prefab root placed after spawning), and the content must go with it (exp116: a door fixed to its
        -- world spot moved on with its root, twice the offset off).
        local w, wr = a:K2_GetActorLocation(), a:K2_GetActorRotation()
        local wrong, wrongR = rc.RelativeLocation, rc.RelativeRotation
        local right = K:InverseTransformLocation(rootXf, w)
        local rightR = K:InverseTransformRotation(rootXf, wr)
        local dr = K:NormalizedDeltaRotator(wrongR, rightR)
        local dLoc = math.abs(wrong.X - right.X) + math.abs(wrong.Y - right.Y) + math.abs(wrong.Z - right.Z)
        local dRot = math.abs(dr.Yaw) + math.abs(dr.Pitch) + math.abs(dr.Roll)
        if dLoc < 3 and dRot < 1 then retract(key, c, a); return end
        -- root spot (as the client gets it), the offset the client gets, the right offset, yaw [, pitch, roll]
        local s = string.format("%d,%d,%d,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f", rnd(rl.X), rnd(rl.Y), rnd(rl.Z),
            wrong.X, wrong.Y, wrong.Z, right.X, right.Y, right.Z, rightR.Yaw)
        if math.abs(rightR.Pitch) > 0.05 or math.abs(rightR.Roll) > 0.05 then
            s = s .. string.format(",%.1f,%.1f", rightR.Pitch, rightR.Roll)
        end
        if s == lastFix[key] then return end
        if c:sub(1, 7) == "BP_Door" then
            log("WORLDREP placement fix %s %s: offset %.0f,%.0f,%.0f -> %.0f,%.0f,%.0f under %s%s", c, a:GetFName():ToString(),
                wrong.X, wrong.Y, wrong.Z, right.X, right.Y, right.Z, r:GetFName():ToString(),
                lastFix[key] ~= "" and " (changed)" or "")
        end
        lastFix[key] = s
        lastEntry[key] = { rnd(rl.X), rnd(rl.Y), rnd(rl.Z), wrong.X, wrong.Y, wrong.Z, wrongR.Yaw, wrongR.Pitch, wrongR.Roll }
        fixes[#fixes + 1] = { c = c, s = s, x = w.X, y = w.Y, z = w.Z, sent = false }
        fixCount = fixCount + 1
    end
    local function hostRecheck()
        local n, done = 0, 0
        while done < RECHECK and #tracked > 0 do
            if cursor > #tracked then cursor = 1 end
            local e = tracked[cursor]
            if valid(e.a) then
                local before = fixCount
                pcall(hostPlacement, e.a, e.c)
                if fixCount > before then n = n + 1 end
                cursor = cursor + 1
            else
                table.remove(tracked, cursor)
            end
            done = done + 1
        end
        if n > 0 then log("WORLDREP placement: %d actor(s) moved since they were replicated, fixes updated", n) end
    end
    -- the remote players that listen on the channel (a new one gets every fix) and where they are
    local function remotePlayers()
        local at = {}
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() then
                pcall(function() if valid(pc.Pawn) then at[#at + 1] = pc.Pawn:K2_GetActorLocation() end end)
            end
        end
        return ctx.readyKey(), at
    end
    -- host: everything to a new set of clients, then what is new; nearest to player 2 first; several classes per
    -- message up to one channel message (no parts), so each message is usable on its own as it arrives; WFIX is
    -- bulk traffic in the channel, the players' state goes first
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
            if size + add > ctx.CHAN_MAX - 200 then flush() end
            if not groups[f.c] then groups[f.c] = {}; order[#order + 1] = f.c end
            table.insert(groups[f.c], f.s); size = size + add
            f.sent = true
        end
        flush()
        log("WORLDREP placement: %d message(s), %d bytes (%d fixes known)", msgs, bytes, fixCount)
    end

    -- client: entries by class and the offset the client got (20 uu cells), checked against the root's spot
    local FIXCELL = 20
    local fixedOnClient = {}    -- client actor full name -> { right offset x, y, z, again = n }
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
                    if #v == 10 or #v == 12 then
                        -- root x, y, z; offset got x, y, z; right offset x, y, z; pitch, yaw, roll
                        local r = { v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[11] or 0, v[10], v[12] or 0 }
                        local k = fixKey(c, r[4], r[5], r[6])
                        fixes[k] = fixes[k] or {}
                        table.insert(fixes[k], r)
                        n = n + 1
                    end
                end
            end
        end
        fixCount = fixCount + n
    end
    -- client: give replicated attached actors the host's offset to their chain root, where the root and the offset
    -- the engine gave them match what the host predicted
    local function clientPlacement()
        if fixCount == 0 then return 0 end
        local moved = 0
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            if valid(a) then
                local okR, role = pcall(function() return a.Role end)
                local okP, parent = pcall(function() return a:GetAttachParentActor() end)
                if okR and role == 1 and okP and parent and parent:IsValid() then
                    local name = a:GetFullName()
                    local rc = a.RootComponent
                    local l = rc.RelativeLocation
                    local rec = fixedOnClient[name]
                    local function near(v, i) return math.abs(v[i] - l.X) + math.abs(v[i + 1] - l.Y) + math.abs(v[i + 2] - l.Z) <= 3 end
                    -- the offset the engine gave it: remembered; if it is neither that nor the one put here, the
                    -- engine gave a new one (the host changed the attachment)
                    if not rec then rec = { orig = { l.X, l.Y, l.Z }, again = 0 }; fixedOnClient[name] = rec
                    elseif not near(rec.orig, 1) and not (rec.applied and near(rec.applied, 7)) then
                        rec.orig = { l.X, l.Y, l.Z }; rec.applied = nil; rec.again = rec.again + 1
                    end
                    local o = rec.orig
                    if not rec.keys or rec.keysFor ~= o then
                        -- the 27 cells around the offset, computed once per offset (4000 actors every 2 s)
                        local c = a:GetClass():GetFName():ToString()
                        rec.keys, rec.keysFor = {}, o
                        for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
                            rec.keys[#rec.keys + 1] = fixKey(c, o[1] + dx * FIXCELL, o[2] + dy * FIXCELL, o[3] + dz * FIXCELL)
                        end end end
                    end
                    local root = rootOf(a)
                    local rl = root:K2_GetActorLocation()
                    local best, bestD = nil, 6
                    for _, k in ipairs(rec.keys) do
                        local list = fixes[k]
                        if list then
                            for _, v in ipairs(list) do
                                local dRoot = math.abs(v[1] - rl.X) + math.abs(v[2] - rl.Y) + math.abs(v[3] - rl.Z)
                                local d = math.abs(v[4] - o[1]) + math.abs(v[5] - o[2]) + math.abs(v[6] - o[3])
                                -- <=: of two entries for one offset the later one (a recheck, a retraction) wins
                                if dRoot < 10 and d <= bestD then best, bestD = v, d end
                            end
                        end
                    end
                    -- apply when the latest entry is not what is in place (new, changed, taken back, or the engine
                    -- reset the offset); an actor whose offset keeps changing (physics here) is left after 3 times
                    if best and rec.again < 3 and (best ~= rec.applied or not near(best, 7)) then
                        local okM = pcall(function()
                            rc:K2_SetRelativeLocationAndRotation({ X = best[7], Y = best[8], Z = best[9] },
                                { Pitch = best[10], Yaw = best[11], Roll = best[12] }, false, {}, true)
                        end)
                        if okM then
                            if rec.applied == best and not rec.told then
                                rec.told = true
                                log("WORLDREP client: %s lost its fixed offset, set again", name:match("[^.:]+$") or name)
                            end
                            if rec.applied == best then rec.again = rec.again + 1 end
                            rec.applied = best
                            moved = moved + 1
                        end
                    end
                end
            end
        end
        return moved
    end

    function M.reset()
        seen, total, fixes, fixCount, sentKey, fixedOnClient = {}, 0, {}, 0, "", {}
        tracked, cursor, lastFix, lastEntry = {}, 1, {}, {}
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
    -- every 2 s when actors arrived or fixes came in, else every 10 s (the engine can reset an attachment without
    -- a new actor): an actor coming into relevance stands at the wrong spot until this moves it
    local placeAt = { spawns = -1, fixes = -1, calls = 0 }
    function M.clientPlaceTick()
        if not ctx.enabled() then return end
        local sc = ctx.Events.spawnCount()
        placeAt.calls = placeAt.calls + 1
        if sc == placeAt.spawns and fixCount == placeAt.fixes and placeAt.calls % 5 ~= 0 then return end
        placeAt.spawns, placeAt.fixes = sc, fixCount
        local okP, moved = pcall(clientPlacement)
        if not okP then log("WORLDREP placement error: %s", tostring(moved))
        elseif moved > 0 then log("WORLDREP client: moved %d attached actor(s) to the host's spot", moved) end
    end

    -- every 5 s, when actors began play since the last search (a replicated twin arrived, or the client's own
    -- generation built something)
    local dedupeAt = -1
    function M.clientTick()
        if not ctx.enabled() then return end
        local sc = ctx.Events.spawnCount()
        if sc == dedupeAt then return end
        dedupeAt = sc
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

    local worldAddr, scanAt = nil, -1
    function M.hostTick()
        if not ctx.enabled() then return end
        -- the re-host (servertravel <same map>?listen) builds a new world with the same name, and actors placed by
        -- name (BP_Hazard_Landmine_8) get their old names back: forget the old world by its address, not its name
        -- (exp94: 236 landmines skipped as already handled)
        local okW, addr = pcall(function() return ctx.UEHelpers.GetWorld():GetAddress() end)
        if okW and addr ~= worldAddr then worldAddr = addr; M.reset(); scanAt = -1 end
        -- the search of the whole world only when actors began play since the last one (zone generation spawns over
        -- time, storms spawn more); the placement recheck and the fixes go on every tick
        local sc = ctx.Events.spawnCount()
        if sc == scanAt then hostRecheck(); hostSendFixes(); return end
        scanAt = sc
        -- items (items.lua gives them markers), pawns and the player car (synced by the mod) stay as they are; but
        -- landmines are item actors without item data (no Instance, also on the host): they cannot get a marker,
        -- and a replicated one does not crash player 2 (a proxy of an item with data did, exp143). Replicated.
        local own = {}
        for _, cls in ipairs({ "ItemWorldManifestation", "Pawn" }) do
            for _, a in ipairs(FindAllOf(cls) or {}) do
                if valid(a) then
                    local hazard = false
                    if cls == "ItemWorldManifestation" then
                        pcall(function() hazard = a:GetClass():GetFName():ToString():sub(1, 10) == "BP_Hazard_" and not valid(a.Instance) end)
                    end
                    if not hazard then own[a:GetFullName()] = true end
                end
            end
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
