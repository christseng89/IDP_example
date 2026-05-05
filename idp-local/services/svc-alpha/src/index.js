const app = require('./app');

const PORT = process.env.PORT || 3000;

process.on('uncaughtException', (err) => {
  console.error('Uncaught exception:', err);
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  console.error('Unhandled rejection:', reason);
  process.exit(1);
});

app.listen(PORT, () => {
  const version = process.env.VERSION || 'v1';
  console.log(`svc-alpha ${version} listening on :${PORT}`);
});
