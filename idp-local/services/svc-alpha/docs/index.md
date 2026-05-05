# Service Alpha

Primary IDP demo service. Demonstrates canary rollout (v1 → v2) and API versioning lifecycle.

## Overview

| Property | Value |
|---|---|
| Owner | platform-team |
| Language | Node.js 20 (Express) |
| Port | 3000 |
| Namespace | svc-alpha |
| Depends on | [svc-beta](../svc-beta/) |

## API Versions

### v1 — Deprecated

```
GET /v1/hello
```

**Response:**
```json
{
  "version": "v1",
  "service": "svc-alpha",
  "message": "Hello from v1"
}
```

v1 is in **deprecated** state. Migrate to v2. The `Sunset` header (RFC 8594) is returned on every v1 response indicating the planned removal date.

### v2 — Production

```
GET /v2/hello
```

**Response:**
```json
{
  "version": "v2",
  "service": "svc-alpha",
  "message": "Hello from v2",
  "timestamp": "2026-05-05T12:00:00.000Z",
  "requestId": "550e8400-e29b-41d4-a716-446655440000",
  "downstream": "http://svc-beta.svc-beta.svc.cluster.local:3000"
}
```

v2 adds `timestamp` and `requestId` fields. The `downstream` field shows the svc-beta dependency URL.

## Canary Rollout

This service uses Argo Rollouts with a canary strategy:

| Step | Traffic to v2 | Action |
|---|---|---|
| 1 | 20% | Pause — inspect Grafana dashboard |
| 2 | 50% | Pause — verify AnalysisTemplate success rate ≥ 95% |
| 3 | 100% | Full promotion |

To trigger a rollout:
```bash
helm upgrade svc-alpha charts/svc-alpha \
  --set image.tag=v2 --namespace svc-alpha
```

To promote:
```bash
kubectl argo rollouts promote svc-alpha -n svc-alpha
```

To simulate failure and trigger auto-rollback:
```bash
for i in {1..50}; do
  curl -s "http://localhost/svc-alpha/v2/hello?fail=true"
done
```

## Observability

- Metrics: `http://localhost/svc-alpha/metrics` (Prometheus format)
- Grafana: `http://localhost/grafana` → IDP Services dashboard
- Health: `http://localhost/svc-alpha/health`
