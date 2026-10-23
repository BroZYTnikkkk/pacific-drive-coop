-- PDCoopNet events: game events the sync modules react to, instead of comparing their whole state on a timer.
-- Loaded by main.lua: require("events")(ctx).
--
-- Containers: UItemContainer::HandleSlotItemAdded / HandleSlotItemRemoved (PenDriverInventory) are bound to the
-- OnItemAdded / OnItemRemoved delegates of every slot, so hooks on them see every item that enters or leaves any
-- container on this machine (trunk, pockets, hand, lootables), whoever moved it: the player, the game, our sync.
-- A module asks takeDirty(container) and does its work only when that container changed.
--
-- hookFunction(path, callback): RegisterHook that survives map changes. A Blueprint class is collected and loaded
-- again after a map change; its old hook is then dead or (same address) fires twice (exp124/125). The hooked
-- function object is kept: once it is no longer valid, the old hook is unregistered and the new function hooked.
return function(ctx)
    local log, valid = ctx.log, ctx.valid
    local M = {}

    local hooks = {}         -- path -> { fn = function object, ids = { pre, post } }
    function M.hookFunction(path, callback)
        local h = hooks[path]
        if h and valid(h.fn) then return true end
        local fn = StaticFindObject(path)
        if not valid(fn) then return false end
        if h and h.ids then pcall(UnregisterHook, path, h.ids[1], h.ids[2]) end
        local ok, pre, post = pcall(RegisterHook, path, callback)
        if not ok then
            hooks[path] = nil
            log("EVENTS hook %s failed: %s", path, tostring(pre))
            return false
        end
        hooks[path] = { fn = fn, ids = { pre, post } }
        log("EVENTS hooked %s%s", path:match("[^.]+$"), h and " again (class loaded again)" or "")
        return true
    end
    local dirty = {}         -- container full name -> true
    local hooked, tries = false, 0

    function M.register()
        if hooked or tries >= 10 then return hooked end
        tries = tries + 1
        local base = "/Script/PenDriverInventory.ItemContainer:"
        local okAll = true
        for _, fn in ipairs({ "HandleSlotItemAdded", "HandleSlotItemRemoved" }) do
            local ok, err = pcall(RegisterHook, base .. fn, function(self)
                local okN, name = pcall(function() return self:get():GetFullName() end)
                if okN and name then dirty[name] = true end
            end)
            if not ok then okAll = false; log("EVENTS hook %s failed: %s", fn, tostring(err)) end
        end
        hooked = okAll
        if hooked then log("EVENTS hooked container item added / removed") end
        return hooked
    end

    -- true once per change of this container since the previous call; always true without the hooks (then the
    -- modules compare on their timer as before)
    function M.takeDirty(cont)
        if not hooked then return true end
        local ok, name = pcall(function() return cont:GetFullName() end)
        if not ok or not name then return false end
        if dirty[name] then dirty[name] = nil; return true end
        return false
    end

    function M.hooked() return hooked end
    return M
end
