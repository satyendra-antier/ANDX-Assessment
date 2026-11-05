# ANDX Web3 Engineering Assessment: Campaign Escrow and Payout Rail

| | |
|---|---|
| **Role** | Web3 Engineer (smart contracts, indexing, on-chain integrations) |
| **Time limit** | 48 hours from when you receive this document |
| **Expected effort** | **14 to 18 focused hours** for a strong engineer. The scope is deliberately small. The difficulty is in getting it right under attack and under failure. |
| **What you get** | The `web3-kit/` folder: the required contract interface, test tokens, the chaos RPC proxy, fixtures, and the contract you will audit. |

---

## 1. The problem

ANDX runs clipping campaigns. A brand locks a budget. Creators post short clips and earn money for verified views. Off-chain systems compute each creator's **cumulative earnings**. An **operator** key publishes those earnings on-chain as a Merkle root. Creators **claim** what they are owed, directly or **gaslessly through a relayer**.

Three things make this hard, and this assessment is about exactly these three:

1. **The contract must stay solvent and pay nobody twice**, even with fee-on-transfer and non-standard tokens, callback tokens, malformed signatures and a **malicious operator**.
2. **The off-chain view of the chain must stay correct** through short reorgs, lagging RPC endpoints, rate limits, dropped connections and crashes at any instant.
3. **Every claim transaction we relay must land exactly once**, even when the RPC loses the response to a send, or silently drops a transaction it said it accepted.

There is also a security review of an older payout contract, and a short design note.

---

## 2. What you will build

```
                 brands (fund, refund)         creators / relayer (claim)
                          |                               |
                          v                               v
               +---------------------------------------------------+
               |  AndxEscrow (your contract, Part 1)               |
               |  test tokens from the kit: USDX, FOTX, NRT, HOOK  |
               +---------------------------------------------------+
                          ^  anvil, chain id 31337, port 8545
                          |
          +---------------+----------------+
          |                                |
   chaos-primary :9545              chaos-replica :9546
   (sometimes 1-4 blocks behind)    (always 3+ blocks behind)
          ^                                ^
          +---------------+----------------+
                          |   RPC_URLS=http://chaos-primary:9545,http://chaos-replica:9546
          +---------------+-----------------------------+
          |  app: indexer (Part 3) + sender (Part 4)     |
          |                    |                        |
          |                Postgres                     |
          +---------------------------------------------+
```

| Part | What | Points |
|---|---|---|
| 1 | `AndxEscrow` contract | 25 |
| 2 | Foundry invariant and fuzz suite | 12 |
| 3 | Reorg-safe, crash-safe indexer | 20 |
| 4 | Exactly-once claim relayer | 10 |
| 5 | Security review of `LegacyPayouts.sol` | 20 |
| 6 | `DESIGN.md` (two questions) | 8 |
| | Engineering quality: README, structure, tests of off-chain code, commit history | 5 |
| | **Total** | **100** |

A correct, well-tested smaller submission beats a complete-looking one with a solvency bug. If you run short of time, finish Parts 1, 2 and 5 properly first.

---

## 3. Setup, layout and the commands we run

### 3.1 Stack

| Area | Rule |
|---|---|
| Contracts | Solidity `^0.8.24`, **Foundry**. OpenZeppelin v5 is allowed and encouraged. |
| Off-chain | **TypeScript** (Node 20+ or Bun), viem or ethers v6. |
| Database | **Postgres 16**. Database `andx`, user `andx`, password `andx`. |
| Chain | One **anvil**: `--chain-id 31337 --block-time 1 --accounts 15 --port 8545` with the default mnemonic. Interval mining (`--block-time 1`) is required. |
| RPC | The `app` reaches the chain **only** through the two chaos proxies, given as `RPC_URLS=http://chaos-primary:9545,http://chaos-replica:9546`. `make deploy`, `make seed` and `make publish` may talk to anvil on 8545 directly. |
| Host ports | These must be published on `localhost`, because our test harness runs on the host: anvil **8545**, chaos-primary **9545**, chaos-replica **9546**, Postgres **5432**. |
| Amounts | Integer token units everywhere (all tokens have 6 decimals). No floats for amounts anywhere. |
| Paid services | None. No testnets, no paid RPCs, no paid APIs. |

### 3.2 Repository layout (required, our hidden tests depend on it)

```
contracts/                        Foundry project (forge test must pass from here)
  src/AndxEscrow.sol              your contract, `contract AndxEscrow`
  src/interfaces/IAndxEscrow.sol  copied UNCHANGED from the kit
  src/tokens/MockTokens.sol       copied UNCHANGED from the kit
  src/audit/LegacyPayouts.sol     copied UNCHANGED from the kit
  test/                           your tests
  test/audit/                     your audit proofs of concept (so `forge test` runs them)
app/                              indexer and relayer (any structure, one or two processes)
fixtures/                         copied UNCHANGED from the kit
chaos/chaos-proxy.mjs             copied UNCHANGED from the kit
docker-compose.yml                exactly five services: anvil, chaos-primary, chaos-replica, postgres, app
Makefile
deployments.json                  written by `make deploy`
README.md  DESIGN.md  AUDIT.md  AI_USAGE.md
```

`deployments.json` must have exactly this shape (addresses checksummed or lowercase):

```json
{ "AndxEscrow": "0x...", "USDX": "0x...", "FOTX": "0x...", "NRT": "0x...", "HOOK": "0x...", "deploymentBlock": 12 }
```

Our hidden Foundry tests are copied into `contracts/test/hidden/` and deploy your contract with `deployCode("AndxEscrow.sol:AndxEscrow", abi.encode(owner, operator, guardian, rootDelay, operatorDelay))`. They talk to it only through `IAndxEscrow`, and they must compile with your `foundry.toml`. Note that `campaignState` returns nine values, so use named return variables or `via_ir`.

### 3.3 Commands we run (exactly these, from a clean checkout)

| Command | Must do |
|---|---|
| `make up` | Start all five services. Idempotent. |
| `make deploy` | Deploy the four kit tokens and `AndxEscrow(owner=acct0, operator=acct1, guardian=acct2, rootDelay=3600, operatorDelay=172800)`, allowlist USDX, FOTX and NRT (not HOOK), and write `deployments.json`. |
| `make seed` | Mint and create campaigns K1, K2, K3 from `fixtures/campaigns.json` (Appendix B). |
| `make publish` | Publish epochs 1 to 4 from `fixtures/epochs.json`: propose, skip `ROOT_DELAY` with `evm_increaseTime`, activate, in order. A plain script is fine. Blocks until done. Exit code 0 on success. |
| `make claim-all` | Enqueue one `claimWithSig` per leaf of the active root (each creator signs; relayer is acct4; `relayerFee = 0`; recipient is the creator) for the `app` to relay. Blocks until all are done or failed. Exit code 0 only if all succeeded. |
| `make test` | `forge test` (including invariants and audit PoCs) and your off-chain tests. |
| `make down` | Stop everything and delete volumes. |

The `app` service must be a **long-running compose service with exactly that name**. We stop it with `docker compose kill -s SIGKILL app` at random moments and restart it with `docker compose up -d app`.

---

## 4. Part 1: the `AndxEscrow` contract (25 points)

Implement `web3-kit/src/interfaces/IAndxEscrow.sol` **exactly**: function names, argument order, events, views, and the constructor `constructor(address owner_, address operator_, address guardian_, uint64 rootDelay_, uint64 operatorDelay_)`. You may add functions. You may not change or remove required ones.

### 4.1 Campaigns

1. `createCampaign(token, amount, endTime, maxCommitPerEpoch, salt)` creates and funds a campaign in one call. `campaignId = keccak256(abi.encode(msg.sender, salt))`. It reverts if the id exists, the token is not allowlisted, `amount == 0`, `endTime <= block.timestamp`, or nothing was received.
2. **Credit what you actually received** (balance difference), never the `amount` argument. FOTX burns 1% on every transfer.
3. NRT returns nothing from `transfer`, `transferFrom` and `approve`, like USDT. It must work.
4. `netDeposited` is what was received. There is no platform fee in this contract.
5. HOOK calls back into opted-in recipients after every transfer. `make deploy` does not allowlist it, but our tests do, to attack you.

### 4.2 Roots

1. Only the current operator calls `proposeRoot(epoch, root, campaignIds, newCommitted)`.
   - `epoch` must equal `lastEpoch() + 1`. The first epoch is `1`; epoch `0` is invalid. A vetoed or discarded epoch still counts as used, so the next proposal uses the next number. At most one root is pending at a time.
   - `root` must be non-zero. It is one Merkle root over all campaigns. The leaf for a creator in a campaign is `keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(escrow), campaignId, creator, cumulativeAmount))))`, which is what OpenZeppelin `StandardMerkleTree` produces for the value types `["uint256","address","bytes32","address","uint256"]`. Your `leaf()` view must return exactly this.
   - `campaignIds` must be **strictly increasing** (as `uint256`). `newCommitted[i]` is the new total committed for that campaign: the sum of all its creators' cumulative amounts in this root. Unlisted campaigns keep their current committed amount.
2. For every listed campaign, revert unless all of these hold:
   - `newCommitted >= activeCommitted` (commitments never decrease)
   - `newCommitted - activeCommitted <= maxCommitPerEpoch` (a per-root limit on increases, set by the brand)
   - `newCommitted <= netDeposited - refunded`
   - if `block.timestamp >= endTime`, the commitment cannot increase
3. `activateRoot(epoch)`: anyone, once `block.timestamp >= activatesAt` (proposal time plus `ROOT_DELAY`). It makes the root and its commitments active.
4. `vetoRoot(epoch)`: **guardian only**, while pending. It discards the root and its commitment changes completely.
5. Claims always verify against the **latest active root**. Amounts are cumulative, so a newer root supersedes older ones.

### 4.3 Claims

1. `claim(c, recipient, proof)`: `msg.sender` must be `c.creator`. Pays `c.cumulativeAmount - claimedBy(campaignId, creator)` to `recipient`. Reverts if that is zero.
2. `claimWithSig(auth, signature, proof)`: anyone may submit an **EIP-712** `ClaimAuth` signed by `auth.creator`.
   - Domain: name `"ANDX Escrow"`, version `"1"`, `block.chainid`, the escrow address.
   - Type string: `ClaimAuth(bytes32 campaignId,address creator,uint256 cumulativeAmount,address recipient,uint256 relayerFee,uint256 nonce,uint256 deadline)`.
   - Signatures are 65 bytes `r || s || v`. Reject high-s signatures, and any signature that recovers to `address(0)`.
   - Nonces are **unordered** and per creator (`nonceUsed(creator, nonce)`). A nonce is consumed only by a successful claim. `block.timestamp > deadline` reverts.
   - `relayerFee` goes to `msg.sender`, the rest of the payout to `auth.recipient`. `relayerFee > payout` reverts.
3. For every claim: a campaign's `claimedTotal` may never exceed its `activeCommitted`, even if the root contains leaves that sum to more. Revert instead.
4. `recipient` may not be `address(0)`. Payouts in FOTX lose 1% in transfer, and the creator bears it. Accounting is always in units the escrow **sent**.

### 4.4 Refunds

`refundUnallocated(campaignId)`: brand only, once `block.timestamp >= endTime + ROOT_DELAY`. It pays `netDeposited - refunded - max(activeCommitted, pendingCommitted)` and returns the amount. Money committed in an active **or pending** root stays claimable forever. A second call returns only what is newly unallocated (normally `0`, without reverting).

### 4.5 Operator rotation and emergencies

| Function | Caller | Effect |
|---|---|---|
| `queueOperator(newOperator)` | owner | Queues a new operator, effective after `OPERATOR_DELAY`. |
| `applyOperator()` | anyone | Applies the queued operator once the delay has passed. |
| `revokeOperator()` | guardian or owner | Sets the operator to `address(0)` immediately. |
| `pause()` | guardian or owner | Every state-changing function reverts except `vetoRoot`, `revokeOperator`, `pause` and `unpause`. |
| `unpause()` | owner | Resumes. |

You decide what happens to a root that is **pending** when the operator is rotated or revoked. Both answers can be right. Make the choice deliberate, enforce it, test it, and state it in your README.

### 4.6 Non-functional

- Safe against reentrancy through HOOK on every path that transfers tokens.
- No unbounded loops over user-controlled data in claim or refund paths.
- Emit the interface events on every state change (Part 3 depends on them).
- Not upgradeable.

---

## 5. Part 2: invariant and fuzz suite (12 points)

Write **Foundry stateful invariant tests** with handlers. Random sequences must include proposals (honest **and adversarial**: an operator proposing arbitrary leaves within the commitment rules), vetoes, activations, direct claims, signed claims (including replays), refunds and time warps, across USDX, FOTX and NRT.

These must hold after every call:

| Id | Invariant |
|---|---|
| I1 | **Solvency per token:** `token.balanceOf(escrow) >= sum over its campaigns of (netDeposited - refunded - claimedTotal)` |
| I2 | **Commitments:** `claimedTotal <= activeCommitted <= netDeposited - refunded`, and `pendingCommitted <= netDeposited - refunded` |
| I3 | **No double pay:** total paid for a (campaign, creator), including relayer fees, never exceeds the largest cumulative amount ever **activated** for them |
| I4 | **Isolation:** actions on one campaign never change another campaign's accounting |
| I5 | **Refunds never strand creators:** after any refund, every active and pending commitment is still fully payable |
| I6 | **Single use:** each `(creator, nonce)` succeeds at most once |

Also write targeted tests for each rule in Part 1, a HOOK reentrancy test, and one test for your decision in 4.5. Run with at least `runs = 256` and `depth = 100`, and put the numbers and the call metrics (`show_metrics = true`) in your README.

How the 12 points split:

| Points | For |
|---|---|
| 4 | Handlers cover propose, activate, claim and refund with at least one non-standard token |
| 3 | The adversarial operator and signed-claim replays are in the handlers |
| 2 | **Exact-equality ghost accounting:** a model of each campaign's numbers that must equal the contract's, not only inequalities |
| 2 | The metrics show real coverage: successful claims, activations and refunds in every run |
| 1 | **A mutation demo:** show (in the README) that your suite fails when you inject a bug into your own contract |

A suite that passes but whose metrics show claims always revert scores low. We also run **our own** invariant suite and adversarial scenario tests against your contract through the interface.

---

## 6. Part 3: the indexer (20 points)

Index every `IAndxEscrow` event into Postgres, through the chaos proxies.

### 6.1 Requirements

1. **Reorg safe.** Store each processed block's number, hash and parent hash. When the chain no longer matches, find the common ancestor, drop everything from orphaned blocks, and re-index the canonical chain. We trigger `anvil_reorg` at depths **1 to 5**, sometimes removing blocks that contained claims or campaigns.
2. **Finality.** `CONFIRMATIONS = 6`. Every reorg we trigger is shallower than that, so finalised data never changes. Reorgs deeper than `CONFIRMATIONS` are **out of scope**. You do not need to repair them.
3. **Crash safe and idempotent.** Events are keyed by `(block_hash, log_index)`. Checkpoints are written in the same database transaction as the data they cover. After `SIGKILL` at any instant and a restart, the database converges to exactly the state it would have reached without the crash: no duplicates, no gaps.
4. **Hostile RPC.** The proxies drop connections, return 429 and 503, and reject `eth_getLogs` spans above 200 blocks. Both endpoints can be behind (6.3). Adapt range sizes, retry with backoff, fail over between endpoints, and **never treat a lagging response as a reorg**.
5. Starts from `deploymentBlock` in `deployments.json` and catches up after downtime.

### 6.2 Required database objects (our checker reads these)

| Object | Columns | Meaning |
|---|---|---|
| `andx_indexer_head` | `head_block bigint, head_hash text, finalized_block bigint, finalized_hash text, updated_at timestamptz` | One row. `head_block` is the newest block you have processed; `finalized_block = head_block - 6` or lower. |
| `andx_events` | `block_number bigint, block_hash text, log_index int, tx_hash text, event_name text, campaign_id text, args jsonb, finalized boolean` | Every canonical event up to `head_block`, including unfinalised ones. Hex values lowercase and `0x`-prefixed; amounts as decimal strings. |
| `andx_campaign_state` | `campaign_id text, net_deposited numeric, active_committed numeric, pending_committed numeric, claimed_total numeric, refunded numeric` | Derived **from finalised events only** (no `eth_call`). Must equal `campaignState(id)` called at `finalized_block`. |

These may be tables or views.

### 6.3 What "lagging" means here, and what to do about it

Each proxy answers from a **visible head**. The replica's visible head is always at least 3 blocks behind the real chain. The primary is usually current, but about **10% of its responses come from a head 1 to 4 blocks behind**. This applies to every method that reads chain state: block number, blocks by number or tag, logs, receipts, transactions, and the block parameter of `eth_call`, `eth_estimateGas`, `eth_getTransactionCount`, `eth_getBalance`, `eth_getCode` and `eth_getStorageAt`. So:

- Track the **highest head you have seen** from any endpoint. Treat any response from a lower head as stale, not as a reorg.
- A block that is "missing" at a height you have already processed is not proof of a reorg. Only a **different hash** at a height, seen from a response at or above your highest head, is.
- A missing receipt or a lower nonce in one response is not proof of anything. Confirm against a later response before acting.

---

## 7. Part 4: exactly-once claim relayer (10 points)

The `app` relays every `claimWithSig` enqueued by `make claim-all`, from the relayer key (acct4). Jobs are stored in Postgres, so they survive restarts.

Requirements:

1. **Own nonce management** for acct4, persisted, so restarts never reuse or skip a nonce. Use the chain's nonce only as a lower bound (see 6.3).
2. **Lost responses.** The proxy can broadcast your transaction and then return HTTP 504. Interpret `nonce too low`, `already known` and `replacement transaction underpriced` correctly. Never re-sign the same claim with a new nonce while the first may still land.
3. **Silently dropped transactions.** The proxy can return a valid hash for a transaction that will never be mined. Detect it and get the claim mined: rebroadcast the same signed transaction, or replace it at the same nonce with a fee bump of at least 10%.
4. **No wasted reverts.** A relayed transaction that reverts on-chain is a defect: for example a claim sent twice under two nonces, or a claim whose nonce was already used. Simulate before you send, and design so that retries cannot produce a revert.
5. A job is `done` once you have seen its receipt with `status = 1`. We do not reorg the chain during relayer tests.

What we measure: every job done, every creator paid exactly their cumulative amount, **zero reverted transactions from acct4**, and no stuck nonces. We measure it with lost and dropped sends turned up and the `app` killed at random moments.

---

## 8. Part 5: security review of `LegacyPayouts.sol` (20 points)

`web3-kit/audit/LegacyPayouts.sol` is an older payout contract we are replacing. Review it as if it were about to hold real funds behind an ERC1967 proxy, and as if any ERC-20 a brand chooses could be used with it.

- It contains **at least six issues of Medium severity or higher**. Some are easy to find. Some are logic errors that only show up when you reason across several functions.
- It also contains patterns that look dangerous but are **not exploitable**. Reporting those as High or Critical costs points. Precision matters as much as recall.
- For each finding: title, severity (Critical, High, Medium, Low, Informational) with a one-line justification, affected lines, exploit scenario, and fix.
- Write a **passing Foundry proof of concept** in `contracts/test/audit/` for every finding you rate **High or Critical**. A High or Critical finding without a working PoC counts half. Medium and lower findings need a clear written scenario only.
- Where two findings combine into a worse attack, say so.
- Put it all in `AUDIT.md`, ordered by severity. Do not fix the contract in place.

---

## 9. Part 6: `DESIGN.md` (8 points, at most one page)

Answer concretely. Formulas and numbers beat adjectives.

1. **The 3 a.m. key leak.** The operator key leaks. Against **your** contract: what is the attacker's best strategy, what is the maximum loss per campaign as a formula over the contract's state, how fast must the guardian act, what tooling makes that realistic, and what would you change in the contract to reduce the loss further?
2. **One budget, two chains.** A brand wants one USD 10,000 budget usable by creators on two chains, without a bridge. How do you keep total payouts under the budget, and what breaks if one chain halts or reorgs deeply?

---

## 10. How we evaluate

1. **Hidden contract tests.** Our invariant suite (including an adversarial operator), and scenario tests covering:
   - weird tokens and reentrancy through HOOK
   - cumulative claims, and leaves that sum above the commitment
   - epoch, veto and delay rules
   - refunds against pending roots
   - signature replay across chains and contracts, plus malleable and zero-address signatures
   - pause, rotation, and input validation
2. **Indexer under chaos.** Reorgs of depth 1 to 5, `SIGKILL` of the `app` at random points, proxy fault rates raised. After each round we compare `andx_events` with the chain up to your `head_block`, and `andx_campaign_state` with the chain at your `finalized_block`.
3. **Relayer under chaos.** `make claim-all` with lost and dropped sends raised and the `app` killed several times. Then we check payouts, reverted transactions and nonces.
4. **Audit.** Findings and PoCs against our answer key, including false positives.
5. **A code walkthrough call** (about 75 minutes) after the review. You will be asked to explain and change your code live.

---

## 11. Deliverables and rules

### 11.1 Checklist

- [ ] Private Git repository with the layout in 3.2, and a commit history that shows how you worked (please do not squash)
- [ ] All `make` targets in 3.3 work from a clean checkout
- [ ] `README.md`: architecture, decisions and trade-offs (including 4.5), invariant run counts, metrics and mutation demo, **Assumptions**, known limitations, what you would do with more time
- [ ] `AUDIT.md`, with PoCs in `contracts/test/audit/`
- [ ] `DESIGN.md`
- [ ] `AI_USAGE.md`: which AI tools you used and for what

### 11.2 Rules

- **AI coding tools are allowed.** You must be able to explain and modify every line without help in the walkthrough call. Contract code you cannot explain counts heavily against you.
- The work must be your own. Do not share this assessment.
- No real funds and no real private keys. Use the anvil default accounts.
- If something is unclear, make a reasonable assumption, write it under **Assumptions** in your README, and continue.
- If you run out of time, stop and write down precisely what is missing. An honest partial submission beats a dishonest complete one.

---

## Appendix A: accounts

Default anvil mnemonic (`test test test test test test test test test test test junk`), `--accounts 15`.

| Index | Address | Role |
|---|---|---|
| 0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | Owner and deployer |
| 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | Operator |
| 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | Guardian |
| 4 | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` | Relayer |
| 5 | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` | Brand: Nimbus |
| 6 | `0x976EA74026E726554dB657fA54763abd0C3a0aa9` | Brand: Arcadia |
| 7 | `0x14dC79964da2C08b23698B3D3cc7Ca32193d9955` | Creator: alice |
| 8 | `0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f` | Creator: bob |
| 9 | `0xa0Ee7A142d267C1f36714E4a8F75612F20a79720` | Creator: carol |
| 10 | `0xBcd4042DE499D14e55001CcbB24a551F3b954096` | Creator: dave |
| 11, 12, 14 | (anvil defaults) | Used by our test harness |
| 13 | `0x1CBd3b2770909D4e10f157cABC84C7264073C9Ec` | Attacker (our tests) |

## Appendix B: campaigns and fixtures

Brand names (Nimbus, Arcadia) and creator names are fictional.

`fixtures/campaigns.json` (seed with `make seed`, `endTime = seed block timestamp + 604800`):

| Key | Brand | Token | Amount (units) | Received | `maxCommitPerEpoch` | `salt` |
|---|---|---|---|---|---|---|
| K1 | Nimbus (5) | USDX | 1,000,000,000 | 1,000,000,000 | 400,000,000 | `keccak256(bytes("nimbus-swaps"))` |
| K2 | Arcadia (6) | FOTX | 500,000,000 | 495,000,000 | 120,000,000 | `keccak256(bytes("arcadia-s4"))` |
| K3 | Nimbus (5) | NRT | 300,000,000 | 300,000,000 | 270,000,000 | `keccak256(bytes("nimbus-nrt"))` |

`fixtures/epochs.json` lists, for epochs 1 to 4, every non-zero leaf `(campaign, creator, cumulative)`. Committed totals per epoch:

| Epoch | K1 | K2 | K3 |
|---|---|---|---|
| 1 | 300,000,000 | 120,000,000 | 180,000,000 |
| 2 | 700,000,000 | 240,000,000 | 290,000,000 |
| 3 | 900,000,000 | 360,000,000 | 290,000,000 |
| 4 | 1,000,000,000 | 480,000,000 | 300,000,000 |

After `make publish` and `make claim-all`, every creator's `claimedBy` equals their epoch 4 cumulative amount, and the escrow holds 0 USDX, 15,000,000 FOTX and 0 NRT.

## Appendix C: interface

The full interface is `web3-kit/src/interfaces/IAndxEscrow.sol`. Besides the functions described above, your contract must provide these views:
- `campaignState`, `claimedBy`, `activeRoot`
- `pendingRoot` (returns zeros when nothing is pending)
- `lastEpoch`, `owner`, `operator`, `guardian`, `queuedOperator`, `paused`, `tokenAllowed`, `ROOT_DELAY`, `OPERATOR_DELAY`, `nonceUsed`, `leaf`
- `hashClaimAuth` (the full EIP-712 digest)

`pendingCommitted` is the pending root's committed amount if the pending root lists the campaign, otherwise `activeCommitted`.

## Appendix D: chaos proxy

`web3-kit/chaos/chaos-proxy.mjs` (Node 20+, no dependencies). Run it unmodified, two instances:

```
UPSTREAM=http://anvil:8545 PORT=9545 LAG_BLOCKS=0 SEED=1 node chaos-proxy.mjs   # chaos-primary
UPSTREAM=http://anvil:8545 PORT=9546 LAG_BLOCKS=3 SEED=2 node chaos-proxy.mjs   # chaos-replica
```

| Fault | Default | Behaviour |
|---|---|---|
| Visible head | `LAG_BLOCKS`, plus 1 to 4 extra blocks on 10% of requests (on **both** endpoints) | Applied to every head-reading method listed in 6.3. `latest`, `pending`, `safe` and `finalized` all mean the visible head. |
| Dropped connection | 3% | Socket closed, no response |
| HTTP 429 | 5% | `Retry-After: 1` |
| HTTP 503 | 3% | |
| Lost send | 15% of sends | Transaction broadcast, client gets HTTP 504 |
| Dropped send | 5% of sends | Client gets the correct hash, transaction is dropped from the mempool and never mined |
| Log range | 200 blocks | Larger `eth_getLogs` spans return JSON-RPC error `-32005` |

We change these at runtime with `POST /admin/config` (JSON body with any of the fields above, for example `{"lostSendRate":0.4}`). `GET /admin/config` shows the current settings. Test against higher rates yourself.
