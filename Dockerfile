# --- bridge-eval builder ---------------------------------------------------
# Cross-compiles the obfs4 bridge evaluator for the target arch. Pure-Go,
# CGO-free, no module deps, so it builds for amd64 / armv7 / arm64 / riscv64
# from any BUILDPLATFORM. GOTOOLCHAIN=local + GOPROXY=off keep it hermetic.
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS bridge-eval-build
ARG TARGETARCH
ARG TARGETVARIANT
ENV CGO_ENABLED=0 GOOS=linux GOTOOLCHAIN=local GOPROXY=off
WORKDIR /src
COPY bridge-eval/go.mod bridge-eval/main.go ./
RUN GOARCH="$TARGETARCH" GOARM="${TARGETVARIANT#v}" \
    go build -trimpath -ldflags='-s -w' -o /out/bridge-eval .

# alpine 3.22 ships haproxy 3.2.16 (3.21 had 3.0.20). 3.1+ is needed for the
# `init-state down` server keyword used in haproxy.cfg — it lets the
# .onion primary start in DOWN state and promote to UP only after its first
# health check succeeds, so the clearnet `backup` serves immediately at
# cold-start instead of the user waiting ~20s for the primary's first
# rendezvous build.
FROM alpine:3.23.4

LABEL org.opencontainers.image.source="https://github.com/sureserverman/tor-haproxy"

SHELL ["/bin/sh", "-o", "pipefail", "-c"]

# HTTPS-only apk repositories
RUN echo "https://alpine.global.ssl.fastly.net/alpine/v$(cut -d . -f 1,2 < /etc/alpine-release)/main" > /etc/apk/repositories \
    && echo "https://alpine.global.ssl.fastly.net/alpine/v$(cut -d . -f 1,2 < /etc/alpine-release)/community" >> /etc/apk/repositories

ENV APP_USER=app
ENV APP_DIR="/$APP_USER"
ENV DATA_DIR="$APP_DIR/data"
ENV CONF_DIR="$APP_DIR/conf"

# Edge-community release pin for lyrebird. Bump when alpine edge ships a new
# `0.8.1-rN` revision — the package version is hard-pinned (`=`) on the apk
# add line so `apk -U upgrade` will fail with `breaks: world[lyrebird=…]`
# the moment edge moves ahead. Override at build time with
# `--build-arg LYREBIRD_VERSION=…` to test a future bump without committing.
ARG LYREBIRD_VERSION=0.8.1-r5

RUN apk add --no-cache ca-certificates

# App user and directories. tor's DataDirectory and haproxy's runtime state
# both live under $DATA_DIR so they are writable by the unprivileged app user.
RUN adduser -s /bin/true -u 1000 -D -h $APP_DIR $APP_USER \
    && mkdir "$DATA_DIR" "$CONF_DIR" "$DATA_DIR/tor" \
    && chown -R "$APP_USER" "$APP_DIR" "$CONF_DIR" "$DATA_DIR" \
    && chmod 700 "$APP_DIR" "$DATA_DIR" "$CONF_DIR"

# Hardening (mirrors ironpeakservices/iron-alpine)
RUN rm -fr /var/spool/cron /etc/crontabs /etc/periodic \
    && find /sbin /usr/sbin ! -type d -a ! -name apk -a ! -name ln -delete \
    && find / -xdev -type d -perm +0002 -exec chmod o-w {} + \
    && find / -xdev -type f -perm +0002 -exec chmod o-w {} + \
    && chmod 777 /tmp/ && chown $APP_USER:root /tmp/ \
    && sed -i -r "/^($APP_USER|root|nobody)/!d" /etc/group \
    && sed -i -r "/^($APP_USER|root|nobody)/!d" /etc/passwd \
    && sed -i -r 's#^(.*):[^:]*$#\1:/sbin/nologin#' /etc/passwd \
    && { while IFS=: read -r username _; do passwd -l "$username"; done < /etc/passwd || true; } \
    && find /bin /etc /lib /sbin /usr -xdev -type f -regex '.*-$' -exec rm -f {} + \
    && find /bin /etc /lib /sbin /usr -xdev -type d -exec chown root:root {} \; -exec chmod 0755 {} \; \
    && find /bin /etc /lib /sbin /usr -xdev -type f -a \( -perm +4000 -o -perm +2000 \) -delete \
    && find /bin /etc /lib /sbin /usr -xdev \( \
         -iname hexdump -o -iname chgrp -o -iname ln -o -iname od -o \
         -iname strings -o -iname su -o -iname sudo \) -delete \
    && rm -fr /etc/init.d /lib/rc /etc/conf.d /etc/inittab /etc/runlevels /etc/rc.conf /etc/logrotate.d \
    && rm -fr /etc/sysctl* /etc/modprobe.d /etc/modules /etc/mdev.conf /etc/acpi \
    && rm -fr /root \
    && rm -f /etc/fstab \
    && find /bin /etc /lib /sbin /usr -xdev -type l -exec test ! -e {} \; -delete

COPY --chown=app:app --chmod=500 post-install.sh $APP_DIR/

WORKDIR $APP_DIR

# --- Application layer ---
# libcap is installed as a named virtual package — `apk del .setcap-deps`
# then removes libcap ONLY if no other installed package (e.g. tor) depends
# on it. Plain `apk del libcap` would fail with reverse-dep rejection.
RUN apk -U --no-cache upgrade \
    && apk add --no-cache tor haproxy bind-tools tini socat \
    && apk add --no-cache --virtual .setcap-deps libcap \
    && apk add --no-cache "lyrebird=${LYREBIRD_VERSION}" \
        --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community/ \
    && setcap 'cap_net_bind_service=+ep' /usr/sbin/haproxy \
    && apk del .setcap-deps

COPY --chown=root:root torrc /etc/tor/
COPY --chown=root:root haproxy.cfg /etc/haproxy/haproxy.cfg
COPY --chown=root:root status-summary.lua /etc/haproxy/status-summary.lua
COPY --chown=root:root --chmod=755 probe-primary.sh /bin/probe-primary.sh
COPY --chown=root:root --chmod=755 start.sh /bin/
COPY --from=bridge-eval-build --chown=root:root --chmod=755 /out/bridge-eval /bin/bridge-eval

HEALTHCHECK CMD dig +short +tls +norecurse +retry=0 -p 853 @127.0.0.1 google.com || exit 1

# Remove apk and lock down app directory
RUN $APP_DIR/post-install.sh

# Run as unprivileged user. haproxy retains CAP_NET_BIND_SERVICE via file
# capabilities so it can bind 853 without UID 0. tor and lyrebird only
# need outbound connections — no privileged ports.
USER app

ENTRYPOINT ["tini", "--"]
CMD ["/bin/start.sh"]
