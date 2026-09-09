// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Shared types for the DyorHQ launchpad (Pons v2 shaped, built for Monad + Uniswap v4).
library Types {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    /// @dev Everything a creator supplies. `expectedEconomics` pins the terms returned by
    ///      `previewLaunchEconomics` so the owner cannot change them between quote and launch.
    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool holderFeeSharing;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    /// @dev Owner-managed launch template. A factory can offer several.
    struct LaunchConfig {
        uint256 supply; // fixed token supply (18 decimals)
        uint16 curveFeeBps; // base trade fee while on the curve
        uint16 poolFeeBps; // base trade fee charged by the hook after graduation
        int24 tickSpacing; // tick spacing of the graduated Uniswap v4 pool
        uint16[] snipeTaxSchedule; // bps charged on buys during second 0, 1, 2, ... after launch
        bool enabled;
    }

    /// @dev Per quote asset economics. address(0) is the native token (MON).
    struct PairEconomics {
        uint256 phantomQuote; // virtual quote reserve that sets the opening price
        uint256 graduationThreshold; // real quote that must be raised to graduate
        uint8 decimals;
        bool approved;
    }

    struct FeePolicy {
        address protocolFeeRecipient;
        uint16 protocolFeeShareBps; // share of the base fee (and snipe tax) that goes to the protocol
    }

    enum Phase {
        NotGraduated,
        Swept,
        PoolCreated,
        Rescued
    }

    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint16 creatorTaxBps;
        uint16 poolFeeBps;
        int24 tickSpacing;
        bool holderFeeSharing;
        Phase phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bytes32 poolId;
        bool exists;
    }

    struct TokenInit {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address deployer;
        address holderFeeSharing;
        uint256 supply;
        address initialHolder;
    }

    struct CurveInit {
        address token;
        address pairToken;
        uint256 supply;
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint16 feeBps;
        uint16 creatorTaxBps;
        address creatorFeeRecipient;
        bool holderFeeSharing;
        address deployer;
        uint16[] snipeTaxSchedule;
        address[] snipeTaxExemptions;
    }

    /// @dev What the hook needs to know about a graduated pool.
    struct PoolLaunch {
        address token;
        address quoteToken; // address(0) for native
        bool tokenIsCurrency0;
        address creatorFeeRecipient;
        uint16 feeBps;
        uint16 creatorTaxBps;
        bool holderFeeSharing;
        bool registered;
    }
}

interface IFeeEscrow {
    function credit(address recipient) external payable;
    function creditToken(address recipient, address token, uint256 amount) external;
}

interface IHolderFeeSharing {
    function register(address token, address quoteToken, address[] calldata excluded) external;
    function exclude(address token, address account) external;
    function setAuthorized(address account, bool allowed) external;
    function beforeTransfer(address from, address to, uint256 amount) external;
    function notifyReward(address token, uint256 amount) external payable;
}

interface IBondingCurve {
    function completed() external view returns (bool);
    function rescued() external view returns (bool);
    function swept() external view returns (bool);
    function phantomQuote() external view returns (uint256);
    function sweep(address to) external returns (uint256 quoteAmount, uint256 tokenAmount);
    function enableRescue() external;
    function setCreatorFeeRecipient(address recipient) external;
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
}

interface IMemeHook {
    function registerLaunch(PoolKey calldata key, Types.PoolLaunch calldata launch) external;
    function setCreatorFeeRecipient(bytes32 poolId, address recipient) external;
}

interface IGraduationExecutor {
    /// @notice Builds the Uniswap v4 pool from the swept reserves (already transferred to the executor)
    ///         and locks the full-range position in the locker forever.
    function graduate(
        address token,
        address pairToken,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint256 phantomQuote,
        int24 tickSpacing
    ) external returns (bytes32 poolId, uint128 liquidity);
}

interface ILaunchLocker {
    function lock(PoolKey calldata key, uint128 liquidity) external;
}

interface ILaunchDeployer {
    function predictToken(bytes32 salt, Types.TokenInit calldata init) external view returns (address);
    function deployToken(bytes32 salt, Types.TokenInit calldata init) external returns (address);
    function deployCurve(bytes32 salt, Types.CurveInit calldata init) external returns (address);
}

interface ILaunchpadFactory {
    function graduationExecutor() external view returns (address);
    function locker() external view returns (address);
    function hook() external view returns (address);
    function escrow() external view returns (address);
    function holderFeeSharing() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function protocolFeeShareBps() external view returns (uint16);
    function onCurveComplete(address token) external;
    function launchTokenFor(
        Types.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions,
        address deployer
    ) external payable returns (address token, address curve);
    function launchFee() external view returns (uint256);
}
