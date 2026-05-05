const { Router } = require('express');
const router = Router();

router.get('/hello', (req, res) => {
  // Simulate failure for demo rollback: ?fail=true
  if (req.query.fail === 'true') {
    return res.status(500).json({ error: 'simulated failure' });
  }
  res.json({
    version: 'v1',
    service: 'svc-alpha',
    message: 'Hello from v1',
  });
});

module.exports = router;
