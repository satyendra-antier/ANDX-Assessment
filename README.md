# ANDX Web3 Assessment — Campaign Escrow & Payout Rail

Production-oriented submission: solvent `AndxEscrow`, Foundry invariants, reorg/crash-safe indexer, exactly-once claim relayer, and a security review of `LegacyPayouts`.

## Quick start

```bash
# Prerequisites: Docker, Node 20+, Foundry (forge/cast/anvil)
make up
make deploy
make seed
make publish
make claim-all
make test
make down
```

Host ports: anvil `8545`, chaos-primary `9545`, chaos-replica `9546`, Postgres `5432`.

## Architecture

See [docs/HLD.md](docs/HLD.md) and [docs/LLD.md](docs/LLD.md). Decision records in [docs/adr/](docs/adr/).

```
brands / operator / guardian / creators / relayer
                    ↓
              AndxEscrow ← anvil :8545
                    ↑
         chaos :9545 / :9546  →  app (indexer + relayer) → Postgres
```

The `app` service is a single long-running process (SIGKILL-tested). Deploy/seed/publish talk to anvil directly; the app uses only `RPC_URLS`.

## Operator rotation (4.5)

**Pending roots survive** `applyOperator` / `revokeOperator`. Only the operator address changes. After revoke, `operator = address(0)` (no new proposals); anyone may still `activateRoot` after delay; guardian may still `vetoRoot`. See [docs/adr/0001-pending-root-on-operator-change.md](docs/adr/0001-pending-root-on-operator-change.md).

## Invariants

Configured in `contracts/foundry.toml`: `runs = 256`, `depth = 100`, `show_metrics = true`.

Handlers cover: createCampaign (USDX/FOTX/NRT), honest + adversarial propose, activate, veto, direct claim, claimWithSig + replay, refund, time warps.

| Id | Check |
|---|---|
| I1 | Per-token solvency |
| I2 | claimed ≤ active ≤ net−refunded; pending ≤ net−refunded |
| I3 | No double-pay vs max activated cumulative |
| I4 | Exact-equality ghost accounting vs contract |
| I5 | Refunds never strand active/pending commitments |
| I6 | Nonce single-use (replay must not succeed) |

### Mutation demo

Temporarily change `AndxEscrow.claim` to skip the `claimedTotal <= activeCommitted` check, then:

```bash
cd contracts && forge test --match-contract EscrowInvariants
```

Invariant I2 (and typically I1) fails. Revert the mutation before submitting. This demonstrates the suite is not vacuously green.

## Assumptions

- Anvil default mnemonic; accounts per Appendix A.
- Kit files under `contracts/src/interfaces|tokens|audit`, `chaos/`, `fixtures/` are unmodified.
- `pendingCommitted` view equals pending proposal commitment if listed, else `activeCommitted`.
- Relayer uses acct4; jobs are `done` only on receipt `status = 1`.
- Deep reorgs beyond `CONFIRMATIONS = 6` are out of scope (per brief).

## Known limitations / more time

- Indexer campaign aggregation is event-sourced; would add property tests vs `eth_call` at finalized block in CI.
- Relayer fee-bump could use EIP-1559 tips explicitly; currently legacy `gasPrice` on anvil.
- Broader murky-style Merkle trees in invariant handlers beyond single-leaf honest claims.
- Formal verification of commitment monotonicity.

## Deliverables

| Doc | Purpose |
|---|---|
| [AUDIT.md](AUDIT.md) | LegacyPayouts review + PoCs |
| [DESIGN.md](DESIGN.md) | Operator leak + dual-chain budget |
| [AI_USAGE.md](AI_USAGE.md) | AI tooling disclosure |
| [docs/](docs/) | HLD, LLD, ADRs |

## Layout

Matches assessment §3.2: `contracts/`, `app/`, `fixtures/`, `chaos/`, `docker-compose.yml`, `Makefile`, `deployments.json`.
