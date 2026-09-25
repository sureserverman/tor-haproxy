<h1 align="center">
  <a href="https://github.com/sureserverman/tor-haproxy">
    <img src="docs/images/logo.svg" alt="Logo" width="100" height="100">
  </a>
</h1>

<div align="center">
  tor-haproxy
  <br />
  <a href="https://github.com/sureserverman/tor-haproxy/issues/new?assignees=&labels=bug&template=01_BUG_REPORT.md&title=bug%3A+">Report a Bug</a>
  ·
  <a href="https://github.com/sureserverman/tor-haproxy/issues/new?assignees=&labels=enhancement&template=02_FEATURE_REQUEST.md&title=feat%3A+">Request a Feature</a>
  .
  <a href="https://github.com/sureserverman/tor-haproxy/issues/new?assignees=&labels=question&template=04_SUPPORT_QUESTION.md&title=support%3A+">Ask a Question</a>
</div>

<div align="center">
<br />

[![Project license](https://img.shields.io/github/license/sureserverman/tor-haproxy.svg?style=flat-square)](LICENSE)

[![Pull Requests welcome](https://img.shields.io/badge/PRs-welcome-ff69b4.svg?style=flat-square)](https://github.com/sureserverman/tor-haproxy/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
[![code with love by sureserverman](https://img.shields.io/badge/%3C%2F%3E%20with%20%E2%99%A5%20by-sureserverman-ff1414.svg?style=flat-square)](https://github.com/sureserverman)

</div>

<details open="open">
<summary>Table of Contents</summary>

- [About](#about)
- [How it works](#how-it-works)
- [Usage](#usage)
- [Differences from tor-socat](#differences-from-tor-socat)
- [Roadmap](#roadmap)
- [Project assistance](#project-assistance)
- [Authors & contributors](#authors--contributors)
- [Security](#security)
- [License](#license)

</details>

---

## About

> This image combines **TOR** and **haproxy** to create a local DNS proxy through TOR to CloudFlare's hidden DNS resolver\
> https://dns4torpnlfs2ifuz2s2yf3fc7rdmsbhm6rw75euj35pac6ap25zgqad.onion/
>
> haproxy provides industrial-grade TCP proxying with native SOCKS4 support for Tor routing, built-in health checks, and automatic failover — replacing the shell-based failover logic entirely.

## How it works

> 1. Clients connect to the container via **DNS-over-TLS** on port 853
> 2. **haproxy** relays the raw TCP stream (TLS passthrough) to an upstream DNS-over-TLS resolver
> 3. haproxy's native **SOCKS4** support routes connections through **Tor's** SOCKS proxy on port 9050
> 4. Tor's **MapAddress** directive maps a virtual IP (10.192.0.1) to Cloudflare's .onion resolver
> 5. haproxy performs **health checks** against all upstreams and automatically fails over if the primary goes down
>
> Unlike tor-socat, the failover is fully handled by haproxy — no shell scripts parsing stderr.

## Usage


> To use it as upstream server for other docker containers your command may look like:\
> `docker run -d --name=tor-haproxy --restart=always sureserver/tor-haproxy:latest`
>
> If you want to access it from your host, publish port 853 like this:\
> `docker run -d --name=tor-haproxy -p 853:853 --restart=always sureserver/tor-haproxy:latest`
>
> This image uses obfs4 bridges to access tor network. There is a pair of them in this image. If you want to use another ones, just do it like this:\
> `docker run -d --name=tor-haproxy -e BRIDGE1="obfs4 IP:PORT FINGERPRINT cert=... iat-mode=0" -e BRIDGE2="obfs4 IP:PORT FINGERPRINT cert=... iat-mode=0" --restart=always sureserver/tor-haproxy:latest`
> with your desired bridges' strings in quotes
>
> After that just use IP-address of your container and port 853 as DNS-over-TLS upstream resolver

### Podman

> All the same commands work with Podman by replacing `docker` with `podman`:\
> `podman run -d --name=tor-haproxy --restart=always sureserver/tor-haproxy:latest`
>
> With host port published:\
> `podman run -d --name=tor-haproxy -p 853:853 --restart=always sureserver/tor-haproxy:latest`
>
> With custom bridges:\
> `podman run -d --name=tor-haproxy -e BRIDGE1="obfs4 IP:PORT FINGERPRINT cert=... iat-mode=0" -e BRIDGE2="obfs4 IP:PORT FINGERPRINT cert=... iat-mode=0" --restart=always sureserver/tor-haproxy:latest`
>
> To generate a systemd service for auto-start:\
> `podman generate systemd --name tor-haproxy --new > ~/.config/systemd/user/tor-haproxy.service`\
> `systemctl --user enable --now tor-haproxy.service`

## Routes

> Port 853 is the legacy listener: the Cloudflare .onion first, Cloudflare's 1.1.1.1 via a Tor exit as backup. It is Cloudflare only. The earlier Quad9 (9.9.9.9) fallback was removed, because a client that authenticates a Cloudflare name must never have its stream handed to another provider.
>
> Three identity-bound routes reach exactly one provider each, with no backup or fallback to another provider:
>
> | Port | Route | Destinations (through Tor) |
> |---|---|---|
> | 18531 | cloudflare-onion | Cloudflare's resolver .onion (virtual IP 10.192.0.1) |
> | 18532 | cloudflare-exit | 1.1.1.1:853, 1.0.0.1:853 via a Tor exit |
> | 18533 | quad9-exit | 9.9.9.9:853, 149.112.112.112:853 via a Tor exit |
>
> tor-socat offers the same routes with one address per exit route (1.1.1.1, 9.9.9.9); here each exit route balances over two addresses of the same provider. Either way a route reaches exactly one provider.
>
> The TLS session is end to end between your client and the provider. Your client must verify the provider's name for the route it uses. The client, not this image, chooses between routes. Each route listener accepts at most 128 connections; 853 accepts 256.
>
> Route backends have no health checks, by design: a check exists to steer traffic elsewhere, and these routes have nowhere else to go. A failing provider shows up as failed client connections, which the client's route policy observes.
>
> Trust boundary: provider separation is enforced by the static `haproxy.cfg`. The runtime socket `/tmp/haproxy.sock` is admin-level, because the latency probe needs `set server ... state`. It is mode 0660 and owned by the image's own user. A process running as that user could repoint a server at runtime. The client's TLS name check is the final guard: a stream sent to another provider fails verification instead of being answered.

## Restarting Tor without restarting the container

> As the image's own user (the default for `docker exec`/`podman exec`), write a request id (1–64 characters from `A-Za-z0-9._:-`; `legacy` is reserved) to `/app/data/control/tor-restart-request`. Write a temp file in the same directory and `mv` it, so the write is atomic. `/app/data/control` is 0700, so no other user can request a restart or forge an answer. Within about 5 seconds only Tor is restarted; haproxy keeps running. The answer appears in `/app/data/control/tor-restart-ack` as tab-separated lines: `request_id`, `status` (`respawned` or `refused`), `generation`, `tor_pid` and `utc`. An invalid id is answered in `tor-restart-rejected` instead, never over a pending acknowledgement. `/app/data/control/tor-generation` always names the current generation and Tor pid. An acknowledgement means Tor was respawned, not that it has bootstrapped. Check readiness separately. Touching `/tmp/tor-restart-flag` (the older interface) still works; it is acknowledged as request id `legacy`.

## Probing a route; the health check

> `nice-dns-route-probe PORT TLS_NAME [QNAME [QTYPE]]` sends one DNS-over-TLS query through a listener of this image and prints one line, for example `port=18532 name=one.one.one.one result=ok rcode=NOERROR ms=640`. The certificate must chain to the image CA store (`NICE_DNS_PROBE_CA` overrides it) and match `TLS_NAME`. Pass the name your client authenticates on that route. `result=ok` means a DNS response with NOERROR or NXDOMAIN; a valid negative answer is working transport. `result=dns-error` means another response code, such as SERVFAIL or REFUSED. `result=no-answer` means no DNS response: a refused or dropped connection, a certificate or name that failed verification, or a timeout (`NICE_DNS_PROBE_TIMEOUT`, default 10 s). The exit status is 0 only for `ok`. The query defaults to `. SOA` (`NICE_DNS_PROBE_QNAME` overrides the name); no client name is ever sent. `nice-dns-route-probe --capabilities` prints what the probe verifies.
>
> The image `HEALTHCHECK` is that probe on the legacy listener with `tor.cloudflare-dns.com`, the name its clients authenticate there. A wrong-name, untrusted or expired certificate, SERVFAIL or a dropped stream is unhealthy. A deployment that uses another route sets `NICE_DNS_HEALTH_PORT` and `NICE_DNS_HEALTH_TLS_NAME`.
>
> The image labels declare the interface: `org.nice-dns.transport.interface` (`nice-dns-transport/2`), `org.nice-dns.transport.routes` (route=port pairs), `org.nice-dns.transport.probe` and `org.nice-dns.transport.restart` (`control-dir-ack`, the restart contract above).
>
> Migration from the earlier image: the health check used to accept any certificate and any answer to `google.com`, so it could report a wrong provider or an unauthenticated session as healthy. Clients of port 853 need no change. A client that ran its own `dig +tls` checks should verify the name the same way.

## Differences from tor-socat

| | tor-socat | tor-haproxy |
|---|---|---|
| Local protocol | TLS passthrough | TLS passthrough (identical client behavior) |
| Failover | Shell-based health checks (`nice-dns-route-probe` every 30s) | haproxy health checks (`inter 30s fall 3 rise 2`) |
| Tor routing | socat SOCKS4A | haproxy native `socks4` keyword |
| .onion support | SOCKS4A hostname resolution | Tor `MapAddress` to virtual IP |
| Health monitoring | Active DNS health checks every 30s | Active TCP health checks every 30s |
| Connection logging | socat debug output | haproxy tcplog |

## Roadmap

See the [open issues](https://github.com/sureserverman/tor-haproxy/issues) for a list of proposed features (and known issues).

## Project assistance

If you want to say **thank you** or/and support active development of tor-haproxy:

- Add a [GitHub Star](https://github.com/sureserverman/tor-haproxy) to the project.
- Tweet about the tor-haproxy.
- Write interesting articles about the project on [Dev.to](https://dev.to/), [Medium](https://medium.com/) or your personal blog.

Together, we can make tor-haproxy **better**!

## Authors & contributors

The original setup of this repository is by [Serverman](https://github.com/sureserverman).

For a full list of all authors and contributors, see [the contributors page](https://github.com/sureserverman/tor-haproxy/contributors).

## Security

tor-haproxy follows good practices of security, but 100% security cannot be assured.
tor-haproxy is provided **"as is"** without any **warranty**. Use at your own risk.

## License

This project is licensed under the **MIT license**.

See [LICENSE](LICENSE.md) for more information.
