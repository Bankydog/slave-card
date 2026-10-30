"use strict";

const http = require("node:http");
const net = require("node:net");
const { spawn } = require("node:child_process");

const PUBLIC_HOST = "0.0.0.0";
const PUBLIC_PORT = parsePort(process.env.PORT, 10000, "PORT");
const GODOT_HOST = "127.0.0.1";
const GODOT_PORT = parsePort(process.env.GODOT_PORT, 10001, "GODOT_PORT");
const GODOT_EXECUTABLE = process.env.GODOT_BIN || "/usr/local/bin/godot";
const GODOT_PROJECT_PATH = process.env.GODOT_PROJECT_PATH || "/app";
const activeSockets = new Set();
let shuttingDown = false;
let godotBackendReady = false;
let backendProbeInFlight = false;

function parsePort(value, fallback, label) {
	if (!value) return fallback;
	const port = Number(value);
	if (!Number.isInteger(port) || port < 1 || port > 65535) {
		throw new Error(`${label} must be an integer between 1 and 65535`);
	}
	return port;
}

const godot = spawn(
	GODOT_EXECUTABLE,
	["--headless", "--path", GODOT_PROJECT_PATH, "res://scenes/server.tscn"],
	{
		stdio: ["ignore", "inherit", "inherit"],
		env: {
			...process.env,
			GODOT_BIND_ADDRESS: GODOT_HOST,
			GODOT_PORT: String(GODOT_PORT),
		},
	},
);

godot.on("error", (error) => {
	console.error("Could not start the Godot dedicated server:", error.message);
	process.exit(1);
});

godot.on("exit", (code, signal) => {
	setBackendReady(false);
	if (shuttingDown) return;
	console.error(`Godot dedicated server exited unexpectedly (code ${code}, signal ${signal}).`);
	shutdown(code === 0 ? 1 : code || 1);
});

const server = http.createServer((request, response) => {
	if (request.method === "GET" && (request.url === "/" || request.url === "/health")) {
		if (request.url === "/health") {
			const ready = godotBackendReady && godot.exitCode === null && godot.signalCode === null;
			response.writeHead(ready ? 200 : 503, { "content-type": "application/json; charset=utf-8", connection: "close" });
			response.end(JSON.stringify({ proxy_alive: true, godot_backend_ready: ready }) + "\n");
			return;
		}
		response.writeHead(200, { "content-type": "text/plain; charset=utf-8", connection: "close" });
		response.end("Slave Card server\n");
		return;
	}
	response.writeHead(404, { "content-type": "text/plain; charset=utf-8", connection: "close" });
	response.end("Not found\n");
});

server.on("upgrade", (request, clientSocket, head) => {
	if (request.url !== "/") {
		clientSocket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
		return;
	}

	activeSockets.add(clientSocket);
	clientSocket.once("close", () => activeSockets.delete(clientSocket));
	const godotSocket = net.createConnection({ host: GODOT_HOST, port: GODOT_PORT });
	activeSockets.add(godotSocket);
	godotSocket.once("close", () => activeSockets.delete(godotSocket));
	let requestForwarded = false;

	godotSocket.once("connect", () => {
		const forwardedHeaders = [];
		for (let index = 0; index < request.rawHeaders.length; index += 2) {
			forwardedHeaders.push(`${request.rawHeaders[index]}: ${request.rawHeaders[index + 1]}`);
		}
		godotSocket.write(
			`${request.method} ${request.url} HTTP/${request.httpVersion}\r\n${forwardedHeaders.join("\r\n")}\r\n\r\n`,
		);
		if (head.length > 0) godotSocket.write(head);
		requestForwarded = true;
		godotSocket.once("data", (data) => {
			if (data.toString("ascii", 0, 32).startsWith("HTTP/1.1 101")) setBackendReady(true);
		});
		clientSocket.pipe(godotSocket);
		godotSocket.pipe(clientSocket);
	});

	godotSocket.once("error", (error) => {
		if (!requestForwarded && !clientSocket.destroyed) {
			clientSocket.end("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
		} else if (!clientSocket.destroyed) {
			clientSocket.destroy(error);
		}
	});
	clientSocket.once("error", () => godotSocket.destroy());
});

server.on("error", (error) => {
	console.error("Public HTTP/WebSocket proxy failed:", error.message);
	shutdown(1);
});

server.listen(PUBLIC_PORT, PUBLIC_HOST, () => {
	console.log(`Slave Card HTTP/WebSocket proxy listening on ${PUBLIC_HOST}:${PUBLIC_PORT}; Godot is ${GODOT_HOST}:${GODOT_PORT}.`);
});

const backendProbeTimer = setInterval(probeGodotBackend, 1000);
backendProbeTimer.unref();
probeGodotBackend();

function probeGodotBackend() {
	if (backendProbeInFlight || shuttingDown || godot.exitCode !== null || godot.signalCode !== null) return;
	backendProbeInFlight = true;
	const socket = net.createConnection({ host: GODOT_HOST, port: GODOT_PORT });
	const timeout = setTimeout(() => socket.destroy(), 750);
	timeout.unref();
	socket.once("connect", () => {
		socket.write(
			"GET / HTTP/1.1\r\n" +
			`Host: ${GODOT_HOST}:${GODOT_PORT}\r\n` +
			"Upgrade: websocket\r\n" +
			"Connection: Upgrade\r\n" +
			"Sec-WebSocket-Version: 13\r\n" +
			"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
		);
	});
	socket.once("data", (data) => {
		clearTimeout(timeout);
		setBackendReady(data.toString("ascii", 0, 32).startsWith("HTTP/1.1 101"));
		socket.destroy();
	});
	socket.once("error", () => {
		clearTimeout(timeout);
		setBackendReady(false);
	});
	socket.once("close", () => {
		clearTimeout(timeout);
		backendProbeInFlight = false;
	});
}

function setBackendReady(ready) {
	if (godotBackendReady === ready) return;
	godotBackendReady = ready;
	console.log(`[Proxy] Godot WebSocket backend ${ready ? "ready" : "unavailable"} at ${GODOT_HOST}:${GODOT_PORT}.`);
}

function shutdown(exitCode) {
	if (shuttingDown) return;
	shuttingDown = true;
	clearInterval(backendProbeTimer);
	if (server.listening) server.close();
	for (const socket of activeSockets) socket.destroy();
	if (godot.exitCode === null && godot.signalCode === null) godot.kill("SIGTERM");
	const forceExit = setTimeout(() => {
		if (godot.exitCode === null && godot.signalCode === null) godot.kill("SIGKILL");
		process.exit(exitCode);
	}, 5000);
	forceExit.unref();
	if (godot.exitCode !== null || godot.signalCode !== null) process.exit(exitCode);
	godot.once("exit", () => process.exit(exitCode));
}

process.on("SIGTERM", () => shutdown(0));
process.on("SIGINT", () => shutdown(0));
