import { createPool, migrate } from "./db/pool.ts";
import { ChaosRpc } from "./rpc/client.ts";
import { Indexer } from "./indexer/indexer.ts";
import { Relayer } from "./relayer/relayer.ts";
import type { Hex } from "viem";

async function main() {
  const pool = createPool();
  await migrate(pool);

  const rpc = ChaosRpc.fromEnv();
  const deploymentsPath = process.env.DEPLOYMENTS_PATH ?? "/deployments.json";
  const relayerKey = (process.env.RELAYER_PRIVATE_KEY ??
    "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a") as Hex;

  const indexer = new Indexer(pool, rpc, deploymentsPath);
  const relayer = new Relayer(pool, rpc, deploymentsPath, relayerKey);

  console.log("[app] starting indexer + relayer");
  await Promise.all([indexer.start(), relayer.start()]);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
