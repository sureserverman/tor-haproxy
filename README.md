<h1 align="center">
  <a href="https://github.com/sureserverman/tor-haproxy">
    <img src="docs/images/logo.svg" alt="Logo" width="100" height="100">
  </a>
</h1>

<div align="center">
  tor-haproxy
  <br />
  <a href="#about"><strong>Explore the screenshots »</strong></a>
  <br />
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

> 1. Clients connect to the container via **DNS-over-TLS** on port 853 (or configured PORT)
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
>
> To use it for DNS-over-HTTPS do it this way:\
> `docker run -d --name=tor-haproxy -e PORT=443 --restart=always sureserver/tor-haproxy:latest`
>
> To use it for DNS do it this way:\
> `docker run -d --name=tor-haproxy -e PORT=53 --restart=always sureserver/tor-haproxy:latest`

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

## Differences from tor-socat

| | tor-socat | tor-haproxy |
|---|---|---|
| Local protocol | TLS passthrough | TLS passthrough (identical client behavior) |
| Failover | Shell-based stderr parsing | haproxy health checks (`inter 30s fall 3 rise 2`) |
| Retry on disconnect | Manual | haproxy retries with configurable count |
| Tor routing | socat SOCKS4A | haproxy native `socks4` keyword |
| .onion support | SOCKS4A hostname resolution | Tor `MapAddress` to virtual IP |
| Health monitoring | None (reactive only) | Active TCP health checks every 30s |
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
