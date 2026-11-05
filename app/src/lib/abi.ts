export const escrowAbi = [
  {
    type: "constructor",
    inputs: [
      { name: "owner_", type: "address" },
      { name: "operator_", type: "address" },
      { name: "guardian_", type: "address" },
      { name: "rootDelay_", type: "uint64" },
      { name: "operatorDelay_", type: "uint64" },
    ],
  },
  {
    type: "function",
    name: "createCampaign",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "endTime", type: "uint64" },
      { name: "maxCommitPerEpoch", type: "uint256" },
      { name: "salt", type: "bytes32" },
    ],
    outputs: [{ name: "campaignId", type: "bytes32" }],
  },
  {
    type: "function",
    name: "proposeRoot",
    stateMutability: "nonpayable",
    inputs: [
      { name: "epoch", type: "uint64" },
      { name: "root", type: "bytes32" },
      { name: "campaignIds", type: "bytes32[]" },
      { name: "newCommitted", type: "uint256[]" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "activateRoot",
    stateMutability: "nonpayable",
    inputs: [{ name: "epoch", type: "uint64" }],
    outputs: [],
  },
  {
    type: "function",
    name: "claimWithSig",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "auth",
        type: "tuple",
        components: [
          { name: "campaignId", type: "bytes32" },
          { name: "creator", type: "address" },
          { name: "cumulativeAmount", type: "uint256" },
          { name: "recipient", type: "address" },
          { name: "relayerFee", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
      { name: "proof", type: "bytes32[]" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setTokenAllowed",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "allowed", type: "bool" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "leaf",
    stateMutability: "view",
    inputs: [
      { name: "campaignId", type: "bytes32" },
      { name: "creator", type: "address" },
      { name: "cumulativeAmount", type: "uint256" },
    ],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "hashClaimAuth",
    stateMutability: "view",
    inputs: [
      {
        name: "auth",
        type: "tuple",
        components: [
          { name: "campaignId", type: "bytes32" },
          { name: "creator", type: "address" },
          { name: "cumulativeAmount", type: "uint256" },
          { name: "recipient", type: "address" },
          { name: "relayerFee", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
    ],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "activeRoot",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "epoch", type: "uint64" },
      { name: "root", type: "bytes32" },
    ],
  },
  {
    type: "function",
    name: "pendingRoot",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "epoch", type: "uint64" },
      { name: "root", type: "bytes32" },
      { name: "activatesAt", type: "uint64" },
    ],
  },
  {
    type: "function",
    name: "ROOT_DELAY",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint64" }],
  },
  {
    type: "function",
    name: "claimedBy",
    stateMutability: "view",
    inputs: [
      { name: "campaignId", type: "bytes32" },
      { name: "creator", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "campaignState",
    stateMutability: "view",
    inputs: [{ name: "campaignId", type: "bytes32" }],
    outputs: [
      { name: "brand", type: "address" },
      { name: "token", type: "address" },
      { name: "endTime", type: "uint64" },
      { name: "maxCommitPerEpoch", type: "uint256" },
      { name: "netDeposited", type: "uint256" },
      { name: "activeCommitted", type: "uint256" },
      { name: "pendingCommitted", type: "uint256" },
      { name: "claimedTotal", type: "uint256" },
      { name: "refunded", type: "uint256" },
    ],
  },
  {
    type: "event",
    name: "CampaignCreated",
    inputs: [
      { name: "campaignId", type: "bytes32", indexed: true },
      { name: "brand", type: "address", indexed: true },
      { name: "token", type: "address", indexed: true },
      { name: "endTime", type: "uint64", indexed: false },
      { name: "maxCommitPerEpoch", type: "uint256", indexed: false },
      { name: "received", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "RootProposed",
    inputs: [
      { name: "epoch", type: "uint64", indexed: true },
      { name: "root", type: "bytes32", indexed: false },
      { name: "activatesAt", type: "uint64", indexed: false },
      { name: "campaignIds", type: "bytes32[]", indexed: false },
      { name: "newCommitted", type: "uint256[]", indexed: false },
    ],
  },
  {
    type: "event",
    name: "RootVetoed",
    inputs: [{ name: "epoch", type: "uint64", indexed: true }],
  },
  {
    type: "event",
    name: "RootActivated",
    inputs: [
      { name: "epoch", type: "uint64", indexed: true },
      { name: "root", type: "bytes32", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Claimed",
    inputs: [
      { name: "campaignId", type: "bytes32", indexed: true },
      { name: "creator", type: "address", indexed: true },
      { name: "recipient", type: "address", indexed: true },
      { name: "cumulativeAmount", type: "uint256", indexed: false },
      { name: "paid", type: "uint256", indexed: false },
      { name: "relayerFee", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Refunded",
    inputs: [
      { name: "campaignId", type: "bytes32", indexed: true },
      { name: "brand", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "OperatorQueued",
    inputs: [
      { name: "newOperator", type: "address", indexed: true },
      { name: "effectiveAt", type: "uint64", indexed: false },
    ],
  },
  {
    type: "event",
    name: "OperatorChanged",
    inputs: [
      { name: "oldOperator", type: "address", indexed: true },
      { name: "newOperator", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "OperatorRevoked",
    inputs: [{ name: "oldOperator", type: "address", indexed: true }],
  },
  {
    type: "event",
    name: "Paused",
    inputs: [{ name: "by", type: "address", indexed: true }],
  },
  {
    type: "event",
    name: "Unpaused",
    inputs: [{ name: "by", type: "address", indexed: true }],
  },
  {
    type: "event",
    name: "TokenAllowed",
    inputs: [
      { name: "token", type: "address", indexed: true },
      { name: "allowed", type: "bool", indexed: false },
    ],
  },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const nrtAbi = [
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
] as const;
