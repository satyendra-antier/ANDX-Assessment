import {
  type Address,
  type Hex,
  encodeAbiParameters,
  keccak256,
  concatHex,
  padHex,
  toHex,
} from "viem";

/** OZ StandardMerkleTree leaf for ["uint256","address","bytes32","address","uint256"] */
export function computeLeaf(
  chainId: bigint,
  escrow: Address,
  campaignId: Hex,
  creator: Address,
  cumulativeAmount: bigint,
): Hex {
  const inner = keccak256(
    encodeAbiParameters(
      [
        { type: "uint256" },
        { type: "address" },
        { type: "bytes32" },
        { type: "address" },
        { type: "uint256" },
      ],
      [chainId, escrow, campaignId, creator, cumulativeAmount],
    ),
  );
  return keccak256(concatHex([inner]));
}

function hashPair(a: Hex, b: Hex): Hex {
  return a.toLowerCase() < b.toLowerCase()
    ? keccak256(concatHex([a, b]))
    : keccak256(concatHex([b, a]));
}

export type MerkleLeaf = {
  campaignId: Hex;
  creator: Address;
  cumulativeAmount: bigint;
  hash: Hex;
};

export type MerkleTree = {
  root: Hex;
  leaves: MerkleLeaf[];
  /** proof for leaf index */
  getProof: (index: number) => Hex[];
};

/** Build a sorted-pair Merkle tree over precomputed leaf hashes (OZ style). */
export function buildMerkleTree(leaves: Omit<MerkleLeaf, "hash">[], chainId: bigint, escrow: Address): MerkleTree {
  const withHash: MerkleLeaf[] = leaves.map((l) => ({
    ...l,
    hash: computeLeaf(chainId, escrow, l.campaignId, l.creator, l.cumulativeAmount),
  }));

  // Keep insertion order for proofs; tree layers use hashes
  const layers: Hex[][] = [withHash.map((l) => l.hash)];
  while (layers[layers.length - 1].length > 1) {
    const prev = layers[layers.length - 1];
    const next: Hex[] = [];
    for (let i = 0; i < prev.length; i += 2) {
      if (i + 1 === prev.length) {
        next.push(prev[i]);
      } else {
        next.push(hashPair(prev[i], prev[i + 1]));
      }
    }
    layers.push(next);
  }

  const root = layers[layers.length - 1][0] ?? padHex("0x0", { size: 32 });

  function getProof(index: number): Hex[] {
    const proof: Hex[] = [];
    let idx = index;
    for (let layer = 0; layer < layers.length - 1; layer++) {
      const current = layers[layer];
      const sibling = idx % 2 === 0 ? idx + 1 : idx - 1;
      if (sibling < current.length) {
        proof.push(current[sibling]);
      }
      idx = Math.floor(idx / 2);
    }
    return proof;
  }

  return { root, leaves: withHash, getProof };
}

export function saltFromString(s: string): Hex {
  return keccak256(toHex(s));
}
