'use strict';

const express = require('express');
const { execSync } = require('child_process');
const path = require('path');
const config = require('./config.json');
const x402Middleware = require('./middleware');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PORT = parseInt(process.env.PORT, 10) || 3402;
const PROJECT_ROOT = path.resolve(__dirname, '..');
const SCRIPTS_DIR = path.join(PROJECT_ROOT, 'scripts');
const SERVICE_NAME = 'yieldclaw-x402';
const SERVICE_VERSION = '1.0.0';

// ---------------------------------------------------------------------------
// Rate limiter (simple in-memory, 100 req/min per IP)
// ---------------------------------------------------------------------------

/** @type {Map<string, { count: number, resetAt: number }>} */
const rateLimitStore = new Map();

const RATE_LIMIT_WINDOW_MS = 60 * 1000; // 1 minute
const RATE_LIMIT_MAX = 100;

/**
 * Clean up expired rate-limit entries every 5 minutes to prevent unbounded
 * memory growth.
 */
setInterval(() => {
  const now = Date.now();
  for (const [ip, entry] of rateLimitStore) {
    if (now > entry.resetAt) {
      rateLimitStore.delete(ip);
    }
  }
}, 5 * 60 * 1000).unref();

/**
 * Express middleware that enforces a per-IP request rate limit.
 *
 * @param {import('express').Request}  req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
function rateLimiter(req, res, next) {
  const ip = req.ip || req.socket.remoteAddress || 'unknown';
  const now = Date.now();

  let entry = rateLimitStore.get(ip);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + RATE_LIMIT_WINDOW_MS };
    rateLimitStore.set(ip, entry);
  }

  entry.count += 1;

  res.setHeader('X-RateLimit-Limit', String(RATE_LIMIT_MAX));
  res.setHeader('X-RateLimit-Remaining', String(Math.max(0, RATE_LIMIT_MAX - entry.count)));
  res.setHeader('X-RateLimit-Reset', String(Math.ceil(entry.resetAt / 1000)));

  if (entry.count > RATE_LIMIT_MAX) {
    return res.status(429).json({
      status: 429,
      message: 'Too Many Requests',
      retryAfterMs: entry.resetAt - now,
    });
  }

  next();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Execute a shell script and return its stdout as a trimmed string.
 *
 * @param {string} scriptName - File name inside the scripts/ directory.
 * @param {string[]} [args] - Arguments to pass to the script.
 * @returns {string} stdout of the script.
 * @throws {Error} If the script exits with a non-zero code.
 */
function runScript(scriptName, args) {
  const scriptPath = path.join(SCRIPTS_DIR, scriptName);
  const argStr = args && args.length > 0 ? ' ' + args.join(' ') : '';
  const cmd = `bash "${scriptPath}"${argStr}`;

  const output = execSync(cmd, {
    cwd: PROJECT_ROOT,
    encoding: 'utf-8',
    timeout: 30000, // 30 s hard limit
    env: { ...process.env },
  });

  return output.trim();
}

/**
 * Attempt to parse a string as JSON; return the raw string wrapped in a
 * `{ result: ... }` object if parsing fails.
 *
 * @param {string} raw - Raw script output.
 * @returns {object} Parsed JSON or wrapped string.
 */
function parseScriptOutput(raw) {
  try {
    return JSON.parse(raw);
  } catch (_) {
    return { result: raw };
  }
}

/**
 * Validate that a string looks like a valid Ethereum address (0x + 40 hex).
 *
 * @param {string} addr
 * @returns {boolean}
 */
function isValidAddress(addr) {
  return /^0x[0-9a-fA-F]{40}$/.test(addr);
}

/**
 * Validate that a value is a positive integer (as a string or number).
 *
 * @param {string|number} id
 * @returns {boolean}
 */
function isPositiveInteger(id) {
  const n = Number(id);
  return Number.isInteger(n) && n > 0;
}

// ---------------------------------------------------------------------------
// App setup
// ---------------------------------------------------------------------------

const app = express();

// CORS -- wide open for agent access.
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Payment, Authorization');
  res.setHeader('Access-Control-Expose-Headers', 'X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset');
  if (req.method === 'OPTIONS') {
    return res.sendStatus(204);
  }
  next();
});

// Request logging.
app.use((req, res, next) => {
  const ts = new Date().toISOString();
  const start = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - start;
    console.log(`[${ts}] ${req.method} ${req.originalUrl} -> ${res.statusCode} (${duration}ms)`);
  });
  next();
});

// JSON body parsing (for potential future POST endpoints).
app.use(express.json());

// Rate limiter.
app.use(rateLimiter);

// x402 payment middleware.
app.use(x402Middleware);

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

/**
 * GET /health -- Health check (free, not gated).
 */
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    service: SERVICE_NAME,
    version: SERVICE_VERSION,
  });
});

/**
 * GET / -- Service info and endpoint listing (free).
 */
app.get('/', (_req, res) => {
  const endpoints = Object.entries(config.endpoints).map(([path, info]) => ({
    path,
    price: info.price,
    priceFormatted: `${(Number(info.price) / Math.pow(10, config.paymentTokenDecimals)).toFixed(config.paymentTokenDecimals)} ${config.paymentTokenSymbol}`,
    description: info.description,
  }));

  res.json({
    service: SERVICE_NAME,
    version: SERVICE_VERSION,
    protocol: 'x402',
    network: config.network,
    chainId: config.chainId,
    paymentToken: config.paymentToken,
    paymentTokenSymbol: config.paymentTokenSymbol,
    endpoints,
  });
});

/**
 * GET /yield/apy -- Current vault APY.
 */
app.get('/yield/apy', (req, res) => {
  try {
    const raw = runScript('get-apy.sh');
    res.json(parseScriptOutput(raw));
  } catch (err) {
    console.error('Error running get-apy.sh:', err.message);
    res.status(500).json({ status: 500, error: 'Failed to retrieve APY data', detail: err.message });
  }
});

/**
 * GET /yield/tvl -- Total value locked.
 */
app.get('/yield/tvl', (req, res) => {
  try {
    const raw = runScript('get-tvl.sh');
    res.json(parseScriptOutput(raw));
  } catch (err) {
    console.error('Error running get-tvl.sh:', err.message);
    res.status(500).json({ status: 500, error: 'Failed to retrieve TVL data', detail: err.message });
  }
});

/**
 * GET /yield/balance/:address -- Address balance lookup.
 */
app.get('/yield/balance/:address', (req, res) => {
  const { address } = req.params;

  if (!isValidAddress(address)) {
    return res.status(400).json({
      status: 400,
      error: 'Invalid address format',
      expected: '0x followed by 40 hexadecimal characters',
    });
  }

  try {
    const raw = runScript('get-balance.sh', [address]);
    res.json(parseScriptOutput(raw));
  } catch (err) {
    console.error(`Error running get-balance.sh ${address}:`, err.message);
    res.status(500).json({ status: 500, error: 'Failed to retrieve balance', detail: err.message });
  }
});

/**
 * GET /yield/stats -- Full protocol statistics.
 */
app.get('/yield/stats', (req, res) => {
  try {
    const raw = runScript('get-stats.sh');
    res.json(parseScriptOutput(raw));
  } catch (err) {
    console.error('Error running get-stats.sh:', err.message);
    res.status(500).json({ status: 500, error: 'Failed to retrieve stats', detail: err.message });
  }
});

/**
 * GET /yield/report -- Complete yield report.
 */
app.get('/yield/report', (req, res) => {
  try {
    const raw = runScript('yield-report.sh');
    res.json(parseScriptOutput(raw));
  } catch (err) {
    console.error('Error running yield-report.sh:', err.message);
    res.status(500).json({ status: 500, error: 'Failed to generate yield report', detail: err.message });
  }
});

/**
 * GET /yield/stream/:id -- Payment stream info.
 */
app.get('/yield/stream/:id', (req, res) => {
  const { id } = req.params;

  if (!isPositiveInteger(id)) {
    return res.status(400).json({
      status: 400,
      error: 'Invalid stream ID',
      expected: 'A positive integer',
    });
  }

  try {
    const raw = runScript('get-stream.sh', [id]);
    res.json(parseScriptOutput(raw));
  } catch (err) {
    console.error(`Error running get-stream.sh ${id}:`, err.message);
    res.status(500).json({ status: 500, error: 'Failed to retrieve stream info', detail: err.message });
  }
});

// ---------------------------------------------------------------------------
// 404 catch-all
// ---------------------------------------------------------------------------

app.use((_req, res) => {
  res.status(404).json({
    status: 404,
    error: 'Not Found',
    service: SERVICE_NAME,
  });
});

// ---------------------------------------------------------------------------
// Global error handler
// ---------------------------------------------------------------------------

/**
 * Express error-handling middleware.
 *
 * @param {Error} err
 * @param {import('express').Request}  _req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} _next
 */
app.use((err, _req, res, _next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({
    status: 500,
    error: 'Internal Server Error',
    detail: process.env.NODE_ENV === 'development' ? err.message : undefined,
  });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`\n  YieldClaw x402 Payment Gateway`);
    console.log(`  ================================`);
    console.log(`  Service:  ${SERVICE_NAME} v${SERVICE_VERSION}`);
    console.log(`  Port:     ${PORT}`);
    console.log(`  Network:  ${config.network} (chain ${config.chainId})`);
    console.log(`  Token:    ${config.paymentTokenSymbol} (${config.paymentToken})`);
    console.log(`  PayTo:    ${process.env.YIELDCLAW_PAY_ADDRESS || '(not set -- using default)'}`);
    console.log(`  Endpoints: ${Object.keys(config.endpoints).length} priced`);
    console.log(`  ================================\n`);
  });
}

module.exports = app;
