# Alpine's squid package is built --with-openssl and ships security_file_certgen,
# which the Ubuntu build lacks — required for SSL-bump.
FROM alpine:3.20

RUN apk add --no-cache squid openssl

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
