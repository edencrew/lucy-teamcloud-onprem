FROM alpine:3.20

RUN apk add --no-cache openssl

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/bin/sh", "/usr/local/bin/docker-entrypoint.sh"]