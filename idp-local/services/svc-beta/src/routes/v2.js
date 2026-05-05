const { Router } = require('express');
const { v4: uuidv4 } = require('uuid');
const router = Router();

router.get('/hello', (req, res) => {
  if (req.query.fail === 'true') {
    return res.status(500).json({ error: 'simulated failure' });
  }
  res.json({
    version: 'v2',
    service: 'svc-beta',
    message: 'Hello from v2',
    timestamp: new Date().toISOString(),
    requestId: uuidv4(),
    capabilities: ['metrics', 'health', 'versioning'],
  });
});

module.exports = router;
