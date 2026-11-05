// chaos-proxy.mjs  (Node 20+, no dependencies)
//
// A hostile JSON-RPC proxy in front of one anvil node. We run two instances:
//   primary : UPSTREAM=http://127.0.0.1:8545 PORT=9545 LAG_BLOCKS=0 SEED=1 node chaos-proxy.mjs
//   replica : UPSTREAM=http://127.0.0.1:8545 PORT=9546 LAG_BLOCKS=3 SEED=2 node chaos-proxy.mjs
//
// Each instance presents a consistent view of the chain at a "visible head":
//   visibleHead = trueHead - LAG_BLOCKS - (random extra lag of 1..MAX_STALE_BLOCKS with probability STALE_RATE)
// The visible head is applied to EVERY head-reading method, not only eth_blockNumber:
//   eth_blockNumber, eth_getBlockByNumber (tags and numbers), eth_getBlockByHash, eth_getLogs,
//   eth_getTransactionReceipt, eth_getTransactionByHash, and the block parameter of eth_call,
//   eth_estimateGas, eth_getTransactionCount, eth_getBalance, eth_getCode, eth_getStorageAt.
// So a lagging endpoint returns stale nonces, missing receipts and short log ranges, like a real
// replica that is behind. Tags "latest", "pending", "safe" and "finalized" all resolve to the
// visible head (anvil has no real finality; your CONFIRMATIONS setting defines finality).
//
// Faults (all configurable at runtime with POST /admin/config, read with GET /admin/config):
//   dropRate        close the socket without a response
//   rate429         HTTP 429 with Retry-After: 1
//   rate5xx         HTTP 503
//   lostSendRate    eth_sendRawTransaction IS broadcast, but the client gets HTTP 504
//   swallowSendRate eth_sendRawTransaction returns the correct hash, then the tx is dropped from
//                   the mempool (anvil_dropTransaction) and will never be mined
//   maxLogRange     eth_getLogs spans above this return JSON-RPC error -32005
//   down            every request gets HTTP 503
// Requires anvil started with --block-time 1 (interval mining) so swallowed sends can be dropped
// before they are mined.

import http from "node:http";

const UPSTREAM = process.env.UPSTREAM ?? "http://127.0.0.1:8545";
const PORT = Number(process.env.PORT ?? 9545);
const cfg = {
  lagBlocks: Number(process.env.LAG_BLOCKS ?? 0),
  staleRate: Number(process.env.STALE_RATE ?? 0.1),
  maxStaleBlocks: Number(process.env.MAX_STALE_BLOCKS ?? 4),
  dropRate: Number(process.env.DROP_RATE ?? 0.03),
  rate429: Number(process.env.RATE_429 ?? 0.05),
  rate5xx: Number(process.env.RATE_5XX ?? 0.03),
  lostSendRate: Number(process.env.LOST_SEND_RATE ?? 0.15),
  swallowSendRate: Number(process.env.SWALLOW_SEND_RATE ?? 0.05),
  minLatencyMs: Number(process.env.MIN_LATENCY_MS ?? 10),
  maxLatencyMs: Number(process.env.MAX_LATENCY_MS ?? 250),
  maxLogRange: Number(process.env.MAX_LOG_RANGE ?? 200),
  down: false,
};

let seed = Number(process.env.SEED ?? 42) >>> 0;
function rand() {
  // mulberry32. Seeded, but concurrency means runs are not perfectly reproducible.
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hex = (n) => "0x" + n.toString(16);
const rpcError = (id, code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });
const ok = (id, result) => ({ jsonrpc: "2.0", id, result });

let nextId = 1;
async function call(method, params = []) {
  const res = await fetch(UPSTREAM, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }),
  });
  const j = await res.json();
  if (j.error) {
    const e = new Error(j.error.message);
    e.rpc = j.error;
    throw e;
  }
  return j.result;
}
async function forward(req) {
  const res = await fetch(UPSTREAM, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(req),
  });
  return res.json();
}

async function visibleHead() {
  const trueHead = BigInt(await call("eth_blockNumber"));
  let lag = BigInt(cfg.lagBlocks);
  if (rand() < cfg.staleRate) lag += BigInt(1 + Math.floor(rand() * cfg.maxStaleBlocks));
  return trueHead > lag ? trueHead - lag : 0n;
}

const TAGS = new Set(["latest", "pending", "safe", "finalized"]);
// returns a block number (bigint), or null for "earliest"
function resolveTag(tag, head) {
  if (tag === undefined || tag === null) return head;
  if (typeof tag === "object") return tag; // EIP-1898 {blockHash} or {blockNumber}: handled by caller
  if (TAGS.has(tag)) return head;
  if (tag === "earliest") return 0n;
  return BigInt(tag);
}

// methods whose LAST param (at given index) is a block tag
const BLOCK_PARAM_INDEX = {
  eth_call: 1,
  eth_estimateGas: 1,
  eth_getTransactionCount: 1,
  eth_getBalance: 1,
  eth_getCode: 1,
  eth_getStorageAt: 2,
};

async function handleOne(req, getHead) {
  const { method, id } = req;
  const params = Array.isArray(req.params) ? [...req.params] : [];

  if (method === "eth_sendRawTransaction") {
    const r = rand();
    if (r < cfg.lostSendRate) {
      await forward(req); // really broadcast
      const e = new Error("response lost");
      e.lost = true;
      throw e;
    }
    if (r < cfg.lostSendRate + cfg.swallowSendRate) {
      const out = await forward(req);
      if (out.result) {
        try { await call("anvil_dropTransaction", [out.result]); } catch {}
      }
      return out; // client sees success; tx never mines
    }
    return forward(req);
  }

  const head = await getHead();

  switch (method) {
    case "eth_blockNumber":
      return ok(id, hex(head));

    case "eth_getBlockByNumber": {
      const n = resolveTag(params[0], head);
      if (n > head) return ok(id, null);
      params[0] = hex(n);
      return forward({ ...req, params });
    }

    case "eth_getBlockByHash": {
      const out = await forward(req);
      if (out.result && BigInt(out.result.number) > head) out.result = null;
      return out;
    }

    case "eth_getLogs": {
      const f = { ...(params[0] ?? {}) };
      if (f.blockHash) {
        const out = await forward(req);
        if (Array.isArray(out.result)) out.result = out.result.filter((l) => BigInt(l.blockNumber) <= head);
        return out;
      }
      let from = resolveTag(f.fromBlock ?? "latest", head);
      let to = resolveTag(f.toBlock ?? "latest", head);
      if (to > head) to = head;
      if (from > to) return ok(id, []);
      if (to - from + 1n > BigInt(cfg.maxLogRange)) {
        return rpcError(id, -32005, `query exceeds max block range ${cfg.maxLogRange}`);
      }
      f.fromBlock = hex(from);
      f.toBlock = hex(to);
      return forward({ ...req, params: [f] });
    }

    case "eth_getTransactionReceipt": {
      const out = await forward(req);
      if (out.result && BigInt(out.result.blockNumber) > head) out.result = null;
      return out;
    }

    case "eth_getTransactionByHash": {
      const out = await forward(req);
      if (out.result && out.result.blockNumber && BigInt(out.result.blockNumber) > head) {
        out.result = { ...out.result, blockHash: null, blockNumber: null, transactionIndex: null };
      }
      return out;
    }
  }

  if (method in BLOCK_PARAM_INDEX) {
    const i = BLOCK_PARAM_INDEX[method];
    const tag = params[i];
    if (tag && typeof tag === "object") return forward(req);
    const n = resolveTag(tag ?? "latest", head);
    if (n > head) return rpcError(id, -32000, "header not found");
    params[i] = hex(n);
    return forward({ ...req, params });
  }

  return forward(req);
}

http
  .createServer(async (req, res) => {
    let raw = "";
    for await (const chunk of req) raw += chunk;

    if (req.url === "/admin/config") {
      if (req.method === "POST") Object.assign(cfg, JSON.parse(raw || "{}"));
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify(cfg));
    }

    await sleep(cfg.minLatencyMs + rand() * (cfg.maxLatencyMs - cfg.minLatencyMs));
    if (cfg.down) { res.writeHead(503); return res.end("upstream down"); }
    if (rand() < cfg.dropRate) { req.socket.destroy(); return; }
    if (rand() < cfg.rate429) { res.writeHead(429, { "retry-after": "1" }); return res.end("rate limited"); }
    if (rand() < cfg.rate5xx) { res.writeHead(503); return res.end("service unavailable"); }

    try {
      const body = JSON.parse(raw);
      let headP; // one visible head per HTTP request, so a batch sees a consistent view
      const getHead = () => (headP ??= visibleHead());
      const out = Array.isArray(body)
        ? await Promise.all(body.map((r) => handleOne(r, getHead)))
        : await handleOne(body, getHead);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(out));
    } catch (e) {
      if (e.lost) { res.writeHead(504); return res.end("gateway timeout"); }
      res.writeHead(502);
      res.end("bad gateway");
    }
  })
  .listen(PORT, () => console.log(`chaos proxy :${PORT} -> ${UPSTREAM} (lag ${cfg.lagBlocks})`));
