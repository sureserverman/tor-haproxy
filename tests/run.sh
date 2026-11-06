#!/usr/bin/env bash
# Bridges-mode tests for start.sh: builds the image, runs it with
# tests/fake-tor.sh bind-mounted over /usr/bin/tor, and checks what tor is
# started with in each bridges mode, the refusals, and the acknowledged
# restart contract with bridges off. Needs podman. Exits non-zero if any case
# fails; removes every container it started.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
IMG=localhost/tor-haproxy:bridges-test
FAKE=$REPO/tests/fake-tor.sh
PFX="tor-haproxy-bridges-test-$$"
CTL=/app/data/control
BRIDGE='obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA iat-mode=0'
BRIDGE_B='obfs4 192.0.2.2:443 89ABCDEF0123456789ABCDEF0123456789ABCDEF cert=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB iat-mode=0'
IGN_POOL='tor-supervisor: bridges off: BRIDGE1..16 ignored'
IGN_EVAL='tor-supervisor: bridges off: BRIDGE_EVAL=auto ignored'
TMPD=$(mktemp -d)
FAILS=0
STARTED=()

cleanup() {
    local c
    for c in "${STARTED[@]}"; do
        podman rm -f -t 2 "$c" >/dev/null 2>&1 || true
    done
    rm -rf "${TMPD:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { echo "PASS: $1"; }
fail() {
    echo "FAIL: $1 -- $2"
    FAILS=$((FAILS + 1))
}

# start <name> <podman run args...>: start a detached test container.
start() {
    local c="$PFX-$1"
    shift
    STARTED+=("$c")
    podman run -d --name "$c" -v "$FAKE:/usr/bin/tor:ro" "$@" "$IMG" >/dev/null
}

running() { [ "$(podman inspect -f '{{.State.Running}}' "$PFX-$1" 2>/dev/null)" = true ]; }
logs() { podman logs "$PFX-$1" 2>&1; }

# wait_log <name> <fixed string> <seconds>: 0 once the log has the string;
# 1 on timeout or when the container stopped without it.
wait_log() {
    local i=0
    while [ "$i" -lt "$3" ]; do
        logs "$1" | grep -qF -- "$2" && return 0
        running "$1" || { logs "$1" | grep -qF -- "$2"; return; }
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# wait_exit <name> <seconds>: prints the exit code once the container stopped.
wait_exit() {
    local i=0
    while [ "$i" -lt "$2" ]; do
        if ! running "$1"; then
            podman inspect -f '{{.State.ExitCode}}' "$PFX-$1"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo timeout
    return 1
}

# file_of <name> <path>: a file of the container (running or stopped), or
# nothing when it does not exist.
file_of() {
    local d="$TMPD/$1.$RANDOM"
    mkdir -p "$d"
    podman cp "$PFX-$1:$2" "$d/f" >/dev/null 2>&1 && cat "$d/f"
}

# argv_line <name> <n>: the n-th recorded tor argv.
argv_line() { file_of "$1" /app/data/tor-argv | sed -n "${2}p"; }

has_bridge_arg() { printf '%s\n' "$1" | grep -qE '(^| )Bridge '; }
has_usebridges0() { printf '%s\n' "$1" | grep -qE '(^| )UseBridges 0( |$)'; }

tail_log() { logs "$1" | tail -n 8 | sed 's/^/    | /'; }

echo "building $IMG from $REPO"
# LYREBIRD_VERSION (optional) overrides the Dockerfile's lyrebird pin, for
# when Alpine edge has moved past it.
build_args=()
[ -z "${LYREBIRD_VERSION:-}" ] || build_args=(--build-arg "LYREBIRD_VERSION=$LYREBIRD_VERSION")
if ! podman build -q "${build_args[@]}" -t "$IMG" "$REPO" >/dev/null; then
    echo "FAIL: image build"
    exit 1
fi

# 1. Bridges off, no BRIDGEn: tor runs direct.
name="1 off without bridges runs tor direct"
start off -e TOR_BRIDGES=off
if ! wait_log off "tor-supervisor: spawned tor" 30; then
    fail "$name" "tor was not spawned; log tail:"; tail_log off
else
    a=$(argv_line off 1)
    if ! has_usebridges0 "$a"; then fail "$name" "argv lacks 'UseBridges 0': $a"
    elif has_bridge_arg "$a"; then fail "$name" "a Bridge argument survived: $a"
    elif ! logs off | grep -qF "direct (no bridges)"; then fail "$name" "log lacks 'direct (no bridges)'"
    else pass "$name"; fi
fi

# 1b. Bridges on with a bridge: unchanged.
name="1b on with a bridge passes it to tor"
start on -e TOR_BRIDGES=on -e BRIDGE1="$BRIDGE"
if ! wait_log on "tor-supervisor: spawned tor" 30; then
    fail "$name" "tor was not spawned; log tail:"; tail_log on
else
    a=$(argv_line on 1)
    if ! has_bridge_arg "$a"; then fail "$name" "argv lacks a Bridge argument: $a"
    elif has_usebridges0 "$a"; then fail "$name" "argv has 'UseBridges 0': $a"
    elif ! logs on | grep -qF "with 1 bridge(s)"; then fail "$name" "log lacks 'with 1 bridge(s)'"
    else pass "$name"; fi
fi

# 2. Default mode, no BRIDGE1: refuses as before.
name="2 default without bridges refuses"
start dflt
rc=$(wait_exit dflt 60)
if [ "$rc" = timeout ] || [ "$rc" = 0 ]; then fail "$name" "exit code $rc"
elif ! logs dflt | grep -qF "REFUSING to launch tor on invalid/empty bridges"; then
    fail "$name" "no refusal message; log tail:"; tail_log dflt
else pass "$name"; fi

# 3. Any other value: exit 1 before any other work.
name="3 TOR_BRIDGES=maybe exits 1"
start maybe -e TOR_BRIDGES=maybe -e BRIDGE1="$BRIDGE"
rc=$(wait_exit maybe 60)
if [ "$rc" != 1 ]; then fail "$name" "exit code $rc; log tail:"; tail_log maybe
elif ! logs maybe | grep -qF "TOR_BRIDGES must be on or off"; then fail "$name" "message missing; log tail:"; tail_log maybe
elif logs maybe | grep -qF "Waiting for Tor"; then fail "$name" "the supervisor went on before refusing"
elif [ -n "$(file_of maybe /app/data/tor-argv)" ]; then fail "$name" "tor was started"
else pass "$name"; fi

# 4. Bridges off with BRIDGE1 and BRIDGE_EVAL: both ignored, once each.
name="4 off ignores BRIDGEn and BRIDGE_EVAL"
start offb -e TOR_BRIDGES=off -e BRIDGE1="$BRIDGE" -e BRIDGE_EVAL=auto
if ! wait_log offb "tor-supervisor: spawned tor" 30; then
    fail "$name" "tor was not spawned; log tail:"; tail_log offb
else
    a=$(argv_line offb 1)
    np=$(logs offb | grep -cxF "$IGN_POOL")
    ne=$(logs offb | grep -cxF "$IGN_EVAL")
    if [ "$np" != 1 ]; then fail "$name" "'$IGN_POOL' appears $np times"
    elif [ "$ne" != 1 ]; then fail "$name" "'$IGN_EVAL' appears $ne times"
    elif has_bridge_arg "$a"; then fail "$name" "a Bridge argument survived: $a"
    elif ! has_usebridges0 "$a"; then fail "$name" "argv lacks 'UseBridges 0': $a"
    else pass "$name"; fi
fi

# 5. Acknowledged restart with bridges off (same container as 4), after the
# supervisor reached its main loop, with a host-dropped bridge refresh file
# that must be ignored.
name="5 off restart contract respawns direct"
if ! wait_log offb "Tor bootstrapped successfully." 60; then
    fail "$name" "the supervisor did not reach its main loop; log tail:"; tail_log offb
else
    podman exec "$PFX-offb" sh -c 'printf "BRIDGE1=%s\n" "$1" > /tmp/bridges-current.env' sh "$BRIDGE_B"
    podman exec "$PFX-offb" sh -c 'printf "%s\n" "$1" >"$2/tor-restart-request.tmp" && mv "$2/tor-restart-request.tmp" "$2/tor-restart-request"' sh bt-1 "$CTL"
    ack="" i=0
    while [ "$i" -lt 40 ]; do
        ack=$(file_of offb "$CTL/tor-restart-ack")
        printf '%s\n' "$ack" | grep -qxF "$(printf 'request_id\tbt-1')" && break
        sleep 1
        i=$((i + 1))
    done
    a2=$(argv_line offb 2)
    np=$(logs offb | grep -cxF "$IGN_POOL")
    ne=$(logs offb | grep -cxF "$IGN_EVAL")
    if ! printf '%s\n' "$ack" | grep -qxF "$(printf 'request_id\tbt-1')"; then
        fail "$name" "no acknowledgement for bt-1 within 40 s; log tail:"; tail_log offb
    elif ! printf '%s\n' "$ack" | grep -qxF "$(printf 'status\trespawned')"; then
        fail "$name" "acknowledgement is not respawned: $(printf '%s' "$ack" | tr '\t\n' ' ;')"
    elif [ -z "$a2" ]; then fail "$name" "no second argv line"
    elif has_bridge_arg "$a2"; then fail "$name" "a Bridge argument in the respawn: $a2"
    elif ! has_usebridges0 "$a2"; then fail "$name" "respawn argv lacks 'UseBridges 0': $a2"
    elif ! logs offb | grep -qF "generation=2 direct (no bridges)"; then fail "$name" "no direct generation-2 spawn line"
    elif [ "$np" != 1 ] || [ "$ne" != 1 ]; then fail "$name" "ignored lines repeated on respawn ($np, $ne)"
    elif ! running offb; then fail "$name" "container stopped after the restart"
    else pass "$name"; fi
fi

if [ "$FAILS" -ne 0 ]; then
    echo "$FAILS case(s) failed"
    exit 1
fi
echo "all cases passed"
