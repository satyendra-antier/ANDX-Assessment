# ADR-0002: Atomic indexer checkpointing

## Status

Accepted

## Context

The app is SIGKILL'd at random. Events must be idempotent and crash-safe. Lagging chaos RPCs must not be mistaken for reorgs.

## Decision

1. Key events by `(block_hash, log_index)`.
2. Persist processed blocks with `(number, hash, parent_hash)`.
3. Update `andx_indexer_head` in the **same database transaction** as the events for those blocks.
4. Track `maxSeenHead` across endpoints; only treat a **different hash** at a height from a response with head ≥ maxSeenHead as a reorg.
5. `CONFIRMATIONS = 6`; campaign aggregates derive from finalized events only.

## Consequences

- Restart after SIGKILL converges without duplicates or gaps.
- Stale lagging reads never rewind canonical data incorrectly.
