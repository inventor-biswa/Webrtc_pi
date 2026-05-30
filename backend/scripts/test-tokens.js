const { setTimeout: delay } = require('timers/promises');

function parseArgs(argv) {
  const args = { baseUrl: 'http://localhost:5000', deviceId: 'pi-1', patientId: 'pi-1' };
  for (let i = 2; i < argv.length; i += 1) {
    const part = argv[i];
    if (part === '--baseUrl') args.baseUrl = argv[i + 1];
    if (part === '--deviceId') args.deviceId = argv[i + 1];
    if (part === '--patientId') args.patientId = argv[i + 1];
  }
  return args;
}

async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status} ${res.statusText}: ${text}`);
  }
  return res.json();
}

async function withRetry(fn, attempts = 10, waitMs = 500) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      await delay(waitMs);
    }
  }
  throw lastErr;
}

async function main() {
  const { baseUrl, deviceId, patientId } = parseArgs(process.argv);
  const edgeUrl = `${baseUrl}/api/edge/token?deviceId=${encodeURIComponent(deviceId)}`;
  const viewerUrl = `${baseUrl}/api/viewer/token?patientId=${encodeURIComponent(patientId)}`;

  const edge = await withRetry(() => fetchJson(edgeUrl));
  const viewer = await fetchJson(viewerUrl);

  console.log('edge:', { room: edge.room, token: edge.token ? 'ok' : 'missing' });
  console.log('viewer:', { token: viewer.token ? 'ok' : 'missing' });
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
