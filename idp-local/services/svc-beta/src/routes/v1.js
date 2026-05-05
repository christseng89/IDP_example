const { Router } = require('express');
const router = Router();

router.get('/hello', (req, res) => {
  if (req.query.fail === 'true') {
    return res.status(500).json({ error: 'simulated failure' });
  }
  res.json({
    version: 'v1',
    service: 'svc-beta',
    message: 'Hello from v1',
  });
});

module.exports = router;
