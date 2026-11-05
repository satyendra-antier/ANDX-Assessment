# ADR-0001: Pending root survives operator rotate/revoke

## Status

Accepted

## Context

Section 4.5 asks what happens to a pending root when the operator is rotated or revoked. Both answers can be right if deliberate, enforced, and tested.

## Decision

Pending roots are **preserved**. `applyOperator` and `revokeOperator` change only the operator (and clear any queue on revoke). Anyone may still call `activateRoot` after `activatesAt`; guardian may still `vetoRoot`.

## Consequences

- Creators are not stranded if a proposal was honest and the operator key is then revoked.
- A malicious pending root remains until guardian veto or activation — guardian tooling must react within `ROOT_DELAY`.
- After revoke, `operator == address(0)` so no new proposals until a new operator is queued and applied by owner.
