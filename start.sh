#!/bin/sh

BRIDGE1="${BRIDGE1:-obfs4 23.95.62.122:8040 CBBE8FC02F311F2656C405896F38A7E63490F4CC cert=Whto8g08oWYv5VIukHsWcI8PoIGhDeampPmaN2mlGM3fZAVhhppwvKajeGCAvDQX4rqGNQ iat-mode=1}"
BRIDGE2="${BRIDGE2:-obfs4 37.27.122.122:8088 7F6051103D00F6E6615C5C8D92C4B648B32331D3 cert=DQ6XOkBQSY424G3SVbOQH5R5aQuWWaCgSI6jv4q7LnI+0h/fJHv4cPX1TMHoY2zD2FUwdQ iat-mode=0}"

tor Bridge "$BRIDGE1" Bridge "$BRIDGE2" &

sed -i "s/LISTEN_PORT/${PORT}/" /etc/haproxy/haproxy.cfg

# Wait for Tor to bootstrap
sleep 10

# Start haproxy — SOCKS4 routing through Tor is native, no torsocks needed
exec haproxy -f /etc/haproxy/haproxy.cfg -W


