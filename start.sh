#!/bin/sh
# This script targets Alpine's busybox ash, not strict POSIX sh.
# shellcheck disable=SC3045  # wait -n is supported by busybox ash
set -eu

# Bridges MUST be supplied by the operator at runtime — no defaults are
# baked into the image. The previous defaults leaked real obfs4 fingerprints
# and certificates into every published image layer.
: "${BRIDGE1:?BRIDGE1 must be set (e.g. -e BRIDGE1='obfs4 IP:PORT FPR cert=... iat-mode=0')}"
: "${BRIDGE2:?BRIDGE2 must be set (e.g. -e BRIDGE2='obfs4 IP:PORT FPR cert=... iat-mode=0')}"

# obfs4 line shape: 'obfs4 host:port 40-hex-fingerprint cert=<base64> iat-mode=[012]'
bridge_re='^obfs4 [^[:space:]]+ [0-9A-Fa-f]{40} cert=[^[:space:]]+ iat-mode=[012]$'
echo "$BRIDGE1" | grep -Eq "$bridge_re" || { echo "ERROR: BRIDGE1 has invalid obfs4 syntax" >&2; exit 1; }
echo "$BRIDGE2" | grep -Eq "$bridge_re" || { echo "ERROR: BRIDGE2 has invalid obfs4 syntax" >&2; exit 1; }

# PORT must be a positive integer in the valid TCP range.
case "${PORT:-}" in
    ''|*[!0-9]*) echo "ERROR: PORT must be numeric (got '${PORT:-}')" >&2; exit 1 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "ERROR: PORT $PORT out of range 1-65535" >&2; exit 1
fi

TOR_LOG=/tmp/tor.log
HAPROXY_CFG=/tmp/haproxy.cfg

# Render the haproxy config from its template (the template lives in /etc and
# is read-only; the rendered copy in /tmp is per-container-run).
sed "s/LISTEN_PORT/${PORT}/" /etc/haproxy/haproxy.cfg.template > "$HAPROXY_CFG"

# Trap signals so a graceful shutdown reaches both processes.
cleanup() {
    [ -n "${TOR_PID:-}" ] && kill -TERM "$TOR_PID" 2>/dev/null || true
    [ -n "${HAPROXY_PID:-}" ] && kill -TERM "$HAPROXY_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup TERM INT

# Background tor so we can wait for bootstrap before launching haproxy.
tor Bridge "$BRIDGE1" Bridge "$BRIDGE2" >"$TOR_LOG" 2>&1 &
TOR_PID=$!

echo "Waiting for Tor to bootstrap..."
for i in $(seq 1 60); do
    if grep -q "Bootstrapped 100%" "$TOR_LOG" 2>/dev/null; then
        echo "Tor bootstrapped successfully."
        break
    fi
    if ! kill -0 "$TOR_PID" 2>/dev/null; then
        echo "ERROR: tor exited before bootstrap." >&2
        cat "$TOR_LOG" >&2
        exit 1
    fi
    if [ "$i" -eq 60 ]; then
        echo "WARNING: Tor did not bootstrap in 5 minutes, starting HAProxy anyway."
    fi
    sleep 5
done

# SOCKS4 routing through Tor is native — no torsocks needed.
haproxy -f "$HAPROXY_CFG" -W &
HAPROXY_PID=$!

# Wait on whichever child exits first; signal the other and propagate the code.
wait -n
ec=$?
cleanup
exit "$ec"
