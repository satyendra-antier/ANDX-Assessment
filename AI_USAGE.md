# AI_USAGE.md

## Tools

- **Cursor (Composer / Agent)** — primary coding assistant for scaffolding the Foundry project, `AndxEscrow`, invariant handlers, TypeScript indexer/relayer, Makefile/Compose wiring, ADR/HLD/LLD, AUDIT/DESIGN/README drafts, and iterative test fixes.
- No Copilot / ChatGPT web / Claude.ai standalone sessions were used as the main implementation path for this submission.

## What AI helped with

- Translating `IAndxEscrow` and the assessment brief into a first-pass Solidity implementation (SafeERC20, EIP-712, Merkle leaf matching OZ StandardMerkleTree).
- Drafting stateful invariant handlers and ghost-accounting checks (I1–I6).
- Drafting reorg-safe indexer and exactly-once relayer designs aligned with the chaos-proxy failure modes.
- Structuring `AUDIT.md` findings and Foundry PoCs against `LegacyPayouts.sol`.
- Drafting `DESIGN.md` answers with explicit formulas.

## What was done / verified by the author

- Commitment, pause, and operator-rotation semantics (including ADR-0001: pending roots survive revoke).
- Manual reasoning on LegacyPayouts cross-function bugs (veto vs commitment, fee accounting, migrateCreator, voucher malleability).
- Running `forge test`, Compose harness commands, and fixing failures until green.
- Ensuring secrets (GitHub PAT) are never committed; `token` / `.env` gitignored.

## Walkthrough readiness

Every line in `AndxEscrow.sol`, the indexer checkpointing path, and the relayer nonce state machine was reviewed and can be explained or modified live without AI assistance.
