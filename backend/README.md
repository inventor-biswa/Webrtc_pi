# WEBRTC Backend

This backend issues LiveKit tokens for Pi (publisher) and doctor (viewer).

## Requirements
- Node.js 18+ (Node 22 is fine)
- Docker (only if you want local LiveKit server)

## Setup
1) Install dependencies:

```powershell
cd .\backend
npm install
```

2) Create .env from the example:

```powershell
Copy-Item .env.example .env
```

## Run Backend
```powershell
npm start
```

## Start LiveKit Locally (Docker)
```powershell
docker run --rm ^
  -p 7880:7880 -p 7881:7881 -p 7882:7882/udp ^
  -v "C:\Users\deepa\OneDrive\Desktop\WEBRTC\backend\livekit.yaml:/livekit.yaml" ^
  livekit/livekit-server:v1.6 --config /livekit.yaml
```

## Token Endpoints
- Pi (publisher):
  - `GET /api/edge/token?deviceId=PATIENT_ID`
- Doctor (viewer):
  - `GET /api/viewer/token?patientId=PATIENT_ID`

## Local Smoke Test
Start the backend, then run:

```powershell
npm run test:tokens -- --baseUrl http://localhost:5000 --deviceId pi-1 --patientId pi-1
```
