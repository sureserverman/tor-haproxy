#!/bin/sh
# nice-dns-route-probe: one authenticated DNS-over-TLS query through a route
# listener of this image (nice-dns ARCH-05; the same file ships in
# tor-haproxy and tor-socat).
#
#   nice-dns-route-probe PORT TLS_NAME [QNAME [QTYPE]]
#   nice-dns-route-probe --capabilities
#
# Sends QNAME/QTYPE (default $NICE_DNS_PROBE_QNAME or ".", and SOA) over TLS
# to 127.0.0.1:PORT, which carries it through Tor to the route's provider.
# The certificate must chain to NICE_DNS_PROBE_CA (default the image CA
# store) and match TLS_NAME: pass the name the route's consumer
# authenticates. Prints one line, and exits 0 only for result=ok:
#
#   port=853 name=tor.cloudflare-dns.com result=ok rcode=NOERROR ms=412
#
#   result=ok         a DNS response with rcode NOERROR or NXDOMAIN (a valid
#                     negative answer is working transport)
#   result=dns-error  a DNS response with another rcode (SERVFAIL, REFUSED...)
#   result=no-answer  no DNS response: refused or dropped connection, failed
#                     certificate or name verification, or timeout
#
# The verdict comes from the response header only: dig exits 0 on a dropped
# TLS connection, and +short output mixes ";;" errors with answers.
# NICE_DNS_PROBE_TIMEOUT (default 10 s) bounds the query. Exit 2: usage.

set -u

ME=nice-dns-route-probe

if [ "${1:-}" = --capabilities ]; then
  printf 'probe\t%s/1\nverify\ttls-ca tls-hostname\nresults\tok dns-error no-answer\n' "$ME"
  exit 0
fi

usage() { printf 'usage: %s PORT TLS_NAME [QNAME [QTYPE]] | --capabilities\n' "$ME" >&2; exit 2; }

[ $# -ge 2 ] && [ $# -le 4 ] || usage
port=$1 name=$2 qname=${3:-${NICE_DNS_PROBE_QNAME:-.}} qtype=${4:-SOA}
case "$port" in ''|0*|*[!0-9]*) usage ;; esac
[ "$port" -le 65535 ] || usage
case "$name" in ''|.*|*[!a-z0-9.-]*) usage ;; esac
case "$qname" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
case "$qtype" in ''|*[!A-Z0-9]*) usage ;; esac
ca=${NICE_DNS_PROBE_CA:-/etc/ssl/certs/ca-certificates.crt}
t=${NICE_DNS_PROBE_TIMEOUT:-10}
case "$t" in ''|0|*[!0-9]*) usage ;; esac

if [ ! -r "$ca" ]; then
  printf 'port=%s name=%s result=no-answer rcode=- ms=0 error=ca-unreadable\n' "$port" "$name"
  exit 1
fi

t0=$(date +%s%3N)
out=$(dig +tls +tls-ca="$ca" +tls-hostname="$name" +tries=1 +retry=0 +time="$t" \
  -p "$port" @127.0.0.1 "$qname" "$qtype" 2>&1)
t1=$(date +%s%3N)
rcode=$(printf '%s\n' "$out" | sed -n 's/^;; ->>HEADER<<- opcode: [A-Z]*, status: \([A-Z]*\), id: [0-9]*$/\1/p' | head -n 1)
case "$rcode" in
  NOERROR|NXDOMAIN) result=ok ;;
  '') result=no-answer rcode=- ;;
  *) result=dns-error ;;
esac
printf 'port=%s name=%s result=%s rcode=%s ms=%s\n' "$port" "$name" "$result" "$rcode" "$((t1 - t0))"
[ "$result" = ok ]
