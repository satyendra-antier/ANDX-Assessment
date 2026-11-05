# High-Level Design — ANDX Campaign Escrow

## Purpose

ANDX locks brand budgets on-chain, publishes cumulative creator earnings as Merkle roots, and lets creators claim (directly or gaslessly via a relayer). Off-chain systems must stay correct under hostile RPCs, shallow reorgs, and process crashes.

## System context

```
Brands / Operator / Guardian / Creators / Relayer
                    |
                    v
              AndxEscrow (anvil :8545)
                    ^
         chaos-primary :9545 / chaos-replica :9546
                    |
              app (indexer + relayer)
                    |
              Postgres (andx)
```

## Components

| Component | Responsibility |
|---|---|
| `AndxEscrow` | Solvent escrow: campaigns, delayed roots, claims, refunds, operator controls |
| Chaos proxies | Inject lag, drops, 429/503, lost/dropped sends, log-range limits |
| Indexer | Reorg-safe event ingestion; derives `andx_campaign_state` from finalized events only |
| Relayer | Exactly-once `claimWithSig` submission with persisted nonce |
| Makefile / Compose | Deterministic local harness matching assessment commands |

## Trust boundaries

- **Operator** can propose roots within commitment rules; cannot drain beyond `netDeposited - refunded` or epoch caps.
- **Guardian** can veto pending roots and revoke/pause; cannot claim or refund brands' funds.
- **Relayer** submits signed claims; EIP-712 binds creator intent (recipient, fee, nonce, deadline).
- **App** never talks to anvil directly — only chaos RPCs (`RPC_URLS`).

## Data flow

1. `make deploy` / `seed` / `publish` → anvil (direct).
2. Operator proposes Merkle root → delay `ROOT_DELAY` → activate.
3. Indexer reads logs via chaos → Postgres (`andx_events`, head checkpoint).
4. `make claim-all` enqueues jobs → relayer simulates → sends → waits for receipt status=1.
5. Finalized events (`CONFIRMATIONS=6`) update `andx_campaign_state`.

## Non-functional requirements

- Solvency and no double-pay under weird ERC-20s (FOTX, NRT, HOOK).
- Crash-safe checkpoints (events + head in one DB transaction).
- Exactly-once relay under lost HTTP responses and silently dropped txs.
- Not upgradeable.

## Related docs

- [LLD.md](./LLD.md) — storage, algorithms, schemas
- [adr/](./adr/) — architecture decision records
