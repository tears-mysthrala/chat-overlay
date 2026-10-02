"use strict";
// Narrow CI bridge: Docker internal networks intentionally do not publish ports.
// Host Chromium reaches only this disposable fixture; the fixture has no egress.
const net = require("node:net");
const target = process.argv[2];
if (net.isIP(target) !== 4) throw new Error("Expected inspected fixture IPv4");
const sockets = new Set();
const server = net.createServer(incoming => {
  if (sockets.size >= 32) return incoming.destroy();
  sockets.add(incoming);
  const upstream = net.createConnection({ host: target, port: 4143 });
  const close = () => { incoming.destroy(); upstream.destroy(); sockets.delete(incoming); };
  incoming.setTimeout(20_000, close);
  upstream.setTimeout(20_000, close);
  incoming.on("error", close).on("close", close);
  upstream.on("error", close).on("close", close);
  incoming.pipe(upstream).pipe(incoming);
});
server.maxConnections = 32;
server.on("error", () => { console.error("Fixture proxy unavailable"); process.exit(1); });
server.listen(4143, "127.0.0.1");
process.on("SIGTERM", () => {
  for (const socket of sockets) socket.destroy();
  server.close(() => process.exit(0));
});
