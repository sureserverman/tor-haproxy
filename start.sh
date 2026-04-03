#!/bin/sh

BRIDGE1="${BRIDGE1:-obfs4 REDACTED-IP-1 REDACTED-FPR-1 cert=REDACTED-CERT-1 iat-mode=0}"
BRIDGE2="${BRIDGE2:-obfs4 REDACTED-IP-2 REDACTED-FPR-2 cert=REDACTED-CERT-2 iat-mode=0}"

TOR_LOG=/var/log/tor.log

tor Bridge "$BRIDGE1" Bridge "$BRIDGE2" 2>&1 | tee "$TOR_LOG" &

sed -i "s/LISTEN_PORT/${PORT}/" /etc/haproxy/haproxy.cfg

# Wait for Tor to bootstrap (up to 5 minutes)
echo "Waiting for Tor to bootstrap..."
for i in $(seq 1 60); do
    if grep -q "Bootstrapped 100%" "$TOR_LOG" 2>/dev/null; then
        echo "Tor bootstrapped successfully."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "WARNING: Tor did not bootstrap in time, starting HAProxy anyway."
    fi
    sleep 5
done

# Start haproxy — SOCKS4 routing through Tor is native, no torsocks needed
exec haproxy -f /etc/haproxy/haproxy.cfg -W
