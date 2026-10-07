"use strict";
// Narrow CI bridge: Docker internal networks intentionally do not publish ports.
// Host Chromium reaches only this disposable fixture; the fixture has no egress.
const net = require("node:net");
const http = require("node:http");
const target = process.argv[2];
if (net.isIP(target) !== 4) throw new Error("Expected inspected fixture IPv4");
const targetPort = Number(process.argv[3] || 4143);
if (!Number.isInteger(targetPort) || targetPort < 1024 || targetPort > 65535) throw new Error("Invalid fixture port");
const sockets = new Set();
const server = http.createServer((incoming, response) => {
  // Synthetic TLS termination only. This localhost HTTP test bridge exercises
  // the explicit trusted-proxy path; it does not verify real TLS.
  const headers = { ...incoming.headers, "x-forwarded-proto": "https", "x-forwarded-for": "127.0.0.1" };
  const upstream = http.request({ host: target, port: targetPort, method: incoming.method, path: incoming.url, headers }, result => {
    response.writeHead(result.statusCode, result.headers);
    result.pipe(response);
  });
  const close = () => { upstream.destroy(); response.destroy(); };
  incoming.on("aborted", close);
  response.on("close", () => upstream.destroy());
  upstream.setTimeout(20_000, close);
  upstream.on("error", () => { if (!response.headersSent) response.writeHead(502); response.end(); });
  incoming.pipe(upstream);
});
server.on("connection", socket => {
  if (sockets.size >= 32) return socket.destroy();
  sockets.add(socket);
  socket.on("close", () => sockets.delete(socket));
});
server.maxConnections = 32;
server.on("error", () => { console.error("Fixture proxy unavailable"); process.exit(1); });
server.listen(4143, "127.0.0.1");
process.on("SIGTERM", () => {
  for (const socket of sockets) socket.destroy();
  server.close(() => process.exit(0));
});
