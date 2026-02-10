#!/bin/sh

BRIDGE1="${BRIDGE1:-obfs4 REDACTED-IP-2 REDACTED-FPR-2 cert=REDACTED-CERT-2 iat-mode=0}"
BRIDGE2="${BRIDGE2:-obfs4 107.4.186.44:8214 1B6CB332A1954FDF740DE75E8AFAEB41469D5821 cert=voxt3pqV5YWgLcqoHt+HDBieiUVzgxx3MOVHHa3RUPqlmsMGzSMu0Mv3AcY3XkQK9UirFw iat-mode=0}"

tor Bridge "$BRIDGE1" Bridge "$BRIDGE2" &

sed -i "s/LISTEN_PORT/${PORT}/" /etc/haproxy/haproxy.cfg

# Wait for Tor to bootstrap
sleep 10

# Start haproxy — SOCKS4 routing through Tor is native, no torsocks needed
exec haproxy -f /etc/haproxy/haproxy.cfg -W
