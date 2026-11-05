import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { computeLeaf, buildMerkleTree } from "./merkle.ts";

describe("merkle", () => {
  it("computes deterministic double-hash leaf", () => {
    const a = computeLeaf(
      31337n,
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      "0x1111111111111111111111111111111111111111111111111111111111111111",
      "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      100n,
    );
    const b = computeLeaf(
      31337n,
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      "0x1111111111111111111111111111111111111111111111111111111111111111",
      "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      100n,
    );
    assert.equal(a, b);
    assert.equal(a.length, 66);
  });

  it("builds single-leaf tree root equal to leaf", () => {
    const tree = buildMerkleTree(
      [
        {
          campaignId: "0x1111111111111111111111111111111111111111111111111111111111111111",
          creator: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
          cumulativeAmount: 100n,
        },
      ],
      31337n,
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    );
    assert.equal(tree.root, tree.leaves[0].hash);
    assert.deepEqual(tree.getProof(0), []);
  });
});
