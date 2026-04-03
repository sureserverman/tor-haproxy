#!/bin/sh

BRIDGE1="${BRIDGE1:-obfs4 109.110.170.208:29323 B93BAE4F17CEACD9E491920C5D283C0D4C3D6D3D cert=p+n8+6mTYmEMpFy+rDuQSyNy4X5pxarA9MzDknqk+WAukqpVa+uE0JJymTK8b8wSyK5pJw iat-mode=0}"
BRIDGE2="${BRIDGE2:-obfs4 84.22.109.77:8088 CEF423251E83353BD875CB5327B458F4C8751170 cert=HMCEwtFxM3OK68PTtZ0NXeYlabBRrRGF1IddIEfXk0J7Dmuq7Y2zgohCwjluwFE0AuH8Zg iat-mode=0}"

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
