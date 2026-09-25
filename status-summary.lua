-- nice-dns / tor-haproxy backend status summary
--
-- Emits one log line per 60s with the state of the legacy dns_resolvers
-- servers, its current sessions, and the current sessions of each
-- identity-bound route backend (nice-dns ARCH-04), so operators can grep
-- the container log for "backends " instead of socat'ing the admin socket.
-- Pure observability — does not interact with serving traffic.
--
-- Output shape (sent at level "info"; one line, fields in this order):
--   backends primary=UP backup=UP sessions=0 routes=cloudflare-onion/1,cloudflare-exit/0,quad9-exit/0
-- Server status is haproxy's own (UP, DOWN, NOLB, MAINT, DRAIN, no check,
-- with transition counters such as "DOWN 1/3"), spaces turned into "_" so
-- every field stays one word. routes=<route>/<current sessions>: the route
-- servers have no health check, so their sessions show which route
-- Unbound is using.
--
-- NICE_DNS_SUMMARY_SECS overrides the 60 s interval (1..3600; tests).
--
-- Loaded via `lua-load /etc/haproxy/status-summary.lua` in the global
-- section of haproxy.cfg. Requires haproxy compiled with USE_LUA=1
-- (alpine's haproxy package satisfies this).

local ROUTES = {
    {"cloudflare-onion", "route_cloudflare_onion"},
    {"cloudflare-exit", "route_cloudflare_exit"},
    {"quad9-exit", "route_quad9_exit"},
}

local function interval()
    local n = tonumber(os.getenv("NICE_DNS_SUMMARY_SECS") or "")
    if n and n >= 1 and n <= 3600 then return math.floor(n) end
    return 60
end

local function backend(name)
    if core.backends then return core.backends[name] end
    return core.proxies[name]
end

local function word(v)
    return (tostring(v or "?"):gsub("%s+", "_"))
end

core.register_task(function()
    local secs = interval()
    while true do
        core.sleep(secs)
        local proxy = backend("dns_resolvers")
        if not proxy then
            core.Info("backends dns_resolvers proxy not found")
        else
            local parts = {}
            -- Servers in a stable order: primary first, then backup.
            for _, name in ipairs({"primary", "backup"}) do
                local srv = proxy.servers[name]
                if srv then
                    table.insert(parts, name .. "=" .. word(srv:get_stats()["status"]))
                end
            end
            table.insert(parts, "sessions=" .. word(proxy:get_stats()["scur"]))
            local routes = {}
            for _, r in ipairs(ROUTES) do
                local be = backend(r[2])
                table.insert(routes, r[1] .. "/" .. (be and word(be:get_stats()["scur"]) or "missing"))
            end
            table.insert(parts, "routes=" .. table.concat(routes, ","))
            core.Info("backends " .. table.concat(parts, " "))
        end
    end
end)
