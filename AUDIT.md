# Security Review — LegacyPayouts.sol

Scope: `contracts/src/audit/LegacyPayouts.sol` as if deployed behind an ERC1967 UUPS proxy with arbitrary ERC-20 brand tokens. Findings ordered by severity. PoCs for High/Critical live in `contracts/test/audit/LegacyPayouts.t.sol`.

---

## Critical

### C-01 — Missing initializer protection on UUPS implementation

**Severity:** Critical — uninitialized implementation / re-initialization can seize upgrade authority.  
**Lines:** `initialize` (54–63), `_authorizeUpgrade` (83).  
**Scenario:** `initialize` has no `initializer` / `reinitializer` modifier and does not disable initializers in the implementation constructor. An attacker calls `initialize` on the naked implementation (or re-inits if the proxy path is ever exposed), sets themselves as `owner`, and authorizes malicious upgrades via UUPS.  
**Fix:** Use OpenZeppelin `Initializable`, call `_disableInitializers()` in the implementation constructor, and mark `initialize` with `initializer`.  
**PoC:** `test_C01_uninitializedImplementation_takeover`

---

## High

### H-01 — `proposeRoot` commits immediately; `vetoRoot` does not roll back commitment

**Severity:** High — guardian veto fails to restore budget; refunds and solvency break.  
**Lines:** `proposeRoot` 123–133; `vetoRoot` 144–151; `refund` 110–119.  
**Scenario:** Operator proposes `newCommitted = budget`. Commitment is written immediately. Guardian vetoes the pending root (clears `pendingRoot` only). `committed` stays inflated, so `refund` computes `budget - (committed - claimed) = 0` and creators cannot be paid against a never-activated root while brand funds are stranded. Combined with a malicious operator this is a permanent grief / lock.  
**Fix:** Keep proposed commitment in pending storage; apply to `committed` only on `activateRoot`; restore on veto.  
**PoC:** `test_H01_vetoLeavesInflatedCommitment`

### H-02 — Claim accounting stores net-after-fee against gross Merkle cumulative

**Severity:** High — repeated claims drain escrow beyond intended cumulative.  
**Lines:** `claim` 154–166; `_chargeFee` 201–205.  
**Scenario:** Leaf encodes gross `cumulativeAmount`. Payout = `cumulative - claimed[id][user]`. After fee, code does `claimed += amount` (net). The fee gap remains claimable: second `claim` with the same leaf pays the fee remainder (and accrues more fees).  
**Fix:** Always advance `claimed[id][user]` by the **gross** payout (`cumulativeAmount`), not the net transfer.  
**PoC:** `test_H02_claimFeeAccountingDoublePay`

### H-03 — `migrateCreator` zeroes source claim allowing full re-claim

**Severity:** High — double payout for the same earnings.  
**Lines:** `migrateCreator` 169–174.  
**Scenario:** After claiming, creator migrates to a new address (moves claim record). Source `claimed` is set to 0, so the same Merkle leaf can be claimed again from the original address.  
**Fix:** Make migration owner/operator-gated with signature proofs, or burn the old identity permanently (e.g. map creator → alias without clearing earned entitlement on the leaf identity).  
**PoC:** `test_H03_migrateCreatorDoubleClaim`

### H-04 — `topUp` credits `amount` instead of tokens received

**Severity:** High — fee-on-transfer tokens inflate `budget` beyond balance.  
**Lines:** `topUp` 102–108 (contrast `fund` 86–99 which uses balance delta).  
**Scenario:** Brand tops up with FOTX. Escrow receives `amount - 1%` but `budget += amount`. Later commitments/refunds assume solvency that does not exist.  
**Fix:** Use the same balance-delta accounting as `fund`.  
**PoC:** `test_H04_topUpIgnoresFeeOnTransfer`

### H-05 — Voucher replay via ECDSA signature malleability

**Severity:** High — same logical voucher redeemable twice.  
**Lines:** `redeemVoucher` 177–198; `_recover` 207–218.  
**Scenario:** `usedVouchers` is keyed by `keccak256(signature)`, not by the voucher digest / nonce. Secp256k1 allows `(r,s,v)` and `(r,n-s,v')` to recover the same signer. Attacker malleates after first redeem and drains again. No low-s check.  
**Fix:** Mark `usedVouchers[digest]` (or `(creator,nonce)`), reject high-s signatures.  
**PoC:** `test_H05_voucherSignatureMalleability`

---

## Medium

### M-01 — Unchecked `transferFrom` in `topUp`

**Severity:** Medium — non-standard ERC-20s (no return data) or silent failures corrupt accounting.  
**Lines:** 106.  
**Scenario:** Tokens that return `false` instead of reverting leave `budget` increased with no tokens pulled.  
**Fix:** `SafeERC20.safeTransferFrom`.

### M-02 — Refund formula ignores pending commitment semantics / can underflow conceptually

**Severity:** Medium — `budget - (committed - claimedTotal)` with pending-committed-already-applied (H-01) strands funds; also unsafe with fee-on-transfer shortfalls.  
**Lines:** 115–117.  
**Fix:** Track `netDeposited`, `refunded`, and reserved = max(active, pending) explicitly.

### M-03 — Operator can be set instantly with no delay / no event discipline

**Severity:** Medium — compromised owner rotates operator without timelock; limited monitoring surface.  
**Lines:** `setOperator` 66–69.  
**Fix:** Timelocked rotation with events (as in AndxEscrow).

### M-04 — `redeemVoucher` reduces `budget` while bypassing Merkle commitment controls

**Severity:** Medium — operator-signed vouchers spend brand budget outside root delay / veto path.  
**Lines:** 177–198.  
**Scenario:** Compromised operator drains residual uncommitted budget via vouchers immediately.  
**Fix:** Cap vouchers, delay them, or remove in favor of Merkle-only payouts.

---

## Low / Informational

### L-01 — `ecrecover` without low-s / address(0) checks on vouchers

Covered under H-05 for malleability; also reject `address(0)`.

### L-02 — No reentrancy guard on token transfers

HOOK-like tokens can reenter `claim` / `redeemVoucher` before state settles (CEI partially present but events after external calls). Prefer checks-effects-interactions + `ReentrancyGuard`.

### I-01 — `feeBps` mutable only at init — OK

Not an issue by itself.

### I-02 — Patterns that look scary but are not (alone) exploitable

- Using `abi.encodePacked` for Merkle leaves is brittle with dynamic types but here types are fixed-width — not a collision bug by itself.
- Anyone can call `activateRoot` after delay — intentional.
- `revokeOperator` sets operator to zero — stops new roots/vouchers; not a theft path alone.

---

## Combined attacks

**H-01 + M-04:** Operator proposes max commitment (locks refunds even if vetoed) and drains remaining perceived budget via vouchers before veto.  
**H-02 + H-03:** Fee-gap re-claim plus migration multiplies payouts per leaf.  
**C-01 + owner powers:** Implementation takeover → upgrade to empty the proxy.
