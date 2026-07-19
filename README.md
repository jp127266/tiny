# Squid Forward Caching Proxy (with SSL-bump)

A Dockerized [Squid](http://www.squid-cache.org/) **forward (web) proxy** with a
4 GB on-disk cache and HTTPS interception (SSL-bump) so that HTTPS responses can
be cached too. Point a browser or another machine at it on port **7080** and it
fetches the internet on their behalf, caching what it can.

> **Forward proxy, not reverse proxy.** This is the kind of proxy you set in a
> browser's connection settings — it fetches arbitrary sites for clients. It is
> *not* a reverse proxy that fronts one backend server.

---

## Features

- **Forward proxy on port 7080**, exposed on all interfaces (reachable from other machines).
- **HTTPS tunneling** via the `CONNECT` method.
- **SSL-bump**: decrypts HTTPS so responses are cacheable (needs a trusted CA — see below).
- **Selective splicing**: cert-pinned / session-bound sites (Mozilla, Google, …) bypass decryption.
- **Caching tuned for performance**: 4 GB `aufs` disk cache + 8 GB in-memory hot cache, heap eviction, request collapsing.
- **LAN-scoped access control** by default (private ranges + localhost).
- Self-initializing cache and cert DB; survives `docker compose restart`.

---

## Architecture

```
                         ┌──────────────────────────────────────────┐
  Browser / client       │  squid-forward-proxy (container)          │
  (proxy = host:7080) ───┼─▶ http_port 7080 ssl-bump                 │
                         │     │                                      │
                         │     ├─ peek SNI ─▶ in nobump.acl? ──┐      │
                         │     │                               │      │
                         │     │   no → BUMP (decrypt,         │ yes  │
                         │     │          cache, re-encrypt)   ▼      │
                         │     │                            SPLICE    │
                         │     ▼                          (pass-thru) │
                         │   cache:  8 GB RAM  +  4 GB disk (aufs)    │
                         └──────────────────────┬───────────────────-┘
                                                ▼
                                            Internet
```

- **Bumped** traffic: Squid presents a certificate signed by the local CA, decrypts,
  caches cacheable responses, then re-encrypts to the client.
- **Spliced** traffic (domains in `nobump.acl`): TLS passes through end-to-end,
  untouched — required for sites that pin certs or bind sessions to the connection.

---

## Project structure

```
.
├── docker-compose.yml        # service, port 7080, volumes, ulimits, healthcheck
├── README.md
└── squid/
    ├── Dockerfile            # Alpine + squid (built --with-openssl) + openssl
    ├── entrypoint.sh         # inits cache + SSL cert DB, clears stale PID, starts squid
    ├── squid.conf            # main config: ssl-bump, ACLs, caching
    ├── nobump.acl            # domains to splice (bypass decryption)
    └── ssl/                  # local CA used for SSL-bump
        ├── ca.crt            # import THIS into client browsers
        └── ca.key            # PRIVATE KEY — keep secret, never commit/share
```

---

## Prerequisites

- Docker + Docker Compose v2
- `openssl` on the host (only to generate the CA, if not already present)

---

## Quick start

### 1. Generate the SSL-bump CA (first time only)

Required for HTTPS interception. Skip if `squid/ssl/ca.crt` and `ca.key` already exist.

```sh
mkdir -p squid/ssl
openssl req -new -newkey rsa:2048 -sha256 -days 3650 -nodes -x509 \
  -keyout squid/ssl/ca.key -out squid/ssl/ca.crt \
  -subj "/C=US/O=Squid SSL-Bump/CN=Squid SSL-Bump CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
chmod 600 squid/ssl/ca.key
chmod 644 squid/ssl/ca.crt
```

### 2. Build and start

```sh
docker compose up -d --build
```

Check it's healthy:

```sh
docker compose ps
```

### 3. Test

```sh
# Plain HTTP through the proxy
curl -x http://localhost:7080 http://example.com/

# HTTPS (bumped) — trust the local CA
curl -x http://localhost:7080 --cacert squid/ssl/ca.crt https://example.com/
```

---

## Client setup

### Configure the proxy

Point the client at `HOST:7080` for both HTTP and HTTPS, where `HOST` is
`localhost` on the proxy machine or its LAN IP from another machine.

**Firefox:** Settings → *Network Settings* → **Manual proxy configuration** →
HTTP Proxy `HOST`, Port `7080`, check **"Also use this proxy for HTTPS"**.

### Import the CA (required for HTTPS)

Without this, bumped HTTPS sites fail with `SEC_ERROR_UNKNOWN_ISSUER`. Copy
`squid/ssl/ca.crt` to the client machine, then:

**Firefox:** Settings → Privacy & Security → Certificates → **View Certificates…**
→ *Authorities* tab → **Import…** → select `ca.crt` → check
**"Trust this CA to identify websites"** → OK.

> Firefox uses its own certificate store. Other browsers (Chrome/Safari/Edge) use
> the OS trust store — import the CA there instead.

---

## Configuration reference

### Caching ([squid/squid.conf](squid/squid.conf))

| Setting | Value | Notes |
|---|---|---|
| `cache_dir aufs … 4096` | **4 GB disk cap** | `aufs` = threaded async I/O (good on HDDs) |
| `cache_mem` | **8 GB** | In-RAM hot-object cache, separate from the disk cap |
| `maximum_object_size` | 512 MB | Largest cacheable object |
| `maximum_object_size_in_memory` | 16 MB | Largest object kept in RAM |
| `cache_replacement_policy` | heap LFUDA | Maximizes byte hit-ratio on disk |
| `memory_replacement_policy` | heap GDSF | Favors small popular objects in RAM |
| `collapsed_forwarding` | on | Dedupes concurrent identical fetches |

### Access control

By default only **localhost** and **private LAN ranges** (`10/8`, `172.16/12`,
`192.168/16`, IPv6 ULA/link-local) may use the proxy. To allow any client (an
**open proxy** — only safe if this host is not reachable from the public
internet), replace the `http_access` rules in `squid.conf` with:

```
http_access allow all
```

### Splice list ([squid/nobump.acl](squid/nobump.acl))

Domains listed here are **spliced** (passed through without decryption) instead
of bumped. Use it for sites that break under interception — those that pin
certificates or bind login sessions to the TLS connection. One domain per line;
a leading dot matches subdomains. Pre-seeded with Mozilla and Google domains.

> **Why Google is here:** Google rotates and binds session cookies to the secure
> connection (`RotateCookies`). Under SSL-bump the browser's TLS channel differs
> from Google's, so Google invalidates the session — you get logged out on every
> launch. Splicing fixes it with no cache loss (auth traffic is `no-store` anyway).

After editing, apply with `docker compose restart squid`.

---

## Operations

```sh
# Logs
docker compose logs -f squid
docker exec squid-forward-proxy tail -f /var/log/squid/access.log

# Validate config before applying
docker exec squid-forward-proxy squid -k parse

# Apply config / nobump.acl changes (mounted files)
docker compose restart squid

# Apply Dockerfile / entrypoint changes
docker compose up -d --build

# Stop / remove (named volumes persist the cache + cert DB)
docker compose down

# Wipe the cache entirely
docker compose down && docker volume rm tiny_squid-cache
```

Access-log cache markers worth knowing: `TCP_MISS` (fetched from origin),
`TCP_MEM_HIT` (served from RAM), `TCP_HIT` (served from disk), `TCP_TUNNEL`
(spliced/opaque HTTPS — not cached).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `SEC_ERROR_UNKNOWN_ISSUER` in browser | CA not trusted | Import `squid/ssl/ca.crt` (see Client setup) |
| Logged out of a site every launch | SSL-bump breaks its session/cert binding | Add the domain to `nobump.acl`, restart |
| `CONNECT … 400` for HTTPS | Client used as forward proxy against a non-forward proxy | N/A here — this *is* a forward proxy; ensure proxy host/port are right |
| `Squid is already running` after restart | Stale PID file | Handled by `entrypoint.sh` (clears it on start) |
| `accept: Too many open files` | FD limit too low | Raised via `ulimits.nofile` in compose (65536) |

---

## Security notes

SSL-bump is a **deliberate man-in-the-middle**:

- Every client must trust the CA — that CA can mint a valid-looking cert for **any** site.
- `squid/ssl/ca.key` can decrypt all bumped traffic. **Keep it private; never commit or share it.** Consider adding `squid/ssl/` to `.gitignore`.
- The proxy decrypts and can log all bumped HTTPS. Don't expose it beyond your trusted network.
- Spliced domains (`nobump.acl`) are **not** decrypted and remain private end-to-end.
