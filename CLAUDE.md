# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Dockerized Squid **forward (web) caching proxy with SSL-bump**, listening on port 7080.
It is infrastructure/configuration, not an application — there is no build step, linter, or
test suite. "Working" is verified by sending traffic through the running proxy.

See [README.md](README.md) for full user-facing docs.

## Common commands

```sh
# Build + start (needed after Dockerfile or entrypoint.sh changes)
docker compose up -d --build

# Apply changes to mounted config files (squid.conf, nobump.acl, ssl/) — NO rebuild
docker compose restart squid

# Validate config before applying (always do this after editing squid.conf)
docker exec squid-forward-proxy squid -k parse

# Logs
docker compose logs -f squid
docker exec squid-forward-proxy tail -f /var/log/squid/access.log

# Verify functionality
curl -x http://localhost:7080 http://example.com/                              # plain HTTP
curl -x http://localhost:7080 --cacert squid/ssl/ca.crt https://example.com/   # bumped HTTPS
```

**Mounted-vs-baked is the key operational distinction:** `squid.conf`, `nobump.acl`, and
`ssl/` are bind-mounted, so a `restart` picks them up. `Dockerfile` and `entrypoint.sh` are
baked into the image, so they require `up -d --build`.

## Architecture

Request flow (`squid/squid.conf`): `peek` the TLS ClientHello at step 1 → if the SNI matches
`squid/nobump.acl`, **splice** (pass TLS through untouched); otherwise **bump** (decrypt,
cache, re-encrypt with a cert signed by the local CA). Bumped responses are cacheable;
spliced connections are opaque (`TCP_TUNNEL`) and invisible in logs.

`squid/nobump.acl` is the primary lever for behavior: any site that pins certificates or
binds login sessions to the TLS connection (Mozilla, Google, many banks, M365) **breaks
under bump** — you get cert errors or get logged out every launch. The fix is always to add
its domain here and restart. This is the single most common change request.

`squid/entrypoint.sh` runs before Squid on every start: initializes the disk cache
(`squid -z`) and SSL cert DB (`security_file_certgen -c`) if missing, and **clears any stale
`squid.pid`** — without that, `docker compose restart` fails with "Squid is already running".

Caching has two independent tiers: a hard **4 GB disk cache** (`cache_dir aufs … 4096`, a firm
requirement — do not raise it) and a separate **8 GB in-memory** hot cache (`cache_mem`).

Access is restricted to localhost + private LAN ranges via `http_access`; widening to all
clients means replacing those rules with `http_access allow all` (open proxy).

## Critical constraints

- **Base image must be Alpine squid**, which is built `--with-openssl` and ships
  `security_file_certgen`. The Ubuntu/Canonical squid image is built `--with-gnutls` and
  **cannot do SSL-bump** (`ssl_bump requires --with-openssl`). Do not switch the base image
  without re-checking OpenSSL + certgen support.
- **SSL-bump requires the local CA** in `squid/ssl/` (`ca.crt` + `ca.key`). It is not
  committed; generate it before first run (command in README). `ca.key` is a secret that can
  decrypt all bumped traffic and mint trusted certs for any site — never commit or share it.
- Clients must import `ca.crt` or every bumped HTTPS site fails with `SEC_ERROR_UNKNOWN_ISSUER`.

## Gotchas

- This is a **forward** proxy (set in a browser's proxy settings), not a reverse proxy. A
  reverse-proxy config cannot serve this use case — browsers send `CONNECT`/absolute-URI
  requests that a fixed-backend reverse proxy rejects (`400`) or misroutes (`404`).
- The Alpine image is minimal: it has `squidclient`, `nc`, `wget`, `openssl`, `sh` — but
  **no `bash`** and **no `curl`**. The healthcheck uses `squidclient`.
