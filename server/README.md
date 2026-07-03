# Tank Arena — multiplayer server

A tiny real-time WebSocket relay for the Tank Arena game (`docs/game.html`).
One global arena. Each client is authoritative over its own tank; the server
relays everyone's position/barrels/level/score/team/name, broadcasts fire
events, and balances the two teams as players join.

You only need to run this if you want **online multiplayer with real friends**.
The game plays fine solo with no server.

## Run locally

```bash
cd server
npm install
npm start          # listens on http://localhost:8080  (ws://localhost:8080)
```

Open the game with the server URL injected, e.g. serve `docs/` and load:

```
http://localhost:8000/game.html
```

after setting `window.TANK_NET_URL = "ws://localhost:8080"` (see
"Point the game at your server" below). Two browser tabs = two players.

## Deploy for free

The server is a single `server.js` with one dependency (`ws`). It binds
`process.env.PORT`, so any Node host works. Pick one:

### Render (easiest)

1. Push this repo to GitHub.
2. On <https://render.com> → **New → Web Service** → connect the repo.
3. Settings:
   - **Root Directory:** `server`
   - **Build Command:** `npm install`
   - **Start Command:** `npm start`
   - **Instance Type:** Free
4. Deploy. Render gives you a URL like `https://tank-arena.onrender.com`.
   Your WebSocket URL is the same host with `wss://`:
   `wss://tank-arena.onrender.com`.

> Render's free tier sleeps after ~15 min idle; the first connection after a
> nap takes a few seconds to wake it. Fine for playing with friends.

### Railway

1. <https://railway.app> → **New Project → Deploy from GitHub repo**.
2. Set the service **Root Directory** to `server` (Settings → Source).
3. Railway auto-detects Node, runs `npm install` + `npm start`.
4. Under **Settings → Networking → Generate Domain** to get a public URL.
   Use it as `wss://your-app.up.railway.app`.

### Fly.io

```bash
cd server
fly launch --now        # accept Node defaults; pick a name/region
```

Fly serves the app at `https://<app>.fly.dev`; connect with
`wss://<app>.fly.dev`. (Fly maps 443 → your `PORT` automatically.)

## Point the game at your server

The client reads the server URL from, in order:

1. `window.TANK_NET_URL` — set before the game loads (best for testing):
   ```html
   <script>window.TANK_NET_URL = "wss://your-app.onrender.com";</script>
   ```
2. The `MULTIPLAYER_URL` constant near the top of `docs/game.html`. Replace the
   placeholder with your deployed URL and it connects automatically for
   everyone (including the Android APK after the OTA update ships):
   ```js
   var MULTIPLAYER_URL = "wss://your-app.onrender.com";
   ```

**Always use `wss://` (TLS) in production** — a page served over HTTPS
(GitHub Pages / the APK's cached copy) is blocked from opening an insecure
`ws://` socket. `ws://` is only for `http://localhost` testing.

## Protocol

JSON text frames. See the header comment in `server.js` for the full schema.

| Direction | Message |
| --- | --- |
| client → server | `{t:"join", name, team, mode, cls, level}` |
| client → server | `{t:"state", x, y, a, cls, hp, maxHp, level, score, team, name}` (~20 Hz) |
| client → server | `{t:"fire", id, x, y, a, cls, team, spd, dmg, r}` |
| server → client | `{t:"welcome", id, team}` (team may be reassigned for balance) |
| server → client | `{t:"players", list:[…]}` (~15 Hz) |
| server → client | `{t:"fire", …}` (relayed to everyone else) |
| server → client | `{t:"leave", id}` |
