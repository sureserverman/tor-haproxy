#!/bin/sh
# probe-primary.sh — latency-aware demotion of haproxy's .onion primary.
#
# Loop measures end-to-end SOCKS4-connect time from this container to the
# Cloudflare DoT .onion (10.192.0.1 → MapAddress via Tor's torrc). When
# the measured time exceeds SLOW_THRESHOLD_MS for DEMOTE_CONSECUTIVE
# probes in a row, the primary server is set to `maint` in haproxy's
# runtime state, so client traffic shifts to backup (DoT-over-Tor-exit
# to 1.1.1.1). The probe keeps running while primary is in maint —
# once PROMOTE_CONSECUTIVE probes come back fast, primary is set back
# to `ready` and starts serving again.
#
# This intentionally bypasses haproxy's routing (probes go straight to
# 127.0.0.1:9050 via SOCKS4) so we can observe primary's true latency
# even when haproxy is currently sending traffic to backup. That's the
# only way to know when primary has recovered.
#
# Tunables (env, with defaults):
#   SLOW_THRESHOLD_MS=3000          one-shot probe ms ceiling
#   PROBE_INTERVAL_S=30             seconds between probes
#   DEMOTE_CONSECUTIVE=3            slow probes in a row → maint
#   PROMOTE_CONSECUTIVE=3           fast probes in a row → ready
#   PROBE_TIMEOUT_S=10              hard cap on socat (kills hung connects)
#
# Outputs one line per probe to stdout (captured by podman → journal):
#   primary-probe t=420ms streak=fast/2  (current state: ready)
#   primary-probe t=4812ms streak=slow/3 → demoting to maint
#   primary-probe TIMEOUT streak=slow/1
#   primary-probe t=580ms streak=fast/3 → promoting to ready
#
# Exits non-zero on unrecoverable error (admin socket gone, socat missing,
# etc.) — start.sh's `wait -n` will then tear down the whole container.

set -u

: "${SLOW_THRESHOLD_MS:=3000}"
: "${PROBE_INTERVAL_S:=30}"
: "${DEMOTE_CONSECUTIVE:=3}"
: "${PROMOTE_CONSECUTIVE:=3}"
: "${PROBE_TIMEOUT_S:=10}"

ADMIN_SOCK="/tmp/haproxy.sock"
BACKEND="dns_resolvers"
SERVER="primary"

# Wait for the admin socket to appear (haproxy starts in parallel).
i=0
while [ ! -S "$ADMIN_SOCK" ] && [ "$i" -lt 60 ]; do
    sleep 1
    i=$((i + 1))
done
if [ ! -S "$ADMIN_SOCK" ]; then
    echo "primary-probe: $ADMIN_SOCK never appeared, exiting" >&2
    exit 1
fi
echo "primary-probe: starting (threshold=${SLOW_THRESHOLD_MS}ms, interval=${PROBE_INTERVAL_S}s, demote/promote=${DEMOTE_CONSECUTIVE}/${PROMOTE_CONSECUTIVE})"

# Send a command to the admin socket; print response.
admin_cmd() {
    printf 'prompt\n%s\nquit\n' "$1" | socat -t 5 - "UNIX-CONNECT:$ADMIN_SOCK" 2>/dev/null
}

# Current admin-reported state ("ready" | "maint" | "drain" | "down").
current_state() {
    admin_cmd "show servers state $BACKEND" \
        | awk -v s="$SERVER" '
            /^# / { next }
            $4 == s {
                # state field is column 5 (admin_state):
                # 0=MAINT, 1=READY, 2=DRAIN.  But the canonical text form
                # is in `show stat`; use that instead for portability.
            }' >/dev/null
    admin_cmd "show stat $BACKEND $SERVER" \
        | awk -F, -v s="$SERVER" '$2 == s { print $18; exit }'
}

# One latency probe to 10.192.0.1:853 via SOCKS4 at 127.0.0.1:9050.
# Echoes the elapsed milliseconds, or "TIMEOUT" on exceeded budget,
# or "ERR<N>" on socat failure (e.g. SOCKS rejected).
probe_once() {
    t0=$(date +%s%3N)
    timeout "$PROBE_TIMEOUT_S" socat -T 5 - \
        "SOCKS4:127.0.0.1:10.192.0.1:853,socksport=9050" </dev/null >/dev/null 2>&1
    # Capture rc on the immediate next line — busybox ash's `local x=$?`
    # runs `local` first and so $? becomes 0 (local's exit code), not the
    # exit code of the timeout/socat pipeline we actually care about.
    rc=$?
    t1=$(date +%s%3N)
    if [ "$rc" -eq 0 ]; then
        echo "$((t1 - t0))"
        return 0
    fi
    # 124 = coreutils-timeout fired; 143 = SIGTERM (busybox-timeout delivers
    # SIGTERM instead of distinguishing); 137 = SIGKILL. Any of those after
    # roughly the timeout window means "did not complete in budget."
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ] \
       || [ "$((t1 - t0))" -ge "$((PROBE_TIMEOUT_S * 1000 - 500))" ]; then
        echo "TIMEOUT"
    else
        echo "ERR$rc"
    fi
    return 1
}

set_state() {
    local new_state="$1"
    admin_cmd "set server $BACKEND/$SERVER state $new_state" >/dev/null
}

slow_streak=0
fast_streak=0

while true; do
    result="$(probe_once)"
    state="$(current_state 2>/dev/null)"
    [ -z "$state" ] && state="?"

    if echo "$result" | grep -qE '^[0-9]+$'; then
        t_ms="$result"
        if [ "$t_ms" -le "$SLOW_THRESHOLD_MS" ]; then
            fast_streak=$((fast_streak + 1))
            slow_streak=0
            label="fast/$fast_streak"
        else
            slow_streak=$((slow_streak + 1))
            fast_streak=0
            label="slow/$slow_streak"
        fi
        echo "primary-probe t=${t_ms}ms streak=$label state=$state"
    else
        # Non-numeric: TIMEOUT or ERR. Count as slow.
        slow_streak=$((slow_streak + 1))
        fast_streak=0
        echo "primary-probe $result streak=slow/$slow_streak state=$state"
    fi

    # State transitions.
    case "$state" in
        UP|*UP*|ready|*ready*)
            if [ "$slow_streak" -ge "$DEMOTE_CONSECUTIVE" ]; then
                echo "primary-probe → demoting to maint after $slow_streak slow probes"
                set_state maint
                slow_streak=0
            fi
            ;;
        MAINT|*MAINT*|maint|*maint*)
            if [ "$fast_streak" -ge "$PROMOTE_CONSECUTIVE" ]; then
                echo "primary-probe → promoting to ready after $fast_streak fast probes"
                set_state ready
                fast_streak=0
            fi
            ;;
        DOWN|*DOWN*|down|*down*)
            # Primary is failed at the L4/L7 check level — haproxy's own
            # rise/fall machinery is handling it. Leave it alone.
            ;;
    esac

    sleep "$PROBE_INTERVAL_S"
done
