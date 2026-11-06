#!/bin/sh
# Test double for /usr/bin/tor, bind-mounted read-only over it by
# tests/run.sh. It records its argv (one line per spawn, arguments joined by
# single spaces) in /app/data/tor-argv, answers SOCKS4 on 127.0.0.1:9050 with
# "request granted" so the supervisor's stream probe succeeds, prints the
# bootstrap line the supervisor waits for, and then runs until TERM.
printf '%s\n' "$*" >> /app/data/tor-argv

stub=/tmp/fake-tor-socks-reply.sh
cat > "$stub" <<'EOF'
dd bs=512 count=1 >/dev/null 2>&1
printf '\000\132\000\000\000\000\000\000'
cat >/dev/null
EOF
socat TCP4-LISTEN:9050,bind=127.0.0.1,reuseaddr,fork EXEC:"sh $stub" >/dev/null 2>&1 &
socks=$!

echo "Bootstrapped 100% (done): Done"

sl=""
trap 'kill "$socks" $sl 2>/dev/null; wait; exit 0' TERM INT
while :; do
    sleep 3600 &
    sl=$!
    wait "$sl"
done
