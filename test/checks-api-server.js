#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const http = require('node:http');

const [portFile, requestFile] = process.argv.slice(2);
if (!portFile || !requestFile) {
  console.error('usage: checks-api-server.js <port-file> <request-file>');
  process.exit(2);
}

const server = http.createServer(async (request, response) => {
  let raw = '';
  for await (const chunk of request) raw += chunk;
  const body = raw ? JSON.parse(raw) : null;
  fs.appendFileSync(requestFile, `${JSON.stringify({
    method: request.method,
    url: request.url,
    headers: request.headers,
    body,
  })}\n`);
  if (request.method === 'GET' && request.url === '/repos/local/test/issues/1/comments?per_page=100') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end('[]');
    return;
  }
  if (request.method === 'POST' && (
    request.url === '/repos/local/test/check-runs' ||
    request.url === '/repos/local/test/issues/1/comments'
  )) {
    response.writeHead(201, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ id: 1 }));
    return;
  }
  response.writeHead(404, { 'content-type': 'application/json' });
  response.end(JSON.stringify({ message: 'not found' }));
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});

function close() {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1_000).unref();
}

process.on('SIGINT', close);
process.on('SIGTERM', close);
