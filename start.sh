#!/bin/sh

BRIDGE1="${BRIDGE1:-obfs4 84.22.109.77:8088 CEF423251E83353BD875CB5327B458F4C8751170 cert=HMCEwtFxM3OK68PTtZ0NXeYlabBRrRGF1IddIEfXk0J7Dmuq7Y2zgohCwjluwFE0AuH8Zg iat-mode=0}"
BRIDGE2="${BRIDGE2:-obfs4 107.4.186.44:8214 1B6CB332A1954FDF740DE75E8AFAEB41469D5821 cert=voxt3pqV5YWgLcqoHt+HDBieiUVzgxx3MOVHHa3RUPqlmsMGzSMu0Mv3AcY3XkQK9UirFw iat-mode=0}"

tor Bridge "$BRIDGE1" Bridge "$BRIDGE2" &

# Generate haproxy configuration
cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log stdout format raw local0 info

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 10s
    timeout client 60s
    timeout server 60s
    timeout check 10s
    retries 3

frontend dns_dot
    bind *:${PORT}
    default_backend dns_resolvers

backend dns_resolvers
    default-server inter 30s fall 3 rise 2
    server primary 10.192.0.1:853 socks4 127.0.0.1:9050 check
    server backup 1.1.1.1:853 socks4 127.0.0.1:9050 check backup
    server fallback 9.9.9.9:853 socks4 127.0.0.1:9050 check backup
EOF

# Wait for Tor to bootstrap
sleep 10

# Start haproxy — SOCKS4 routing through Tor is native, no torsocks needed
exec haproxy -f /etc/haproxy/haproxy.cfg -W
