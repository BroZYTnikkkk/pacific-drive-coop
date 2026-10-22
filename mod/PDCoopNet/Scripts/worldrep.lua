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

    function M.reset() seen = {}; total = 0 end

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
        if okW and addr ~= worldAddr then worldAddr = addr; seen = {}; total = 0 end
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
                        if ok then n = n + 1; byClass[c] = (byClass[c] or 0) + 1 end
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
    end

    return M
end
