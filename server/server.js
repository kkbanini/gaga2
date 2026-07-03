/*
 * Tank Arena — real-time multiplayer relay server
 * ------------------------------------------------
 * A small authoritative-relay WebSocket server for the Tank Arena game
 * (docs/game.html). Each client is authoritative over its own tank; the server
 * relays state, fire events, and player lists to everyone, and balances the two
 * teams on join. One global arena/room.
 *
 * Protocol (JSON text frames)
 *   client -> server:
 *     { t:"join",  name, team, mode, cls, level }
 *     { t:"state", x, y, a, cls, hp, maxHp, level, score, team, name }   (~20Hz)
 *     { t:"fire",  id, x, y, a, cls, team, spd, dmg, r }
 *   server -> client:
 *     { t:"welcome", id, team }                     // team may be reassigned for balance
 *     { t:"players", list:[ {id,x,y,a,cls,hp,maxHp,level,team,name,score} ] }  (~15Hz)
 *     { t:"fire",   ... }                           // relayed to everyone else
 *     { t:"leave",  id }
 *
 * Run:  npm install && npm start   (listens on process.env.PORT, default 8080)
 */
"use strict";

const http = require("http");
const { WebSocketServer } = require("ws");

const PORT = process.env.PORT || 8080;
const TICK_HZ = 15;                 // player-list broadcast rate
const MAX_PLAYERS = 100;            // hard cap for one arena

// Tiny HTTP server so hosts (Render/Fly/Railway) have a health check + open port.
const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("Tank Arena server OK — " + players.size + " players online\n");
});

const wss = new WebSocketServer({ server });
const players = new Map(); // ws -> state object
let idSeq = 1;

function nextId() { return "p" + (idSeq++); }

// Assign a team that keeps 2-Teams mode balanced: honor the request unless it
// would overpopulate that side, otherwise place on the smaller team.
function assignTeam(requested) {
  let red = 0, blue = 0;
  for (const p of players.values()) {
    if (p.mode === "teams") { if (p.team === "red") red++; else if (p.team === "blue") blue++; }
  }
  if (requested === "red" && red > blue) return "blue";
  if (requested === "blue" && blue > red) return "red";
  if (requested === "red" || requested === "blue") return requested;
  return red <= blue ? "red" : "blue";
}

function send(ws, obj) {
  if (ws.readyState === ws.OPEN) { try { ws.send(JSON.stringify(obj)); } catch (e) {} }
}
function broadcast(obj, exceptWs) {
  const msg = JSON.stringify(obj);
  for (const ws of players.keys()) {
    if (ws === exceptWs) continue;
    if (ws.readyState === ws.OPEN) { try { ws.send(msg); } catch (e) {} }
  }
}

wss.on("connection", (ws) => {
  if (players.size >= MAX_PLAYERS) { try { ws.close(); } catch (e) {} return; }
  const p = {
    id: nextId(), name: "player", team: "ffa", mode: "ffa",
    x: 3000, y: 3000, a: 0, cls: null, hp: 100, maxHp: 100, level: 1, score: 0,
    joined: false
  };
  players.set(ws, p);
  ws.isAlive = true;
  ws.on("pong", () => { ws.isAlive = true; });

  ws.on("message", (raw) => {
    let m;
    try { m = JSON.parse(raw.toString()); } catch (e) { return; }
    if (m.t === "join") {
      p.name = ("" + (m.name || "player")).slice(0, 16);
      p.mode = m.mode === "teams" ? "teams" : "ffa";
      p.team = p.mode === "teams" ? assignTeam(m.team) : "ffa";
      p.cls = m.cls || null;
      p.level = m.level || 1;
      p.joined = true;
      send(ws, { t: "welcome", id: p.id, team: p.team });
    } else if (m.t === "state") {
      if (typeof m.x === "number") p.x = m.x;
      if (typeof m.y === "number") p.y = m.y;
      if (typeof m.a === "number") p.a = m.a;
      p.cls = m.cls || null;
      if (typeof m.hp === "number") p.hp = m.hp;
      if (typeof m.maxHp === "number") p.maxHp = m.maxHp;
      if (typeof m.level === "number") p.level = m.level;
      if (typeof m.score === "number") p.score = m.score;
      if (m.team) p.team = m.team === "red" || m.team === "blue" ? m.team : p.team;
      if (m.name) p.name = ("" + m.name).slice(0, 16);
    } else if (m.t === "fire") {
      // Relay the shot to everyone else, stamped with the shooter's id/team.
      broadcast({ t: "fire", id: p.id, x: m.x, y: m.y, a: m.a, cls: m.cls,
                  team: p.team, spd: m.spd, dmg: m.dmg, r: m.r }, ws);
    }
  });

  const close = () => {
    if (players.has(ws)) {
      const id = players.get(ws).id;
      players.delete(ws);
      broadcast({ t: "leave", id: id });
    }
  };
  ws.on("close", close);
  ws.on("error", close);
});

// Broadcast the authoritative player list at a fixed tick.
setInterval(() => {
  const list = [];
  for (const p of players.values()) {
    if (!p.joined) continue;
    list.push({ id: p.id, x: p.x, y: p.y, a: p.a, cls: p.cls, hp: p.hp,
                maxHp: p.maxHp, level: p.level, team: p.team, name: p.name, score: p.score });
  }
  broadcast({ t: "players", list: list });
}, Math.round(1000 / TICK_HZ));

// Drop dead connections (no pong within the interval).
setInterval(() => {
  for (const ws of players.keys()) {
    if (ws.isAlive === false) { try { ws.terminate(); } catch (e) {} continue; }
    ws.isAlive = false;
    try { ws.ping(); } catch (e) {}
  }
}, 30000);

server.listen(PORT, () => {
  console.log("Tank Arena multiplayer server listening on port " + PORT);
});
