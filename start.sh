#!/bin/sh
# This script targets Alpine's busybox ash, not strict POSIX sh.
# shellcheck disable=SC3045  # wait -n is supported by busybox ash
set -eu

# Files we create (tor.log, rendered haproxy config) are owner-only —
# tor circuit info and bridge parameters are visible in startup logs.
umask 077

# Bridges MUST be supplied by the operator at runtime — no defaults are
# baked into the image. The previous defaults leaked real obfs4 fingerprints
# and certificates into every published image layer.
#
# BRIDGE1 + BRIDGE2 are required. BRIDGE3..BRIDGE16 are optional extras:
#   - With ≥3 bridges Tor 0.4.8+ can form Conflux paths for onion-service
#     traffic (≥3 distinct primary guards required), roughly halving
#     cold-query latency to the Cloudflare DoT .onion.
#   - Bridges beyond NumPrimaryGuards (3) sit in Tor's guard sample set as
#     warm fallbacks; if a primary obfs4 endpoint dies, Tor rotates a
#     reserve in within seconds without re-bootstrapping the whole stack.
# With only 2 bridges the torrc-baked ConfluxEnabled 0 / NumPrimaryGuards 2
# stays in effect (legacy mode — slower but functional).
: "${BRIDGE1:?BRIDGE1 must be set (e.g. -e BRIDGE1='obfs4 IP:PORT FPR cert=... iat-mode=0')}"
: "${BRIDGE2:?BRIDGE2 must be set (e.g. -e BRIDGE2='obfs4 IP:PORT FPR cert=... iat-mode=0')}"

# obfs4 line shape: 'obfs4 host:port 40-hex-fingerprint cert=<base64> iat-mode=[012]'
bridge_re='^obfs4 [^[:space:]]+ [0-9A-Fa-f]{40} cert=[^[:space:]]+ iat-mode=[012]$'

# Discover BRIDGE1..BRIDGE16 (stop at the first unset slot) and validate each.
# bridge_count is used downstream to decide between Conflux mode (≥3) and
# legacy 2-bridge mode.
bridge_count=0
i=1
while [ "$i" -le 16 ]; do
    eval "_v=\${BRIDGE${i}:-}"
    [ -z "$_v" ] && break
    echo "$_v" | grep -Eq "$bridge_re" \
        || { echo "ERROR: BRIDGE$i has invalid obfs4 syntax" >&2; exit 1; }
    bridge_count=$((bridge_count + 1))
    i=$((i + 1))
done

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

# Build tor argv: each BRIDGE_i becomes a "Bridge $val" pair. With ≥3 bridges
# we override the torrc-baked safe defaults (ConfluxEnabled 0 /
# NumPrimaryGuards 2 — necessary for 2-bridge configs to function at all) so
# Tor uses 3 primary guards, re-engages Conflux, and treats bridges 4+ as
# warm reserves in its guard sample set.
set --
i=1
while [ "$i" -le "$bridge_count" ]; do
    eval "_v=\${BRIDGE${i}}"
    set -- "$@" Bridge "$_v"
    i=$((i + 1))
done
if [ "$bridge_count" -ge 3 ]; then
    set -- "$@" NumPrimaryGuards 3 ConfluxEnabled 1
fi

# Background tor so we can wait for bootstrap before launching haproxy.
tor "$@" >"$TOR_LOG" 2>&1 &
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
