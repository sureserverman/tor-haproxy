FROM ghcr.io/ironpeakservices/iron-alpine/iron-alpine:3

RUN apk -U --no-cache upgrade \
    && apk add --no-cache tor haproxy bind-tools tini \
    && apk add --no-cache lyrebird \
        --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community/

COPY torrc /etc/tor/
COPY haproxy.cfg /etc/haproxy/
COPY start.sh /bin/

ENV PORT=853
HEALTHCHECK CMD dig +short +tls +norecurse +retry=0 -p 853 @127.0.0.1 google.com || exit 1

# Remove apk and lock down app directory
RUN $APP_DIR/post-install.sh

ENTRYPOINT ["tini", "--"]
CMD ["/bin/start.sh"]
