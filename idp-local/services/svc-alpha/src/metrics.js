const client = require('prom-client');

const registry = new client.Registry();
client.collectDefaultMetrics({ register: registry });

const requestCounter = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['service', 'version', 'method', 'status'],
  registers: [registry],
});

const requestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['service', 'version'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
  registers: [registry],
});

function metricsMiddleware(version) {
  return (req, res, next) => {
    if (req.path === '/metrics' || req.path === '/health') return next();
    const end = requestDuration.startTimer({ service: 'svc-alpha', version });
    res.on('finish', () => {
      end();
      requestCounter.inc({
        service: 'svc-alpha',
        version,
        method: req.method,
        status: String(res.statusCode),
      });
    });
    next();
  };
}

module.exports = { registry, metricsMiddleware };
