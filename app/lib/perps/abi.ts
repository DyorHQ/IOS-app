// Subset of the Perpl Exchange ABI (github.com/PerplFoundation/dex-sdk, crates/sdk/abi/dex/Exchange.json). Generated; do not edit.
export const perplExchangeAbi = [
 {
  "type": "function",
  "name": "createAccount",
  "stateMutability": "nonpayable",
  "inputs": [
   {
    "name": "amountCNS",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "accountId",
    "type": "uint256"
   }
  ]
 },
 {
  "type": "function",
  "name": "depositCollateral",
  "stateMutability": "nonpayable",
  "inputs": [
   {
    "name": "amountCNS",
    "type": "uint256"
   }
  ],
  "outputs": []
 },
 {
  "type": "function",
  "name": "execOrders",
  "stateMutability": "nonpayable",
  "inputs": [
   {
    "name": "orderDescs",
    "type": "tuple[]",
    "components": [
     {
      "name": "orderDescId",
      "type": "uint256"
     },
     {
      "name": "perpId",
      "type": "uint256"
     },
     {
      "name": "orderType",
      "type": "uint8"
     },
     {
      "name": "orderId",
      "type": "uint256"
     },
     {
      "name": "pricePNS",
      "type": "uint256"
     },
     {
      "name": "lotLNS",
      "type": "uint256"
     },
     {
      "name": "expiryBlock",
      "type": "uint256"
     },
     {
      "name": "postOnly",
      "type": "bool"
     },
     {
      "name": "fillOrKill",
      "type": "bool"
     },
     {
      "name": "immediateOrCancel",
      "type": "bool"
     },
     {
      "name": "maxMatches",
      "type": "uint256"
     },
     {
      "name": "leverageHdths",
      "type": "uint256"
     },
     {
      "name": "lastExecutionBlock",
      "type": "uint256"
     },
     {
      "name": "amountCNS",
      "type": "uint256"
     },
     {
      "name": "maxNegPnlCollatBPS",
      "type": "uint256"
     }
    ]
   },
   {
    "name": "revertOnFail",
    "type": "bool"
   }
  ],
  "outputs": [
   {
    "name": "signatures",
    "type": "tuple[]",
    "components": [
     {
      "name": "perpId",
      "type": "uint256"
     },
     {
      "name": "orderId",
      "type": "uint256"
     }
    ]
   }
  ]
 },
 {
  "type": "function",
  "name": "getAccountByAddr",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "accountAddress",
    "type": "address"
   }
  ],
  "outputs": [
   {
    "name": "accountInfo",
    "type": "tuple",
    "components": [
     {
      "name": "accountId",
      "type": "uint256"
     },
     {
      "name": "balanceCNS",
      "type": "uint256"
     },
     {
      "name": "lockedBalanceCNS",
      "type": "uint256"
     },
     {
      "name": "frozen",
      "type": "uint8"
     },
     {
      "name": "accountAddr",
      "type": "address"
     },
     {
      "name": "positions",
      "type": "tuple",
      "components": [
       {
        "name": "bank1",
        "type": "uint256"
       },
       {
        "name": "bank2",
        "type": "uint256"
       },
       {
        "name": "bank3",
        "type": "uint256"
       },
       {
        "name": "bank4",
        "type": "uint256"
       }
      ]
     }
    ]
   }
  ]
 },
 {
  "type": "function",
  "name": "getExchangeInfo",
  "stateMutability": "view",
  "inputs": [],
  "outputs": [
   {
    "name": "balanceCNS",
    "type": "uint256"
   },
   {
    "name": "protocolBalanceCNS",
    "type": "uint256"
   },
   {
    "name": "recycleBalanceCNS",
    "type": "uint256"
   },
   {
    "name": "collateralDecimals",
    "type": "uint256"
   },
   {
    "name": "collateralToken",
    "type": "address"
   },
   {
    "name": "verifierProxy",
    "type": "address"
   }
  ]
 },
 {
  "type": "function",
  "name": "getMarginFractions",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256"
   },
   {
    "name": "lotLNS",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "perpInitMarginFracHdths",
    "type": "uint256"
   },
   {
    "name": "perpMaintMarginFracHdths",
    "type": "uint256"
   },
   {
    "name": "dynamicInitMarginFracHdths",
    "type": "uint256"
   },
   {
    "name": "oiMaxLNS",
    "type": "uint256"
   },
   {
    "name": "unityDescentThreshHdths",
    "type": "uint256"
   },
   {
    "name": "overColDescentThreshHdths",
    "type": "uint256"
   }
  ]
 },
 {
  "type": "function",
  "name": "getMinAccountOpenCNS",
  "stateMutability": "view",
  "inputs": [],
  "outputs": [
   {
    "name": "minAccountOpenCNS",
    "type": "uint256"
   }
  ]
 },
 {
  "type": "function",
  "name": "getOrder",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256"
   },
   {
    "name": "orderId",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "order",
    "type": "tuple",
    "components": [
     {
      "name": "accountId",
      "type": "uint32"
     },
     {
      "name": "orderType",
      "type": "uint8"
     },
     {
      "name": "priceONS",
      "type": "uint24"
     },
     {
      "name": "lotLNS",
      "type": "uint40"
     },
     {
      "name": "recycleFeeRaw",
      "type": "uint16"
     },
     {
      "name": "expiryBlock",
      "type": "uint32"
     },
     {
      "name": "leverageHdths",
      "type": "uint16"
     },
     {
      "name": "orderId",
      "type": "uint16"
     },
     {
      "name": "prevOrderId",
      "type": "uint16"
     },
     {
      "name": "nextOrderId",
      "type": "uint16"
     },
     {
      "name": "maxNegPnlCollatBPS",
      "type": "uint16"
     }
    ]
   }
  ]
 },
 {
  "type": "function",
  "name": "getOrderIdIndex",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "root",
    "type": "uint256"
   },
   {
    "name": "leaves",
    "type": "uint256[]"
   },
   {
    "name": "numOrders",
    "type": "uint256"
   }
  ]
 },
 {
  "type": "function",
  "name": "getOrderLocks",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "accountId",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "orderLocks",
    "type": "tuple[]",
    "components": [
     {
      "name": "orderLockId",
      "type": "uint32"
     },
     {
      "name": "nextOrderLockId",
      "type": "uint32"
     },
     {
      "name": "prevOrderLockId",
      "type": "uint32"
     },
     {
      "name": "orderType",
      "type": "uint8"
     },
     {
      "name": "lotLNS",
      "type": "uint40"
     },
     {
      "name": "amountCNS",
      "type": "uint80"
     }
    ]
   }
  ]
 },
 {
  "type": "function",
  "name": "getPerpFeeSchedule",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "feeSchedId",
    "type": "uint256"
   },
   {
    "name": "takerFeesPer100K",
    "type": "uint256[8]"
   },
   {
    "name": "makerFeesPer100K",
    "type": "uint256[8]"
   }
  ]
 },
 {
  "type": "function",
  "name": "getPerpOrderLocks",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "accountId",
    "type": "uint256"
   },
   {
    "name": "perpId",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "perpOrderLocks",
    "type": "tuple[]",
    "components": [
     {
      "name": "orderLockId",
      "type": "uint32"
     },
     {
      "name": "nextOrderLockId",
      "type": "uint32"
     },
     {
      "name": "prevOrderLockId",
      "type": "uint32"
     },
     {
      "name": "orderType",
      "type": "uint8"
     },
     {
      "name": "lotLNS",
      "type": "uint40"
     },
     {
      "name": "amountCNS",
      "type": "uint80"
     }
    ]
   }
  ]
 },
 {
  "type": "function",
  "name": "getPerpetualInfo",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "perpetualInfo",
    "type": "tuple",
    "components": [
     {
      "name": "name",
      "type": "string"
     },
     {
      "name": "symbol",
      "type": "string"
     },
     {
      "name": "priceDecimals",
      "type": "uint256"
     },
     {
      "name": "lotDecimals",
      "type": "uint256"
     },
     {
      "name": "linkFeedId",
      "type": "bytes32"
     },
     {
      "name": "priceTolPer100K",
      "type": "uint256"
     },
     {
      "name": "marginTol",
      "type": "uint256"
     },
     {
      "name": "marginTolDecimals",
      "type": "uint256"
     },
     {
      "name": "refPriceMaxAgeSec",
      "type": "uint256"
     },
     {
      "name": "positionBalanceCNS",
      "type": "uint256"
     },
     {
      "name": "insuranceBalanceCNS",
      "type": "uint256"
     },
     {
      "name": "markPNS",
      "type": "uint256"
     },
     {
      "name": "markTimestamp",
      "type": "uint256"
     },
     {
      "name": "lastPNS",
      "type": "uint256"
     },
     {
      "name": "lastTimestamp",
      "type": "uint256"
     },
     {
      "name": "oraclePNS",
      "type": "uint256"
     },
     {
      "name": "oracleTimestampSec",
      "type": "uint256"
     },
     {
      "name": "longOpenInterestLNS",
      "type": "uint256"
     },
     {
      "name": "shortOpenInterestLNS",
      "type": "uint256"
     },
     {
      "name": "fundingStartBlock",
      "type": "uint256"
     },
     {
      "name": "fundingRatePct100k",
      "type": "int16"
     },
     {
      "name": "absFundingClampPctPer100K",
      "type": "uint256"
     },
     {
      "name": "status",
      "type": "uint8"
     },
     {
      "name": "basePricePNS",
      "type": "uint256"
     },
     {
      "name": "maxBidPriceONS",
      "type": "uint256"
     },
     {
      "name": "minBidPriceONS",
      "type": "uint256"
     },
     {
      "name": "maxAskPriceONS",
      "type": "uint256"
     },
     {
      "name": "minAskPriceONS",
      "type": "uint256"
     },
     {
      "name": "numOrders",
      "type": "uint256"
     },
     {
      "name": "ignOracle",
      "type": "bool"
     }
    ]
   }
  ]
 },
 {
  "type": "function",
  "name": "getPosition",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256"
   },
   {
    "name": "accountId",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "positionInfo",
    "type": "tuple",
    "components": [
     {
      "name": "accountId",
      "type": "uint256"
     },
     {
      "name": "nextNodeId",
      "type": "uint256"
     },
     {
      "name": "prevNodeId",
      "type": "uint256"
     },
     {
      "name": "positionType",
      "type": "uint8"
     },
     {
      "name": "depositCNS",
      "type": "uint256"
     },
     {
      "name": "pricePNS",
      "type": "uint256"
     },
     {
      "name": "lotLNS",
      "type": "uint256"
     },
     {
      "name": "entryBlock",
      "type": "uint256"
     },
     {
      "name": "pnlCNS",
      "type": "int256"
     },
     {
      "name": "deltaPnlCNS",
      "type": "int256"
     },
     {
      "name": "premiumPnlCNS",
      "type": "int256"
     }
    ]
   },
   {
    "name": "markPricePNS",
    "type": "uint256"
   },
   {
    "name": "markPriceValid",
    "type": "bool"
   }
  ]
 },
 {
  "type": "function",
  "name": "getPositionV2",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256"
   },
   {
    "name": "accountId",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "positionInfo",
    "type": "tuple",
    "components": [
     {
      "name": "accountId",
      "type": "uint256"
     },
     {
      "name": "nextNodeId",
      "type": "uint256"
     },
     {
      "name": "prevNodeId",
      "type": "uint256"
     },
     {
      "name": "positionType",
      "type": "uint8"
     },
     {
      "name": "depositCNS",
      "type": "uint256"
     },
     {
      "name": "pricePNS",
      "type": "uint256"
     },
     {
      "name": "lotLNS",
      "type": "uint256"
     },
     {
      "name": "entryBlock",
      "type": "uint256"
     },
     {
      "name": "pnlCNS",
      "type": "int256"
     },
     {
      "name": "deltaPnlCNS",
      "type": "int256"
     },
     {
      "name": "premiumPnlCNS",
      "type": "int256"
     },
     {
      "name": "priceResiduePNSQ16",
      "type": "uint256"
     }
    ]
   },
   {
    "name": "markPricePNS",
    "type": "uint256"
   },
   {
    "name": "markPriceValid",
    "type": "bool"
   }
  ]
 },
 {
  "type": "function",
  "name": "getWithdrawAllowanceData",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "blockNumber",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "allowanceCNS",
    "type": "uint256"
   },
   {
    "name": "expiryBlock",
    "type": "uint256"
   },
   {
    "name": "lastAllowanceBlock",
    "type": "uint256"
   },
   {
    "name": "cnsPerBlock",
    "type": "uint256"
   }
  ]
 },
 {
  "type": "function",
  "name": "isHalted",
  "stateMutability": "view",
  "inputs": [],
  "outputs": [
   {
    "name": "halted",
    "type": "bool"
   }
  ]
 },
 {
  "type": "function",
  "name": "perpetualExists",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256"
   }
  ],
  "outputs": [
   {
    "name": "perpExists",
    "type": "bool"
   }
  ]
 },
 {
  "type": "function",
  "name": "whitelisted",
  "stateMutability": "view",
  "inputs": [
   {
    "name": "",
    "type": "address"
   }
  ],
  "outputs": [
   {
    "name": "",
    "type": "bool"
   }
  ]
 },
 {
  "type": "function",
  "name": "whitelistingEnabled",
  "stateMutability": "view",
  "inputs": [],
  "outputs": [
   {
    "name": "",
    "type": "bool"
   }
  ]
 },
 {
  "type": "function",
  "name": "withdrawCollateral",
  "stateMutability": "nonpayable",
  "inputs": [
   {
    "name": "amountCNS",
    "type": "uint256"
   }
  ],
  "outputs": []
 },
 {
  "type": "event",
  "name": "AccountCreated",
  "inputs": [
   {
    "name": "account",
    "type": "address",
    "indexed": false
   },
   {
    "name": "id",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "CollateralDeposit",
  "inputs": [
   {
    "name": "accountId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "amountCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "balanceCNS",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "CollateralWithdrawal",
  "inputs": [
   {
    "name": "accountId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "amountCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "balanceCNS",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "MakerOrderFilled",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "accountId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "orderId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "pricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "lotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "feeCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "lockedBalanceCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "amountCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "balanceCNS",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "OrderCancelled",
  "inputs": [
   {
    "name": "lockedBalanceCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "amountCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "balanceCNS",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "OrderPlaced",
  "inputs": [
   {
    "name": "orderId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "lotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "lockedBalanceCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "amountCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "balanceCNS",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "OrderPostFailed",
  "inputs": [
   {
    "name": "reason",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "OrderRequest",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "accountId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "orderDescId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "orderId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "orderType",
    "type": "uint8",
    "indexed": false
   },
   {
    "name": "pricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "lotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "expiryBlock",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "postOnly",
    "type": "bool",
    "indexed": false
   },
   {
    "name": "fillOrKill",
    "type": "bool",
    "indexed": false
   },
   {
    "name": "immediateOrCancel",
    "type": "bool",
    "indexed": false
   },
   {
    "name": "maxMatches",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "leverageHdths",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "lastExecutionBlock",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "amountCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "maxNegPnlCollatBPS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "gasLeft",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "PositionClosed",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "accountId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "positionType",
    "type": "uint8",
    "indexed": false
   },
   {
    "name": "pricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "deltaPnlCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "fundingCNS",
    "type": "int256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "PositionDecreased",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "accountId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "positionType",
    "type": "uint8",
    "indexed": false
   },
   {
    "name": "startDepositCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "endDepositCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "startLotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "endLotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "deltaPnlCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "fundingCNS",
    "type": "int256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "PositionIncreased",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "accountId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "positionType",
    "type": "uint8",
    "indexed": false
   },
   {
    "name": "leverageHdths",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "startDepositCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "endDepositCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "pnlCollateralizedCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "premiumPnlSettledCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "maxNegPnlCollatBPS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "pricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "startLotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "endLotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "insFeeCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "protFeeCNS",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "PositionLiquidated",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "posAccountId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "positionType",
    "type": "uint8",
    "indexed": false
   },
   {
    "name": "markPricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "liqPricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "liqLotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "posLotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "deltaPnlCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "fundingCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "posAmountCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "posDepositCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "accAmountCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "accBalanceCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "onOrderBook",
    "type": "bool",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "PositionOpened",
  "inputs": [
   {
    "name": "perpId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "accountId",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "positionType",
    "type": "uint8",
    "indexed": false
   },
   {
    "name": "leverageHdths",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "depositCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "pnlCollateralizedCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "pricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "lotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "insFeeCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "protFeeCNS",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 },
 {
  "type": "event",
  "name": "TakerOrderFilled",
  "inputs": [
   {
    "name": "entryPricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "collatPricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "pnlPricePNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "lotLNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "feeCNS",
    "type": "uint256",
    "indexed": false
   },
   {
    "name": "amountCNS",
    "type": "int256",
    "indexed": false
   },
   {
    "name": "balanceCNS",
    "type": "uint256",
    "indexed": false
   }
  ],
  "anonymous": false
 }
] as const;
