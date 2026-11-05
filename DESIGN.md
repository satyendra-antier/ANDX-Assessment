# DESIGN.md

## 1. The 3 a.m. operator key leak

**Best attack against AndxEscrow.** With a leaked operator key the attacker can only `proposeRoot` within the commitment rules: `newCommitted` cannot exceed `netDeposited - refunded`, cannot jump more than `maxCommitPerEpoch` above `activeCommitted`, and cannot increase after `endTime`. They publish a Merkle root whose leaves assign the maximum feasible commitment to attacker-controlled creator addresses (or colluding creators), wait out `ROOT_DELAY`, then `activateRoot` and claim.

**Maximum loss per campaign (formula).** Let

- `A = activeCommitted`
- `N = netDeposited - refunded`
- `M = maxCommitPerEpoch`
- `ended = (block.timestamp >= endTime)`

If `ended`, commitment cannot increase → **extra loss = 0** beyond amounts already activated for honest creators (those remain claimable). If not ended, one malicious epoch can raise commitment by at most `min(M, N - A)`. After activation, attacker-controlled leaves can claim up to that new commitment, subject to `claimedTotal <= activeCommitted`. So:

\[
L_{\text{one epoch}} = \min(M,\ N - A)
\]

With repeated epochs (if guardian never revokes), each epoch can add another `min(M, N - A')` until `A → N`. Absolute ceiling:

\[
L_{\max} = N - A_{\text{honest already claimable}} \le N
\]

Honest creators with cumulatives already in an **active** root can still claim those amounts; the attacker cannot decrease `A` or steal already-claimed funds. Pending honest roots survive revoke (ADR-0001) but a malicious **pending** root can still activate unless vetoed.

**How fast must the guardian act?** Within **`ROOT_DELAY`** (here 3600s) of a malicious `RootProposed` to call `vetoRoot`, **or** immediately `revokeOperator` / `pause` (pause still allows veto). Revoke stops further proposals but does **not** clear an already-pending root — veto is still required before `activatesAt`.

**Tooling.** Indexer alerts on `RootProposed` with commitment deltas; paging within minutes; guardian hot-wallet or multisig that can `vetoRoot` + `revokeOperator` in one scripted bundle; optional auto-veto policy if `newCommitted - activeCommitted` exceeds an off-chain risk threshold.

**Contract changes to shrink loss further.** (1) Cap total operator-driven commitment growth per calendar day. (2) Require guardian co-sign / dual approval for proposals above a threshold. (3) On `revokeOperator`, auto-veto pending roots (trade-off vs ADR-0001). (4) Bond the operator with slash on veto-of-malicious-root. (5) Shorter `ROOT_DELAY` only if guardian automation is proven.

## 2. One budget, two chains (no bridge)

**Goal.** One USD 10,000 logical budget usable on chain A and chain B without bridging principal.

**Approach — off-chain global allocator + per-chain escrows.** Deploy identical escrow instances on A and B. An off-chain **budget oracle / allocator** (the existing earnings pipeline) maintains:

\[
\text{GlobalAvailable} = 10\,000 - \sum_{\text{chains}} \text{activatedCommitted}_c
\]

When publishing epoch roots, it assigns `newCommitted` slices such that \(\sum_c (C_c^{\text{new}} - C_c^{\text{old}}) \le \text{GlobalAvailable}\). Each chain’s contract still enforces local solvency against that chain’s deposits. Brands fund each chain with a **working inventory** (e.g. 6k on A, 6k on B) greater than expected local load but the allocator never activates more than 10k globally. Excess local deposits are refundable after campaign end.

**What breaks.**

- **Deep reorg on one chain** after activation: indexer must rewind local state; if the allocator already counted that commitment toward the global cap and the other chain spent the remainder, a reorg that removes claims but not the allocator’s memory can desync. Mitigate with `CONFIRMATIONS` before counting activation toward the global budget (same 6-block idea), and never spend global headroom on unfinalized roots.
- **Chain halt:** funds and unclaimed commitments on the halted chain are stuck; the other chain can continue only up to remaining global headroom **excluding** the halted chain’s activated commitments (those remain reserved so creators are not double-paid if the halt resumes). If you free the halted chain’s reservation too early, a restart could overpay globally.
- **No bridge** means you cannot automatically rebalance inventory; brands must manually top up the hot chain or accept failed local claims when local deposits are exhausted even if global headroom remains.
