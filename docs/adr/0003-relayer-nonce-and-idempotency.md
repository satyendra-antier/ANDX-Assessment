# ADR-0003: Relayer nonce ownership and exactly-once claims

## Status

Accepted

## Context

Chaos proxies return 504 after broadcasting, or return a hash for a tx that never mines. Resigning under a new nonce can double-submit or stick nonces.

## Decision

- Persist acct4's next nonce in Postgres; treat chain nonce as a lower bound only.
- Store the raw signed transaction bytes with each submission.
- On lost response: poll receipt/mempool; rebroadcast the same raw tx or replace at the **same nonce** with ≥10% fee bump.
- Simulate before first send; never send a claim that would revert.
- Mark job `done` only on receipt `status = 1`.

## Consequences

- Zero wasted reverts from the relayer under raised fault rates.
- Jobs survive app restarts.
