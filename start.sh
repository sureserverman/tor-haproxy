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
# Exactly 3 bridges are required: that's the minimum for Tor 0.4.8+ Conflux
# (≥3 distinct primary guards) on the onion-service traffic this image
# carries, and the maximum that doesn't widen first-query latency variance
# enough to push cold queries past typical client timeouts (8s+).
: "${BRIDGE1:?BRIDGE1 must be set (e.g. -e BRIDGE1='obfs4 IP:PORT FPR cert=... iat-mode=0')}"
: "${BRIDGE2:?BRIDGE2 must be set (e.g. -e BRIDGE2='obfs4 IP:PORT FPR cert=... iat-mode=0')}"
: "${BRIDGE3:?BRIDGE3 must be set (e.g. -e BRIDGE3='obfs4 IP:PORT FPR cert=... iat-mode=0')}"

# obfs4 line shape: 'obfs4 host:port 40-hex-fingerprint cert=<base64> iat-mode=[012]'
bridge_re='^obfs4 [^[:space:]]+ [0-9A-Fa-f]{40} cert=[^[:space:]]+ iat-mode=[012]$'
validate_bridges() {
    for b in "$BRIDGE1" "$BRIDGE2" "$BRIDGE3"; do
        if ! echo "$b" | grep -Eq "$bridge_re"; then
            echo "ERROR: bridge has invalid obfs4 syntax: $b" >&2
            return 1
        fi
    done
}
validate_bridges || exit 1

TOR_LOG=/tmp/tor.log
RESTART_FLAG=/tmp/tor-restart-flag
BRIDGES_REFRESH=/tmp/bridges-current.env

# Stage 8 (reliability plan): graceful in-container Tor restart.
#
# nice-dns-health on the host detects a sustained full-chain outage,
# (optionally) drops fresh bridges at /tmp/bridges-current.env via
# `podman cp` / `container cp`, then triggers a restart by touching
# /tmp/tor-restart-flag. The flag-watcher subshell below picks it up
# and pkills tor; the main loop sees tor exit, sees the flag is set,
# reloads bridges if a refresh file is present, and respawns tor.
# haproxy + probe-primary keep running across the restart.
#
# Why graceful: a full container restart loses haproxy state (its
# admin socket, Lua tasks, probe-primary streak counters), and the
# systemd / launchd restart cycle adds ~10-15s of container-create
# overhead on top of Tor's own bootstrap time. The in-container path
# skips all of that — when tor returns, haproxy's existing rise/fall
# loop notices and shifts client traffic back without service
# downtime from the client's perspective.

# Read live bridges into BRIDGE{1,2,3}. If /tmp/bridges-current.env
# exists (dropped by the host's recovery logic), source it so a
# respawn uses the freshly-fetched bridges. Otherwise the original
# env vars from `container run` remain in scope.
reload_bridges() {
    if [ -r "$BRIDGES_REFRESH" ]; then
        # shellcheck disable=SC1090  # path is intentional and runtime-only
        . "$BRIDGES_REFRESH" 2>/dev/null || true
        echo "tor-supervisor: reloaded bridges from $BRIDGES_REFRESH"
    fi
}

# Spawn (or respawn) tor with the current BRIDGE{1,2,3}. Caller must
# have killed any previous TOR_PID first. Returns 0 on launch, 1 if
# bridges are malformed (refusing to launch is safer than letting tor
# bootstrap on garbage).
launch_tor() {
    reload_bridges
    if ! validate_bridges; then
        echo "tor-supervisor: REFUSING to launch tor on invalid bridges" >&2
        return 1
    fi
    : > "$TOR_LOG"   # truncate so wait_for_tor_bootstrap below starts fresh
    tor Bridge "$BRIDGE1" Bridge "$BRIDGE2" Bridge "$BRIDGE3" \
        >"$TOR_LOG" 2>&1 &
    TOR_PID=$!
    echo "tor-supervisor: spawned tor pid=$TOR_PID"
}

# Wait for the most recent tor to reach Bootstrapped 100% (5 min cap).
# Non-fatal: caller decides what to do on early-exit / timeout.
wait_for_tor_bootstrap() {
    i=0
    while [ "$i" -lt 60 ]; do
        if grep -q "Bootstrapped 100%" "$TOR_LOG" 2>/dev/null; then
            echo "Tor bootstrapped successfully."
            return 0
        fi
        if ! kill -0 "$TOR_PID" 2>/dev/null; then
            echo "ERROR: tor exited before bootstrap." >&2
            cat "$TOR_LOG" >&2
            return 1
        fi
        sleep 5
        i=$((i + 1))
    done
    echo "WARNING: Tor did not bootstrap in 5 minutes."
    return 2
}

# Trap signals so a graceful shutdown reaches every child.
cleanup() {
    [ -n "${TOR_PID:-}" ] && kill -TERM "$TOR_PID" 2>/dev/null || true
    [ -n "${HAPROXY_PID:-}" ] && kill -TERM "$HAPROXY_PID" 2>/dev/null || true
    [ -n "${PROBE_PID:-}" ] && kill -TERM "$PROBE_PID" 2>/dev/null || true
    [ -n "${WATCHER_PID:-}" ] && kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup TERM INT

# Clear any stale restart marker so the watcher doesn't fire
# immediately on a fresh start.
rm -f "$RESTART_FLAG" "$BRIDGES_REFRESH"

echo "Waiting for Tor to bootstrap..."
launch_tor || exit 1
wait_for_tor_bootstrap || true   # WARNING is non-fatal; carry on to haproxy

# SOCKS4 routing through Tor is native — no torsocks needed.
haproxy -f /etc/haproxy/haproxy.cfg -W &
HAPROXY_PID=$!

# Latency-aware primary demotion (Stage 7 of the reliability plan).
/bin/probe-primary.sh &
PROBE_PID=$!

# Stage 8 flag-watcher: poll for /tmp/tor-restart-flag every 5s. When
# it appears, send SIGTERM to the tor process by name; the main loop
# below will see tor exit, see the flag is still present, and respawn
# tor (picking up fresh bridges from /tmp/bridges-current.env if any).
#
# Killing tor by name (pkill -x tor) rather than by PID means the
# watcher doesn't need to track TOR_PID across respawns; one less
# coupling between the subshell and the main loop.
(
    while true; do
        sleep 5
        if [ -f "$RESTART_FLAG" ]; then
            echo "tor-supervisor: restart flag observed, sending SIGTERM to tor"
            pkill -TERM -x tor 2>/dev/null || true
            # Don't remove the flag here — the main loop reads it as
            # "this exit was a planned restart" and only then clears.
            sleep 2
        fi
    done
) &
WATCHER_PID=$!

# Supervisory main loop: wait for any non-watcher child to exit. If
# the exit was tor and the restart flag is set, respawn tor and keep
# looping. Otherwise treat it as a fatal exit and tear the whole
# container down (haproxy or probe-primary dying = bug, not a
# planned event).
while true; do
    # Wait for ANY child. wait -n (no args) returns on whichever child
    # exits first. With the watcher running infinitely, the only
    # children that can exit are TOR_PID, HAPROXY_PID, PROBE_PID, or
    # the watcher subshell itself (in error cases).
    wait -n
    ec=$?

    # Identify which child died. kill -0 returns 0 iff the process is
    # alive. We use the most-recent TOR_PID captured by launch_tor.
    if ! kill -0 "${TOR_PID:-0}" 2>/dev/null; then
        if [ -f "$RESTART_FLAG" ]; then
            echo "tor-supervisor: tor exited as part of planned restart, respawning"
            rm -f "$RESTART_FLAG"
            if launch_tor; then
                wait_for_tor_bootstrap || true
                # If bridges file was a one-shot drop, remove it so the
                # next reload reverts to original env vars unless the
                # host drops another file.
                rm -f "$BRIDGES_REFRESH"
                continue
            else
                echo "tor-supervisor: respawn refused (bad bridges); exiting" >&2
                cleanup
                exit 1
            fi
        else
            echo "tor-supervisor: tor died unexpectedly (rc=$ec)" >&2
            cleanup
            exit "$ec"
        fi
    fi

    # Not tor — must be haproxy, probe-primary, or watcher. Any of
    # those dying is fatal (we want the container to restart, picking
    # up whatever fix the operator deploys).
    if ! kill -0 "${HAPROXY_PID:-0}" 2>/dev/null; then
        echo "tor-supervisor: haproxy exited (rc=$ec); tearing down" >&2
    elif ! kill -0 "${PROBE_PID:-0}" 2>/dev/null; then
        echo "tor-supervisor: probe-primary exited (rc=$ec); tearing down" >&2
    elif ! kill -0 "${WATCHER_PID:-0}" 2>/dev/null; then
        echo "tor-supervisor: restart watcher exited (rc=$ec); tearing down" >&2
    else
        echo "tor-supervisor: unknown child exited (rc=$ec); tearing down" >&2
    fi
    cleanup
    exit "$ec"
done
