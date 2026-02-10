FROM alpine:latest

RUN apk -U --no-cache upgrade
RUN apk add --no-cache tor
RUN apk add --no-cache haproxy
RUN apk add --no-cache bind-tools
RUN apk add --no-cache tini
RUN apk add lyrebird --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community/
ADD torrc /etc/tor/
ADD start.sh /bin/
ENV PORT=853
HEALTHCHECK CMD dig +short +tls +norecurse +retry=0 -p 853 @127.0.0.1 google.com || exit 1
ENTRYPOINT ["tini", "--"]
CMD ["/bin/start.sh"]
