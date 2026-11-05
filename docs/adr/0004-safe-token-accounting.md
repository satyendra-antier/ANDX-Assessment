# ADR-0004: Safe token accounting

## Status

Accepted

## Context

Kit tokens include fee-on-transfer (FOTX), non-returning (NRT), and callback (HOOK) ERC-20s. Hidden tests allowlist HOOK to attack reentrancy.

## Decision

- Use OpenZeppelin `SafeERC20` for all transfers.
- Credit campaigns with **balance delta**, never the `amount` argument.
- Wrap all token-moving entrypoints in `ReentrancyGuard`.
- Track claim/refund accounting in units the escrow **sent** (creator bears FOTX burn on receipt).

## Consequences

- Solvency invariants hold across USDX/FOTX/NRT/HOOK.
- HOOK callbacks cannot re-enter payout paths successfully.
