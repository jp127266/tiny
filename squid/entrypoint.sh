#!/bin/sh
set -e

CACHE_DIR=/var/cache/squid
SSL_DB=/var/lib/squid/ssl_db

# Make sure squid owns its writable dirs (they come from named volumes).
chown -R squid:squid "$CACHE_DIR" "$(dirname "$SSL_DB")" /var/log/squid 2>/dev/null || true

# Initialize the on-disk object cache on first run.
if [ ! -d "$CACHE_DIR/00" ]; then
    echo "entrypoint: initializing cache_dir at $CACHE_DIR"
    squid -z --foreground -f /etc/squid/squid.conf
fi

# Initialize the SSL certificate database used to mint per-site certs.
if [ ! -d "$SSL_DB" ]; then
    echo "entrypoint: initializing SSL cert db at $SSL_DB"
    /usr/lib/squid/security_file_certgen -c -s "$SSL_DB" -M 4MB
    chown -R squid:squid "$SSL_DB"
fi

# Remove a stale PID file left behind by an unclean stop (e.g. docker restart),
# otherwise squid aborts with "Squid is already running".
rm -f /run/squid.pid /var/run/squid.pid

echo "entrypoint: starting squid"
exec squid --foreground -f /etc/squid/squid.conf
