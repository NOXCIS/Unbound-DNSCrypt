# Unbound Performance Monitoring

## Check Socket Buffer Limits

```bash
# Check current OS limits
sysctl net.core.rmem_max net.core.wmem_max
sysctl net.core.rmem_default net.core.wmem_default

# Check what unbound actually got
docker exec <container> cat /proc/sys/net/core/rmem_max
```

## Monitor Unbound Statistics

```bash
# View unbound statistics (requires unbound-control)
docker exec <container> unbound-control stats

# Key metrics to watch:
# - num.query.ratelimited - queries dropped due to rate limiting
# - num.query.dropped - queries dropped
# - total.num.queries - total query count
# - total.requestlist.avg - average requests in queue
```

## Check for Packet Loss

```bash
# Monitor unbound logs for:
# - "socket buffer truncated"
# - "packet buffer overflow"
# - High latency during traffic spikes

# Check network interface statistics
docker exec <container> cat /proc/net/sockstat
```

## When to Increase Buffers

**Signs you need larger buffers:**
- Sustained query rates >10,000/second
- Log messages about buffer truncation
- Increased query latency during traffic spikes
- High `num.query.dropped` statistics
- Network monitoring shows UDP receive errors

**To increase buffers in Docker:**

The current setup has `NET_ADMIN` capability and requests 4MB buffers. However:

- **On Linux hosts**: You can set sysctls to allow larger buffers:
  ```yaml
  sysctls:
    - net.core.rmem_max=8388608  # 8MB
    - net.core.wmem_max=8388608
  ```
  
- **On macOS Docker Desktop**: Sysctls cannot be set via docker-compose. 
  The warnings are harmless - ~425KB buffers are sufficient for most use cases.
  To eliminate warnings on macOS, set buffers to 0 (system defaults) in unbound.conf.

- **Current config**: Uses 4MB buffers with `NET_ADMIN` capability
  - Warnings on macOS Docker Desktop are expected and harmless
  - Full 4MB available on Linux hosts with appropriate sysctls

## Typical Scenarios

| Scenario | Default (0) | Large (4MB) |
|----------|-------------|-------------|
| Home network (1-10 devices) | ✅ Sufficient | Overkill |
| Small office (10-50 devices) | ✅ Usually OK | Consider if issues |
| Medium office (50-200 devices) | ⚠️ Monitor | Recommended |
| Large network (200+ devices) | ❌ Likely insufficient | ✅ Recommended |
| High query rate (>10k/sec) | ❌ Likely insufficient | ✅ Recommended |
| DDoS protection service | ⚠️ Depends | ✅ Recommended |

