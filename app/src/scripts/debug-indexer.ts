import { createPool, migrate } from "../db/pool.ts";
import { ChaosRpc } from "../rpc/client.ts";
import { Indexer } from "../indexer/indexer.ts";

async function main() {
  const pool = createPool();
  await migrate(pool);
  const rpc = ChaosRpc.fromEnv();
  console.log("tip", (await rpc.getBlockNumber()).toString());
  console.log("RPC_URLS", process.env.RPC_URLS);
  console.log("DEPLOYMENTS", process.env.DEPLOYMENTS_PATH);
  const indexer = new Indexer(pool, rpc, process.env.DEPLOYMENTS_PATH ?? "/deployments.json");
  for (let i = 0; i < 5; i++) {
    await (indexer as unknown as { tick: () => Promise<void> }).tick();
    const r = await pool.query("select head_block from andx_indexer_head where id=1");
    const e = await pool.query("select count(*)::int as n from andx_events");
    console.log(`tick ${i}: head=${r.rows[0].head_block} events=${e.rows[0].n}`);
  }
  await pool.end();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
