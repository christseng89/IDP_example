const request = require('supertest');

process.env.VERSION = 'v1';
const app = require('./app');

describe('GET /health', () => {
  it('returns 200 with service info', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'ok', service: 'svc-beta' });
  });
});

describe('GET /v1/hello', () => {
  it('returns 200 with version v1', async () => {
    const res = await request(app).get('/v1/hello');
    expect(res.status).toBe(200);
    expect(res.body.version).toBe('v1');
    expect(res.body.service).toBe('svc-beta');
  });

  it('returns 500 when ?fail=true', async () => {
    const res = await request(app).get('/v1/hello?fail=true');
    expect(res.status).toBe(500);
    expect(res.body.error).toBeDefined();
  });
});

describe('GET /v2/hello', () => {
  it('returns 200 with version v2', async () => {
    const res = await request(app).get('/v2/hello');
    expect(res.status).toBe(200);
    expect(res.body.version).toBe('v2');
    expect(res.body.service).toBe('svc-beta');
    expect(res.body.requestId).toBeDefined();
    expect(res.body.capabilities).toContain('metrics');
  });

  it('returns 500 when ?fail=true', async () => {
    const res = await request(app).get('/v2/hello?fail=true');
    expect(res.status).toBe(500);
  });
});

describe('GET /metrics', () => {
  it('returns Prometheus text format', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.text).toContain('http_requests_total');
  });
});

describe('404 handling', () => {
  it('returns 404 for unknown routes', async () => {
    const res = await request(app).get('/nonexistent');
    expect(res.status).toBe(404);
  });
});
