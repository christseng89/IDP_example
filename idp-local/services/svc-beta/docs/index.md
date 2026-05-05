# Service Beta

Downstream IDP demo service. Consumed by svc-alpha. Demonstrates standalone canary rollout and API versioning.

## Overview

| Property | Value |
|---|---|
| Owner | platform-team |
| Language | Node.js 20 (Express) |
| Port | 3000 |
| Namespace | svc-beta |
| Consumed by | [svc-alpha](../svc-alpha/) |

## API Versions

### v1 — Deprecated

```
GET /v1/hello
```

```json
{ "version": "v1", "service": "svc-beta", "message": "Hello from v1" }
```

### v2 — Production

```
GET /v2/hello
```

```json
{
  "version": "v2",
  "service": "svc-beta",
  "message": "Hello from v2",
  "timestamp": "2026-05-05T12:00:00.000Z",
  "requestId": "550e8400-e29b-41d4-a716-446655440000",
  "capabilities": ["metrics", "health", "versioning"]
}
```

## Canary Rollout

Same canary strategy as svc-alpha: 20% → 50% → 100%, gated by Prometheus AnalysisTemplate.

## Observability

- Metrics: `http://localhost/svc-beta/metrics`
- Health: `http://localhost/svc-beta/health`
