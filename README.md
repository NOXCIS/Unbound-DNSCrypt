# Unbound-DNSCrypt

A production-ready Docker container combining **Unbound** (recursive, validating DNS resolver) with **dnscrypt-proxy** (encrypted DNS proxy) in a single, minimal `scratch`-based image.

## Overview

This project provides a unified DNS solution that:
- **Unbound** (port 53) - Recursive DNS resolver with DNSSEC validation, caching, and advanced features
- **dnscrypt-proxy** (port 5053) - Encrypted DNS proxy supporting DNSCrypt and DoH
- Both services run in a single container with proper health checks and graceful shutdown

### Architecture

```
┌─────────────────────────────────────────┐
│         Unbound (Port 53)              │
│  ┌──────────────────────────────────┐  │
│  │  DNSSEC Validation               │  │
│  │  Recursive Resolution            │  │
│  │  Response Caching (512MB)       │  │
│  └──────────┬───────────────────────┘  │
│             │ Forwards to              │
│             ▼                           │
│  ┌──────────────────────────────────┐  │
│  │  dnscrypt-proxy (Port 5053)      │  │
│  │  - DNSCrypt/DoH Encryption       │  │
│  │  - Server Selection              │  │
│  │  - Response Caching              │  │
│  └──────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

## Features

### Unbound
- ✅ DNSSEC validation and enforcement
- ✅ Aggressive NSEC/NSEC3 caching
- ✅ 512MB response cache with prefetching
- ✅ Support for EDNS Client Subnet (ECS)
- ✅ CacheDB Redis support (optional)
- ✅ Private domain resolution
- ✅ Custom A/AAAA record overrides

### dnscrypt-proxy
- ✅ DNSCrypt and DNS-over-HTTPS (DoH) support
- ✅ Automatic server selection from public resolvers
- ✅ Response caching (4,200 entries)
- ✅ Ephemeral keys for enhanced privacy
- ✅ No-log and no-filter server filtering

### Container
- ✅ Minimal `scratch` base image (~15MB compressed)
- ✅ Multi-stage build for optimal size
- ✅ Non-root execution (`nonroot` user)
- ✅ Health checks for both services
- ✅ Graceful shutdown handling
- ✅ Volume-mounted configuration files

## Quick Start

### Prerequisites
- Docker with BuildKit support
- Docker Compose v2+

### Basic Usage

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd Unbound-DNSCrypt
   ```

2. **Start the service:**
   ```bash
   docker compose up -d
   ```

3. **Test DNS resolution:**
   ```bash
   # Test via Unbound (port 53)
   dig @127.0.0.1 cloudflare.com +dnssec
   
   # Test via dnscrypt-proxy directly (port 5053)
   dig @127.0.0.1 -p 5053 cloudflare.com
   ```

4. **Check service status:**
   ```bash
   docker compose ps
   # Look for "healthy" status
   
   # View logs
   docker compose logs -f server
   ```

## Configuration

### Volume Mounts

The container expects configuration files to be mounted from the host:

```yaml
volumes:
  - ./configs/dnscrypt-unbound/dnscrypt-proxy.toml:/config/dnscrypt-proxy.toml:ro
  - ./configs/dnscrypt-unbound/unbound.conf:/etc/unbound/unbound.conf:ro
  - ./configs/dnscrypt-unbound/custom.conf.d:/etc/unbound/custom.conf.d:ro
```

### Configuration Files

#### `dnscrypt-proxy.toml`
Configure DNS encryption, server selection, and caching:
- `listen_addresses` - Where dnscrypt-proxy listens (default: `0.0.0.0:5053`)
- `require_nolog` - Only use no-log servers (default: `true`)
- `require_nofilter` - Filter out servers that filter content
- `cache_size` - Response cache size (default: 4200)
- `[sources]` - Resolver list sources (public-resolvers, cs-resolvers, etc.)

#### `unbound.conf`
Configure recursive resolution, DNSSEC, and caching:
- `server:` section - Main Unbound configuration
  - `interface` - Listen address (default: `0.0.0.0`)
  - `do-ip4`, `do-ip6`, `do-udp`, `do-tcp` - Protocol options
  - `msg-cache-size`, `rrset-cache-size` - Cache sizes (default: 512m each)
  - `root-hints` - Path to root hints file
  - `auto-trust-anchor-file` - Path to root key for DNSSEC
- `forward-zone:` - Forward all queries to dnscrypt-proxy at `127.0.0.1:5053`

#### `custom.conf.d/`
Optional configuration snippets:
- `a-records.conf.example` - Custom A/AAAA record overrides
- `private-domains.conf` - Private domain resolution (e.g., `.local`)
- `cachedb.conf.example` - Redis CacheDB configuration
- `remote-control.conf.example` - Unbound remote control
- `send-client-subnet.conf.example` - ECS configuration

### Required Capabilities

The container requires:
- `NET_BIND_SERVICE` - Bind to privileged ports (53)
- `NET_ADMIN` - Set socket buffer sizes (for optimal performance)

## Testing

Run the comprehensive test suite:

```bash
docker compose -f docker-compose-test.yaml up --build --abort-on-container-exit
```

The test suite verifies:
- ✅ Both services start correctly
- ✅ Unbound version and configuration validation
- ✅ DNSSEC validation (sigok.verteiltesysteme.net)
- ✅ DNSSEC failure detection (sigfail.verteiltesysteme.net)
- ✅ Unbound forwarding to dnscrypt-proxy
- ✅ Response caching functionality
- ✅ Service health checks

## Monitoring

See [MONITORING.md](MONITORING.md) for detailed monitoring guidance.

### Quick Health Check

```bash
# Check container health status
docker compose ps

# Check service logs
docker compose logs server | grep -E "(unbound|dnscrypt)"

# Test DNS resolution manually
dig @127.0.0.1 cloudflare.com +dnssec

# Check Unbound statistics (if remote-control enabled)
docker exec <container> unbound-control stats
```

### Health Check Binary

The container includes a custom health check binary (`/usr/local/bin/healthcheck`) that:
- Queries `cloudflare.com` via Unbound on port 53
- Queries `cloudflare.com` via dnscrypt-proxy on port 5053
- Returns exit code 0 if both succeed, 1 otherwise

## Architecture Details

### Build Stages

The Dockerfile uses multi-stage builds:

1. **build-base** - Alpine with build dependencies
2. **ldns** - Builds LDNS library (provides `drill`, `dig`)
3. **unbound** - Builds Unbound with DNSCrypt, subnet, CacheDB, TFO support
4. **root-hints** - Downloads root hints file
5. **root-key** - Generates DNSSEC root anchor
6. **unbound-config** - Processes Unbound configuration
7. **dnscrypt-build** - Builds dnscrypt-proxy
8. **probe** - Builds dnsprobe tool
9. **launcher** - Builds Go launcher for process management
10. **healthcheck** - Builds health check binary
11. **final** - Assembles minimal `scratch` image

### Process Management

The container uses a custom Go launcher (`/usr/local/bin/launcher`) that:
- Starts both `dnscrypt-proxy` and `unbound` concurrently
- Monitors both processes
- Handles termination signals (SIGTERM, SIGINT)
- Gracefully shuts down both services when one exits

## Troubleshooting

### Common Issues

#### Unbound warnings about socket buffer sizes
```
warning: so-rcvbuf 4194304 was not granted. Got 425984.
```

**Solution:** This is expected on macOS Docker Desktop where kernel limits are lower. The warnings are harmless. On Linux hosts, you can increase limits with `sysctls` in `compose.yaml`:

```yaml
sysctls:
  - net.core.rmem_max=8388608
  - net.core.wmem_max=8388608
```

#### "user 'unbound' does not exist" error
**Solution:** Ensure `username: ""` is set in `unbound.conf` since the container runs as `nonroot` user.

#### "do-not-query-localhost: yes" warning
**Solution:** Set `do-not-query-localhost: no` in `unbound.conf` to allow forwarding to `127.0.0.1:5053`.

#### Health check failures
**Solution:** Ensure both services are running and responding:
```bash
# Check logs
docker compose logs server

# Test manually
docker exec <container> /usr/local/bin/healthcheck
```

### Debugging

```bash
# Enter the container
docker compose exec server sh

# Check Unbound configuration
/usr/sbin/unbound-checkconf /etc/unbound/unbound.conf

# View Unbound version
/usr/sbin/unbound -V

# Test DNS resolution from inside container
drill @127.0.0.1 cloudflare.com
drill @127.0.0.1 -p 5053 cloudflare.com

# Check process status
ps aux
```

## Performance Considerations

### Socket Buffer Sizes

Unbound is configured with 4MB socket buffers for high-performance scenarios. See [MONITORING.md](MONITORING.md) for:
- When to increase buffer sizes
- How to monitor packet loss
- Platform-specific limitations (macOS Docker Desktop)

### Cache Sizes

- **Unbound**: 512MB message cache, 512MB rrset cache
- **dnscrypt-proxy**: 4,200 entry cache

Adjust based on your workload and available memory.

## Security

- ✅ Runs as non-root user (`nonroot`, UID 65532)
- ✅ Read-only configuration mounts
- ✅ Minimal attack surface (`scratch` base image)
- ✅ DNSSEC validation enabled and enforced
- ✅ No-log DNS servers preferred
- ✅ Ephemeral keys for DNSCrypt connections

## License

See [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please ensure:
- All tests pass (`docker compose -f docker-compose-test.yaml up`)
- Code follows existing style
- New features include appropriate tests

## References

- [Unbound Documentation](https://unbound.docs.nlnetlabs.nl/)
- [dnscrypt-proxy Documentation](https://github.com/DNSCrypt/dnscrypt-proxy/wiki)
- [DNSSEC Test Domains](https://www.isc.org/dnssec-test-zone/)
- [Public DNSCrypt Resolvers](https://github.com/DNSCrypt/dnscrypt-resolvers)
