# Low-Level Design — ANDX Campaign Escrow

## 1. AndxEscrow storage

| Slot / mapping | Meaning |
|---|---|
| `owner`, `operator`, `guardian` | Role addresses |
| `ROOT_DELAY`, `OPERATOR_DELAY` | Immutable delays (seconds) |
| `paused` | Emergency pause flag |
| `_queuedOperator`, `_queuedOperatorEffectiveAt` | Timelocked operator rotation |
| `_lastEpoch` | Highest epoch number ever proposed (including vetoed) |
| `_activeEpoch`, `_activeRoot` | Latest activated Merkle root |
| `_pending` | Pending proposal: epoch, root, activatesAt, per-campaign commitments |
| `tokenAllowed` | Brand deposit allowlist |
| `_campaigns[id]` | brand, token, endTime, maxCommitPerEpoch, netDeposited, activeCommitted, claimedTotal, refunded |
| `_claimedBy[id][creator]` | Highest cumulative amount already paid |
| `_nonceUsed[creator][nonce]` | Unordered claimWithSig nonces |

### Campaign id

`campaignId = keccak256(abi.encode(brand, salt))`

### Leaf (StandardMerkleTree)

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(chainId, escrow, campaignId, creator, cumulativeAmount))))
```

### Claim payment

`payout = cumulativeAmount - claimedBy[campaign][creator]`  
Require `claimedTotal + payout <= activeCommitted`.  
Accounting uses amounts **sent** by escrow (pre fee-on-transfer loss on recipient side).

### Operator change (ADR-0001)

`applyOperator` / `revokeOperator` do **not** clear `_pending`. Pending roots remain activatable/vetoable.

## 2. Indexer

### Tables

**`andx_indexer_head`** (single row)

| Column | Type |
|---|---|
| head_block | bigint |
| head_hash | text |
| finalized_block | bigint |
| finalized_hash | text |
| updated_at | timestamptz |

Also store parent hashes in `andx_blocks(number, hash, parent_hash)` for reorg walks.

**`andx_events`**

| Column | Notes |
|---|---|
| block_number, block_hash, log_index | Unique key with hash |
| tx_hash, event_name, campaign_id, args jsonb, finalized | Hex lowercase `0x`; amounts decimal strings |

**`andx_campaign_state`**

Derived **only** from finalized events; must match `campaignState` at `finalized_block`.

### Algorithm

1. Poll both RPC URLs; track `maxSeenHead`.
2. Ignore responses whose visible head `< maxSeenHead` (stale, not reorg).
3. From checkpoint, fetch blocks; if hash at height differs **and** response head ≥ maxSeenHead → reorg: delete events/blocks from orphan height upward in one TX, rewind checkpoint.
4. `eth_getLogs` spans ≤ 200; backoff on 429/503/drop; failover URLs.
5. Write events + head update atomically. `finalized_block = max(0, head_block - 6)`.
6. Recompute campaign aggregates for affected ids from finalized events.

### Start block

`deployments.json.deploymentBlock`.

## 3. Relayer

### Job row

| Field | Meaning |
|---|---|
| id | UUID |
| campaign_id, creator, cumulative, recipient, relayer_fee, nonce, deadline, signature, proof | claimWithSig args |
| status | pending / submitted / done / failed |
| tx_hash, raw_tx, gas_price, nonce_used | submission state |
| updated_at | |

### Nonce manager

Persist `relayer_nonce` (acct4). On start: `nonce = max(persisted, eth_getTransactionCount(latest lower-bound confirmed carefully))`. Never reuse; never skip while a tx may be in-flight.

### State machine

```
pending → (simulate ok) → sign+send → submitted
submitted → receipt status=1 → done
submitted → 504 / unknown → wait → getTransaction / getTransactionCount
  → rebroadcast same raw_tx OR replace same nonce with ≥10% fee bump
submitted → would revert on sim after mined competing nonce → mark failed carefully (should not happen)
```

Never re-sign the same claim under a **new** nonce while the first may still land.

## 4. Compose services

| Service | Port |
|---|---|
| anvil | 8545 |
| chaos-primary | 9545 |
| chaos-replica | 9546 |
| postgres | 5432 |
| app | (internal; long-running) |
