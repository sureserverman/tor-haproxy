-- nice-dns / tor-haproxy backend status summary
--
-- Emits one log line per 60s with the UP/DOWN state of each backend in
-- the dns_resolvers backend, so operators can grep journalctl for
-- "backends=" instead of socat'ing the admin socket. Pure observability
-- — does not interact with serving traffic.
--
-- Output shape (sent at level "info" → journal label haproxy[...]):
--   backends primary=UP backup=UP fallback=UP
-- Status field uses haproxy's internal STATE_UP / STATE_DOWN values
-- (UP / DOWN / NOLB / MAINT / DRAIN / no check).
--
-- Loaded via `lua-load /etc/haproxy/status-summary.lua` in the global
-- section of haproxy.cfg. Requires haproxy compiled with USE_LUA=1
-- (alpine's haproxy package satisfies this).

core.register_task(function()
    while true do
        core.sleep(60)
        local proxy = core.proxies["dns_resolvers"]
        if not proxy then
            core.Info("backends dns_resolvers proxy not found")
        else
            local parts = {}
            -- Iterate servers in a stable order: primary first, then backup,
            -- then fallback. The proxy.servers map is keyed by name; we
            -- emit in declaration order if pairs() doesn't preserve it.
            for _, name in ipairs({"primary", "backup", "fallback"}) do
                local srv = proxy.servers[name]
                if srv then
                    local st = srv:get_stats()
                    table.insert(parts, name .. "=" .. (st["status"] or "?"))
                end
            end
            core.Info("backends " .. table.concat(parts, " "))
        end
    end
end)
