#!/bin/sh
# This script targets Alpine's busybox ash, not strict POSIX sh.
set -eu

# Files we create (tor.log, rendered haproxy config) are owner-only —
# tor circuit info and bridge parameters are visible in startup logs.
umask 077

# Bridges MUST be supplied by the operator at runtime — no defaults are
# baked into the image. The previous defaults leaked real obfs4 fingerprints
# and certificates into every published image layer.
#
# Three working bridges are ideal: that's the minimum for Tor 0.4.8+ Conflux
# (≥3 distinct primary guards) on the onion-service traffic this image carries.
# The operator may pass a *pool* of up to 16 candidates (BRIDGE1..BRIDGE16);
# when the in-image evaluator (/bin/bridge-eval) is present it tests the pool
# for real obfs4 usability and keeps the fastest-handshaking ones. At least one
# usable bridge is required; fewer than 3 still runs but disables Conflux.

# obfs4 line shape: 'obfs4 host:port 40-hex-fingerprint cert=<base64> iat-mode=[012]'
bridge_re='^obfs4 [^[:space:]]+ [0-9A-Fa-f]{40} cert=[^[:space:]]+ iat-mode=[012]$'

MAX_BRIDGE_SLOTS=16
SELECTED_ENV=/tmp/bridges-selected.env       # canonical chosen-bridge set (BRIDGE1..k)
BRIDGE_EVAL="${BRIDGE_EVAL:-off}"            # off (default): consume the host-selected bridges.env as-is.
                                             # Selection now runs HOST-SIDE (bridge-eval `manage` on a timer);
                                             # in-container eval (auto/moat/force) blocks haproxy startup ~150s
                                             # and can trip HealthStartPeriod into a restart loop. Opt in only
                                             # for debugging. Modes: off | auto | moat | force.
BRIDGE_COUNT="${BRIDGE_COUNT:-3}"
NBRIDGES=0

# collect_pool: emit every set BRIDGEn (n=1..MAX) as a bare obfs4 line.
collect_pool() {
    _n=1
    while [ "$_n" -le "$MAX_BRIDGE_SLOTS" ]; do
        eval "_v=\${BRIDGE${_n}:-}"
        [ -n "${_v:-}" ] && printf '%s\n' "$_v"
        _n=$((_n + 1))
    done
}

# select_bridges: write the chosen BRIDGE1..k to $SELECTED_ENV. Uses bridge-eval
# to test real usability when enabled (default: only when a >count pool, or an
# empty pool, is given — so exact-N deployments keep their existing fast path
# and pay no extra bootstrap). Falls back to a straight passthrough of the pool
# on any evaluator failure, so behaviour is never worse than before.
select_bridges() {
    _pool=/tmp/bridge-candidates.txt
    collect_pool > "$_pool"
    _pooln=$(grep -c . "$_pool" 2>/dev/null || true); _pooln=${_pooln:-0}

    _do_eval=0
    case "$BRIDGE_EVAL" in
        off)        _do_eval=0 ;;
        moat|force) _do_eval=1 ;;
        auto)       [ "$_pooln" -gt "$BRIDGE_COUNT" ] && _do_eval=1
                    [ "$_pooln" -eq 0 ] && _do_eval=1 ;;
    esac

    if [ "$_do_eval" = 1 ] && [ -x /bin/bridge-eval ]; then
        echo "tor-supervisor: selecting bridges via bridge-eval (pool=$_pooln, want=$BRIDGE_COUNT, mode=$BRIDGE_EVAL)..."
        if [ "$BRIDGE_EVAL" = moat ] || [ "$_pooln" -eq 0 ]; then
            /bin/bridge-eval -count "$BRIDGE_COUNT" -min 1 -out "$SELECTED_ENV" && return 0
        else
            /bin/bridge-eval -candidates "$_pool" -count "$BRIDGE_COUNT" -min 1 -out "$SELECTED_ENV" && return 0
        fi
        echo "tor-supervisor: bridge-eval failed; using operator-supplied bridges as-is" >&2
    fi

    # Passthrough: emit the pool unchanged as BRIDGE1..k.
    : > "$SELECTED_ENV"
    _i=1
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        printf 'BRIDGE%d=%s\n' "$_i" "$_line" >> "$SELECTED_ENV"
        _i=$((_i + 1))
    done < "$_pool"
}

# load_and_validate: reset BRIDGE slots, source $SELECTED_ENV, validate each,
# and set NBRIDGES. Returns non-zero if nothing usable.
load_and_validate() {
    _n=1
    while [ "$_n" -le "$MAX_BRIDGE_SLOTS" ]; do eval "unset BRIDGE${_n}"; _n=$((_n + 1)); done
    # Parse KEY=VALUE WITHOUT sourcing. The values are unquoted and contain
    # spaces (the --env-file / EnvironmentFile= format), so `. file` would try
    # to execute the value as a command (e.g. "1.2.3.4:80: not found", exit
    # 127). Assign each BRIDGEn literally from the line instead.
    if [ -r "$SELECTED_ENV" ]; then
        while IFS= read -r _ln; do
            case "$_ln" in
                BRIDGE[0-9]*=*)
                    _k=${_ln%%=*}
                    _v=${_ln#*=}
                    eval "$_k=\$_v"
                    ;;
            esac
        done < "$SELECTED_ENV"
    fi
    NBRIDGES=0
    _n=1
    while [ "$_n" -le "$MAX_BRIDGE_SLOTS" ]; do
        eval "_b=\${BRIDGE${_n}:-}"
        if [ -n "${_b:-}" ]; then
            if ! echo "$_b" | grep -Eq "$bridge_re"; then
                echo "ERROR: BRIDGE${_n} has invalid obfs4 syntax: $_b" >&2
                return 1
            fi
            NBRIDGES=$((NBRIDGES + 1))
        fi
        _n=$((_n + 1))
    done
    if [ "$NBRIDGES" -lt 1 ]; then
        echo "ERROR: no usable bridges (supply BRIDGE1.. at runtime, or enable bridge-eval)" >&2
        return 1
    fi
    [ "$NBRIDGES" -ge 3 ] || echo "tor-supervisor: WARNING: only $NBRIDGES bridge(s); Tor Conflux needs 3 — running without it." >&2
    return 0
}

# Initial selection. Validation happens in launch_tor (fail-fast there).
select_bridges

TOR_LOG=/tmp/tor.log
RESTART_FLAG=/tmp/tor-restart-flag
BRIDGES_REFRESH=/tmp/bridges-current.env
# Acknowledged restart contract (nice-dns ARCH-03 request_recovery):
#   host writes a request id to RESTART_REQUEST (atomically: tmp + mv in
#   the same directory);
#   the image restarts only tor and answers in RESTART_ACK, TSV lines
#     request_id <id>  status respawned|refused  generation <n>
#     tor_pid <pid>    utc <time>
#   GENERATION_FILE always holds the current generation and tor pid.
# An acknowledgement says tor was respawned, not that it bootstrapped:
# readiness is a separate, later observation. Touching RESTART_FLAG (the
# older interface) still works and is acknowledged as request_id "legacy".
# The request, acknowledgement and generation files live in CONTROL_DIR, a
# 0700 directory of the image's own user, so only that user can request a
# restart or forge an answer (/tmp is shared by every uid). Rejections go to
# RESTART_REJECTED, never over a pending acknowledgement.
CONTROL_DIR="${DATA_DIR:-/app/data}/control"
RESTART_REQUEST=$CONTROL_DIR/tor-restart-request
RESTART_PENDING=$CONTROL_DIR/tor-restart-pending
RESTART_ACK=$CONTROL_DIR/tor-restart-ack
RESTART_REJECTED=$CONTROL_DIR/tor-restart-rejected
GENERATION_FILE=$CONTROL_DIR/tor-generation
GENERATION=0
if [ -L "$CONTROL_DIR" ] || { [ -e "$CONTROL_DIR" ] && [ ! -d "$CONTROL_DIR" ]; }; then
    echo "ERROR: $CONTROL_DIR is not a real directory; refusing" >&2
    exit 1
fi
if ! { mkdir -p "$CONTROL_DIR" && chmod 700 "$CONTROL_DIR"; }; then
    echo "ERROR: cannot prepare $CONTROL_DIR" >&2
    exit 1
fi

# write_kv <file> <request_id> <status> <generation> <tor_pid>: atomic TSV.
write_kv() {
    {
        [ -n "$2" ] && printf 'request_id\t%s\nstatus\t%s\n' "$2" "$3"
        printf 'generation\t%s\ntor_pid\t%s\nutc\t%s\n' "$4" "$5" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$1.tmp" && mv "$1.tmp" "$1"
}

# gen_field <key>: a field of the current GENERATION_FILE (for the watcher,
# which runs in a subshell and cannot see GENERATION or TOR_PID).
gen_field() {
    awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$GENERATION_FILE" 2>/dev/null
}

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

# If /tmp/bridges-current.env exists (dropped by the host's recovery logic),
# adopt it as the selected bridge set so a respawn uses the freshly-fetched
# bridges. The host has already chosen these, so we do not re-evaluate.
reload_bridges() {
    if [ -r "$BRIDGES_REFRESH" ]; then
        cp "$BRIDGES_REFRESH" "$SELECTED_ENV" 2>/dev/null || true
        echo "tor-supervisor: reloaded bridges from $BRIDGES_REFRESH"
    fi
}

# Spawn (or respawn) tor with the selected bridges (1..N). Caller must have
# killed any previous TOR_PID first. Returns 0 on launch, 1 if no usable
# bridge is available (refusing to launch is safer than bootstrapping on
# garbage).
launch_tor() {
    reload_bridges
    if ! load_and_validate; then
        echo "tor-supervisor: REFUSING to launch tor on invalid/empty bridges" >&2
        return 1
    fi
    # Build the "Bridge <line> Bridge <line> ..." argument list dynamically.
    set --
    _n=1
    while [ "$_n" -le "$MAX_BRIDGE_SLOTS" ]; do
        eval "_b=\${BRIDGE${_n}:-}"
        [ -n "${_b:-}" ] && set -- "$@" Bridge "$_b"
        _n=$((_n + 1))
    done
    : > "$TOR_LOG"   # truncate so wait_for_tor_bootstrap below starts fresh
    tor "$@" >"$TOR_LOG" 2>&1 &
    TOR_PID=$!
    GENERATION=$((GENERATION + 1))
    write_kv "$GENERATION_FILE" "" "" "$GENERATION" "$TOR_PID"
    echo "tor-supervisor: spawned tor pid=$TOR_PID generation=$GENERATION with $NBRIDGES bridge(s)"
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
rm -f "$RESTART_FLAG" "$BRIDGES_REFRESH" "$RESTART_REQUEST" "$RESTART_REQUEST.claimed" "$RESTART_PENDING" "$RESTART_ACK" "$RESTART_REJECTED" "$GENERATION_FILE"

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
        # A request is consumed only when no restart is in progress, so an
        # acknowledgement is never lost to a second request.
        if [ -f "$RESTART_REQUEST" ] && [ ! -f "$RESTART_FLAG" ]; then
            # Claim the request by rename before reading it: a request
            # written meanwhile lands as a new file and is not lost.
            _req=""
            if mv "$RESTART_REQUEST" "$RESTART_REQUEST.claimed" 2>/dev/null; then
                _req=$(head -n 1 "$RESTART_REQUEST.claimed" 2>/dev/null || true)
                rm -f "$RESTART_REQUEST.claimed"
            fi
            # "legacy" is reserved for the flag interface's acknowledgements.
            if [ "$_req" != legacy ] && printf '%s\n' "$_req" | grep -Eqx '[A-Za-z0-9._:-]{1,64}'; then
                printf '%s\n' "$_req" > "$RESTART_PENDING"
                echo "tor-supervisor: restart request $_req accepted"
                : > "$RESTART_FLAG"
            else
                echo "tor-supervisor: restart request rejected (invalid id)" >&2
                write_kv "$RESTART_REJECTED" invalid rejected "$(gen_field generation)" "$(gen_field tor_pid)"
            fi
        fi
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
    # Poll until any child is gone. Not `wait -n`: busybox ash's `wait -n`
    # returns only for a child that exits 0, so a tor killed for a planned
    # restart (143) or a crashed haproxy was never noticed -- tor was not
    # respawned and the container ran on without it. ash reaps background
    # children while `sleep` runs, so `kill -0` fails once one has exited,
    # and `wait <pid>` then returns its recorded status. Both are busybox ash
    # behaviours (a zombie would still answer kill -0), proven on this image
    # by nice-dns tests/integration/transport-haproxy; re-verify on a busybox
    # upgrade.
    while kill -0 "${TOR_PID:-0}" 2>/dev/null && kill -0 "${HAPROXY_PID:-0}" 2>/dev/null \
        && kill -0 "${PROBE_PID:-0}" 2>/dev/null && kill -0 "${WATCHER_PID:-0}" 2>/dev/null; do
        sleep 1
    done
    ec=0
    for _p in "${TOR_PID:-}" "${HAPROXY_PID:-}" "${PROBE_PID:-}" "${WATCHER_PID:-}"; do
        if [ -n "$_p" ] && ! kill -0 "$_p" 2>/dev/null; then
            wait "$_p" 2>/dev/null || ec=$?
            break
        fi
    done

    # Identify which child died. kill -0 returns 0 iff the process is
    # alive. We use the most-recent TOR_PID captured by launch_tor.
    if ! kill -0 "${TOR_PID:-0}" 2>/dev/null; then
        if [ -f "$RESTART_FLAG" ]; then
            echo "tor-supervisor: tor exited as part of planned restart, respawning"
            _req=$(cat "$RESTART_PENDING" 2>/dev/null || true)
            [ -n "$_req" ] || _req=legacy
            rm -f "$RESTART_PENDING" "$RESTART_FLAG"
            if launch_tor; then
                write_kv "$RESTART_ACK" "$_req" respawned "$GENERATION" "$TOR_PID"
                wait_for_tor_bootstrap || true
                # If bridges file was a one-shot drop, remove it so the
                # next reload reverts to original env vars unless the
                # host drops another file.
                rm -f "$BRIDGES_REFRESH"
                continue
            else
                write_kv "$RESTART_ACK" "$_req" refused "$GENERATION" 0
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
