const express = require('express');
const helmet = require('helmet');
const { registry, metricsMiddleware } = require('./metrics');

const app = express();
const VERSION = process.env.VERSION || 'v1';

app.use(helmet());
app.use(metricsMiddleware(VERSION));

app.get('/health', (req, res) =>
  res.json({ status: 'ok', service: 'svc-beta', version: VERSION }),
);

app.get('/metrics', async (req, res, next) => {
  try {
    res.set('Content-Type', registry.contentType);
    res.end(await registry.metrics());
  } catch (err) {
    next(err);
  }
});

app.use('/v1', require('./routes/v1'));
app.use('/v2', require('./routes/v2'));

app.use((err, _req, res, _next) => {
  console.error(err.stack);
  res.status(500).json({ error: 'internal server error' });
});

module.exports = app;
