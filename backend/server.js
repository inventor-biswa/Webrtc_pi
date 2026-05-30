const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '.env') });

const express = require('express');
const cors = require('cors');
const { AccessToken, RoomServiceClient } = require('livekit-server-sdk');

const LIVEKIT_API_KEY    = process.env.LIVEKIT_API_KEY    || 'devkey';
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET || 'secret_secret_key_12345';
const LIVEKIT_URL        = process.env.LIVEKIT_URL        || 'http://localhost:7880';
// WebSocket URL exposed to browser viewers (ws:// or wss:// for production)
const LIVEKIT_WS_URL     = process.env.LIVEKIT_WS_URL     || 'ws://localhost:7880';

const app = express();
app.use(cors());
app.use(express.json());

// LiveKit Room Service client (server-to-server REST API)
const roomService = new RoomServiceClient(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);

// ─── Token helpers ───────────────────────────────────────────
async function createToken(identity, roomName, canPublish, canSubscribe) {
  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, { identity });
  at.addGrant({
    room: roomName,
    roomJoin: true,
    canPublish: !!canPublish,
    canSubscribe: !!canSubscribe,
  });
  return await at.toJwt();
}

// ─── Pi publisher token ──────────────────────────────────────
// GET /api/edge/token?deviceId=pi-patient-01
app.get('/api/edge/token', async (req, res) => {
  const deviceId  = req.query.deviceId || 'unknown';
  const roomName  = `room-${deviceId}`;
  const identity  = `edge-${deviceId}`;
  const token     = await createToken(identity, roomName, true, false);
  res.json({ token, room: roomName });
});

// ─── Viewer token ────────────────────────────────────────────
// GET /api/viewer/token?patientId=pi-patient-01
app.get('/api/viewer/token', async (req, res) => {
  const patientId = req.query.patientId || 'unknown';
  const roomName  = `room-${patientId}`;
  const identity  = `viewer-${Date.now()}-${patientId}`;
  const token     = await createToken(identity, roomName, false, true);
  res.json({ token, room: roomName, livekitUrl: LIVEKIT_WS_URL });
});

// ─── List active rooms ────────────────────────────────────────
// GET /api/rooms
// Returns all active LiveKit rooms with participant counts.
app.get('/api/rooms', async (req, res) => {
  try {
    const rooms = await roomService.listRooms();
    const result = rooms.map((r) => ({
      name:            r.name,
      numParticipants: r.numParticipants,
      numPublishers:   r.numPublishers,
      creationTime:    r.creationTime ? Number(r.creationTime) : null,
      // Derive deviceId from room name convention "room-{deviceId}"
      deviceId: r.name.startsWith('room-') ? r.name.slice(5) : r.name,
    }));
    res.json(result);
  } catch (err) {
    console.error('listRooms error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── LiveKit WebSocket URL for browser clients ────────────────
// GET /api/config
app.get('/api/config', (req, res) => {
  res.json({ livekitUrl: LIVEKIT_WS_URL });
});

// ─── Health check ────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', ts: Date.now() }));

// ─── Serve frontend static files ─────────────────────────────
const FRONTEND_DIR = path.join(__dirname, '..', 'frontend');
app.use(express.static(FRONTEND_DIR));

const PORT = Number.parseInt(process.env.PORT, 10) || 5001;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`\n  ✅ Backend listening on http://0.0.0.0:${PORT}`);
  console.log(`  🔗 LiveKit server: ${LIVEKIT_URL}`);
  console.log(`  🌐 LiveKit WS URL (for browsers): ${LIVEKIT_WS_URL}`);
  console.log(`  📡 Endpoints:`);
  console.log(`       GET /api/edge/token?deviceId=<id>    (Pi publisher)`);
  console.log(`       GET /api/viewer/token?patientId=<id> (Browser viewer)`);
  console.log(`       GET /api/rooms                        (List active streams)`);
  console.log(`       GET /api/config                       (LiveKit config for frontend)\n`);
});
