# tor-haproxy

DNS-over-TLS resolver through Tor using **haproxy** with built-in health checks and automatic failover.

## What it does

Routes your DNS queries through the Tor network to encrypted upstream DNS resolvers. haproxy provides industrial-grade TCP proxying with native SOCKS4 support for Tor routing and active health monitoring of all upstreams.

**Upstream resolvers (in failover order):**
1. Cloudflare .onion hidden DNS resolver (most private)
2. Cloudflare 1.1.1.1 (backup)
3. Quad9 9.9.9.9 (backup)

Clients connect via **DNS-over-TLS** — haproxy does transparent TLS passthrough, so the TLS session is end-to-end between your client and the upstream resolver.

## Quick start

```bash
docker run -d --name=tor-haproxy -p 853:853 --restart=always sureserver/tor-haproxy:latest
```

Then point your DNS client to `127.0.0.1:853` as a DNS-over-TLS upstream.

## As upstream for other containers

```bash
docker run -d --name=tor-haproxy --restart=always sureserver/tor-haproxy:latest
```

Use the container IP and port 853 as a DNS-over-TLS upstream in your resolver (Unbound, Pi-hole, etc.).

## Podman

```bash
podman run -d --name=tor-haproxy -p 853:853 --restart=always sureserver/tor-haproxy:latest
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `853` | Listening port (853 for DoT, 443 for DoH, 53 for DNS) |
| `BRIDGE1` | *(built-in)* | First obfs4 bridge string |
| `BRIDGE2` | *(built-in)* | Second obfs4 bridge string |

## Custom bridges

```bash
docker run -d --name=tor-haproxy \
  -e BRIDGE1="obfs4 IP:PORT FINGERPRINT cert=... iat-mode=0" \
  -e BRIDGE2="obfs4 IP:PORT FINGERPRINT cert=... iat-mode=0" \
  --restart=always sureserver/tor-haproxy:latest
```

## Different protocols

```bash
# DNS-over-HTTPS
docker run -d --name=tor-haproxy -e PORT=443 --restart=always sureserver/tor-haproxy:latest

# Plain DNS
docker run -d --name=tor-haproxy -e PORT=53 --restart=always sureserver/tor-haproxy:latest
```

## Architecture

```
Client --[DNS-over-TLS]--> haproxy --[SOCKS4]--> Tor ---> upstream DoT resolver
```

- **haproxy** in TCP mode does transparent TLS passthrough (end-to-end encryption)
- Native **socks4** keyword routes each connection through Tor — no torsocks/LD_PRELOAD
- Tor **MapAddress** maps a virtual IP to Cloudflare's .onion address for SOCKS4 compatibility
- **Health checks** every 30s with `fall 3 rise 2` — automatic failover to backup servers
- **backup** servers only receive traffic when primary is down

## Supported platforms

`linux/amd64` | `linux/arm/v7` | `linux/arm64` | `linux/riscv64`

## Source

[GitHub](https://github.com/sureserverman/tor-haproxy)

## License

GPLv3
