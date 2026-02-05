'use strict';

const path = require('path');
const config = require('./config.json');

/**
 * Default payment receiving address when YIELDCLAW_PAY_ADDRESS is not set.
 * @type {string}
 */
const DEFAULT_PAY_ADDRESS = '0x0000000000000000000000000000000000000000';

/**
 * Resolve the pay-to address from environment or fall back to default.
 * @returns {string} Ethereum-style address
 */
function getPayToAddress() {
  return process.env.YIELDCLAW_PAY_ADDRESS || DEFAULT_PAY_ADDRESS;
}

/**
 * Match a request path against the configured endpoint patterns.
 *
 * Supports Express-style route parameters (`:address`, `:id`) by converting
 * them to a simple regex with a `[^/]+` capture group.
 *
 * @param {string} reqPath - The incoming request path (e.g. "/yield/balance/0xabc...")
 * @returns {{ endpoint: string, price: string, description: string } | null}
 *   The matched endpoint config or null when the path is not priced.
 */
function matchEndpoint(reqPath) {
  const endpoints = config.endpoints;

  // Try an exact match first (fast path).
  if (endpoints[reqPath]) {
    return {
      endpoint: reqPath,
      price: endpoints[reqPath].price,
      description: endpoints[reqPath].description,
    };
  }

  // Try parameterised patterns (e.g. /yield/balance/:address).
  for (const pattern of Object.keys(endpoints)) {
    if (!pattern.includes(':')) continue;

    // Convert Express-style params to regex: `:foo` -> `[^/]+`
    const regexStr =
      '^' +
      pattern
        .split('/')
        .map((seg) => (seg.startsWith(':') ? '[^/]+' : seg))
        .join('/') +
      '$';

    if (new RegExp(regexStr).test(reqPath)) {
      return {
        endpoint: pattern,
        price: endpoints[pattern].price,
        description: endpoints[pattern].description,
      };
    }
  }

  return null;
}

/**
 * Validate a Payment header value.
 *
 * The header is expected to be a Base64-encoded JSON string containing at
 * minimum: `from`, `to`, `amount`, `token`, `chainId`, and `signature`.
 *
 * This is a *simplified* verification suitable for the hackathon demo.  A
 * production implementation would verify the cryptographic signature
 * on-chain or via an EIP-712 typed-data check.
 *
 * @param {string} paymentHeader - Raw value of the `Payment` HTTP header.
 * @param {string} expectedAmount - The price in base units for the endpoint.
 * @returns {{ valid: boolean, error?: string, payment?: object }}
 */
function validatePayment(paymentHeader, expectedAmount) {
  try {
    // The header may be raw JSON or Base64-encoded JSON.
    let decoded;
    try {
      decoded = JSON.parse(paymentHeader);
    } catch (_) {
      // Try Base64 decoding.
      const buf = Buffer.from(paymentHeader, 'base64');
      decoded = JSON.parse(buf.toString('utf-8'));
    }

    const required = ['from', 'to', 'amount', 'token', 'chainId', 'signature'];
    for (const field of required) {
      if (decoded[field] === undefined || decoded[field] === null || decoded[field] === '') {
        return { valid: false, error: `Missing required field: ${field}` };
      }
    }

    // Verify the payment targets the correct token and chain.
    if (String(decoded.chainId) !== String(config.chainId)) {
      return { valid: false, error: `Invalid chainId: expected ${config.chainId}` };
    }

    if (decoded.token.toLowerCase() !== config.paymentToken.toLowerCase()) {
      return { valid: false, error: `Invalid token: expected ${config.paymentToken}` };
    }

    // Verify the amount is sufficient.
    if (BigInt(decoded.amount) < BigInt(expectedAmount)) {
      return {
        valid: false,
        error: `Insufficient payment: expected at least ${expectedAmount}, got ${decoded.amount}`,
      };
    }

    // Verify the recipient matches the configured payTo address.
    const payTo = getPayToAddress();
    if (payTo !== DEFAULT_PAY_ADDRESS && decoded.to.toLowerCase() !== payTo.toLowerCase()) {
      return { valid: false, error: `Invalid recipient: expected ${payTo}` };
    }

    return { valid: true, payment: decoded };
  } catch (err) {
    return { valid: false, error: `Malformed Payment header: ${err.message}` };
  }
}

/**
 * Build the 402 Payment Required response body.
 *
 * @param {string} price - Price in base token units.
 * @param {string} description - Human-readable endpoint description.
 * @returns {object} JSON-serialisable response body.
 */
function build402Response(price, description) {
  return {
    status: 402,
    message: 'Payment Required',
    x402: {
      version: '1.0',
      network: config.network,
      chainId: config.chainId,
      payTo: getPayToAddress(),
      token: config.paymentToken,
      amount: price,
      description: description,
    },
  };
}

/**
 * Express middleware implementing the x402 payment gate.
 *
 * - If the request path does not match a priced endpoint the request passes
 *   through to the next handler unchanged.
 * - If the path matches but no `Payment` header is present the middleware
 *   responds with HTTP 402 and payment requirements.
 * - If a `Payment` header is present the middleware validates it; on success
 *   it sets `req.x402Paid = true` and calls `next()`.  On failure it returns
 *   HTTP 402 with the validation error.
 *
 * @param {import('express').Request}  req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
function x402Middleware(req, res, next) {
  const match = matchEndpoint(req.path);

  // Not a priced endpoint -- pass through.
  if (!match) {
    return next();
  }

  const paymentHeader = req.headers['payment'] || req.headers['Payment'];

  // No payment provided -- respond with 402.
  if (!paymentHeader) {
    const body = build402Response(match.price, match.description);
    return res.status(402).json(body);
  }

  // Validate the supplied payment.
  const result = validatePayment(paymentHeader, match.price);

  if (!result.valid) {
    const body = build402Response(match.price, match.description);
    body.error = result.error;
    return res.status(402).json(body);
  }

  // Payment accepted.
  req.x402Paid = true;
  req.x402Payment = result.payment;
  req.x402Endpoint = match.endpoint;
  next();
}

module.exports = x402Middleware;
module.exports.matchEndpoint = matchEndpoint;
module.exports.validatePayment = validatePayment;
module.exports.build402Response = build402Response;
