// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {HolderFeeSharing} from "../src/HolderFeeSharing.sol";
import {LaunchLocker} from "../src/LaunchLocker.sol";
import {MemeHook} from "../src/MemeHook.sol";
import {GraduationExecutor} from "../src/GraduationExecutor.sol";
import {MondayGraduationExecutor} from "../src/MondayGraduationExecutor.sol";
import {MondayFeeVault} from "../src/MondayFeeVault.sol";
import {IMondayV3Factory} from "../src/interfaces/IMondayV3.sol";
import {LaunchAndBuyRouter} from "../src/LaunchAndBuyRouter.sol";
import {LaunchDeployer} from "../src/LaunchDeployer.sol";
import {Types, ILaunchpadFactory} from "../src/interfaces/ILaunchpad.sol";
import {HookAddress} from "../src/libraries/HookAddress.sol";

/// @notice Deploys the whole launchpad on Monad mainnet against the canonical Uniswap v4 PoolManager.
///         The broadcasting key becomes the owner of the factory (and therefore of all policy).
///
///         Both graduation venues are wired: the Uniswap v4 executor (default) and the Monday Trade executor.
///         A creator picks the venue per launch; aBIL-quoted launches are forced to Monday.
///
///         Economics are set from USD FDV targets: launch FDV = $2,000, graduation FDV = $20,000 (a 10x multiple,
///         so graduationThreshold = phantomQuote * (sqrt(10) - 1) and ~31.6% of supply is reserved for the pool).
///         Volatile/RWA quote prices (MON, aBIL) are supplied as USD*1e8 env vars; USDC/AUSD are pinned to $1.
///
///         Dry run:   forge script script/Deploy.s.sol:Deploy --rpc-url monad
///         Deploy:    forge script script/Deploy.s.sol:Deploy --rpc-url monad --broadcast --private-key $OWNER_KEY
contract Deploy is Script {
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    /// @dev graduationThreshold = phantomQuote * (sqrt(10) - 1). sqrt(10) - 1 = 2.16227766..., scaled by 1e8.
    ///      This yields graduation FDV = 10x launch FDV (i.e. $2,000 -> $20,000).
    uint256 internal constant GRAD_MULT_E8 = 216_227_766;

    function run() external {
        address poolManager = vm.envOr("POOL_MANAGER", address(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e));
        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", msg.sender);
        // Distinct from owner and treasury: Monday LP swap fees harvest here. If unset, Monday LP mints to LaunchLocker
        // and those fees cannot be collected.
        address feesRecipient = vm.envOr("FEES", address(0));
        uint256 launchFee = vm.envOr("LAUNCH_FEE_WEI", uint256(1 ether));
        uint16 protocolShareBps = uint16(vm.envOr("PROTOCOL_FEE_SHARE_BPS", uint256(5000)));
        uint16 maxCreatorTaxBps = uint16(vm.envOr("MAX_CREATOR_TAX_BPS", uint256(1000)));
        uint256 supply = vm.envOr("SUPPLY", uint256(1_000_000_000e18));
        uint16 curveFeeBps = uint16(vm.envOr("CURVE_FEE_BPS", uint256(100)));
        uint16 poolFeeBps = uint16(vm.envOr("POOL_FEE_BPS", uint256(100)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        // USD FDV targets (whole USD). Launch $2,000 -> graduation $20,000.
        uint256 launchFdvUsd = vm.envOr("LAUNCH_FDV_USD", uint256(2_000));

        // Monday Trade spot AMM (Uniswap-v3-style) + canonical WMON, for the Monday graduation venue.
        address mondayFactory = vm.envOr("MONDAY_FACTORY", address(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21));
        address wmon = vm.envOr("WMON", address(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A));

        // Quote assets. USDC/AUSD are $1 stables (6dp); aBIL is the RWA quote asset (18dp, Monday-only).
        address usdc = vm.envOr("USDC", address(0x754704Bc059F8C67012fEd69BC8A327a5aafb603));
        address ausd = vm.envOr("AUSD", address(0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a));
        address abil = vm.envOr("ABIL", address(0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f));
        // USD price * 1e8 for the non-$1 assets. Override with live prices before a real deploy.
        uint256 monPriceE8 = vm.envOr("MON_USD_E8", uint256(1e8)); // TODO: set to the live MON price * 1e8
        uint256 abilPriceE8 = vm.envOr("ABIL_USD_E8", uint256(1e8)); // TODO: set to the live aBIL price * 1e8

        require(poolManager.code.length > 0, "PoolManager has no code on this chain");

        vm.startBroadcast();
        LaunchpadFactory factory = new LaunchpadFactory(IPoolManager(poolManager), protocolFeeRecipient, launchFee, protocolShareBps, maxCreatorTaxBps);
        FeeEscrow escrow = new FeeEscrow();
        HolderFeeSharing sharing = new HolderFeeSharing(address(factory));
        LaunchLocker locker = new LaunchLocker(IPoolManager(poolManager), address(factory));

        // The hook must live at an address whose low bits encode its permissions. forge routes `new X{salt}` through
        // the deterministic CREATE2 deployer (0x4e59...956C, live on Monad), so we mine the salt against that deployer.
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(MemeHook).creationCode, abi.encode(poolManager, address(factory))));
        (address predictedHook, bytes32 salt) = HookAddress.mine(HookAddress.CREATE2_DEPLOYER, HOOK_FLAGS, initCodeHash, 10_000_000);
        MemeHook hook = new MemeHook{salt: salt}(IPoolManager(poolManager), address(factory));
        require(address(hook) == predictedHook, "hook landed on an unexpected address");

        // Both venues: Uniswap v4 (default) and Monday Trade (creator-selectable; the only venue for aBIL).
        GraduationExecutor v4Executor = new GraduationExecutor(IPoolManager(poolManager), address(factory), address(hook), address(locker));
        // Monday LP is minted to a collectable vault when FEES is set, so swap fees can be harvested without
        // unlocking principal. LaunchLocker stays the v4 position owner (it has no v3 collect path).
        address mondayPositionOwner = address(locker);
        address feeVault = address(0);
        if (feesRecipient != address(0)) {
            require(feesRecipient != msg.sender && feesRecipient != protocolFeeRecipient && protocolFeeRecipient != msg.sender, "roles must be distinct");
            MondayFeeVault vault = new MondayFeeVault(msg.sender, feesRecipient);
            feeVault = address(vault);
            mondayPositionOwner = feeVault;
        }
        MondayGraduationExecutor mondayExecutor = new MondayGraduationExecutor(IMondayV3Factory(mondayFactory), address(factory), mondayPositionOwner, wmon);
        LaunchAndBuyRouter router = new LaunchAndBuyRouter(ILaunchpadFactory(address(factory)));
        LaunchDeployer launchDeployer = new LaunchDeployer(address(factory));

        factory.setModules(address(hook), address(v4Executor), address(locker), address(escrow), address(sharing), address(router), address(launchDeployer));
        factory.setMondayExecutor(address(mondayExecutor));

        uint16[] memory schedule = new uint16[](4);
        schedule[0] = 9800; // second 0: 98% snipe tax
        schedule[1] = 2500; // second 1: 25%
        schedule[2] = 300; // second 2: 3%
        schedule[3] = 30; // second 3: 0.3%, then 0
        factory.addLaunchConfig(
            Types.LaunchConfig({supply: supply, curveFeeBps: curveFeeBps, poolFeeBps: poolFeeBps, tickSpacing: tickSpacing, snipeTaxSchedule: schedule, enabled: true})
        );

        // Quote-asset economics from the USD FDV targets.
        _setPair(factory, address(0), 18, monPriceE8, launchFdvUsd, false); // MON (native)
        _setPair(factory, usdc, 6, 1e8, launchFdvUsd, false); // USDC ($1)
        _setPair(factory, ausd, 6, 1e8, launchFdvUsd, false); // AUSD ($1)
        _setPair(factory, abil, 18, abilPriceE8, launchFdvUsd, true); // aBIL (RWA, Monday-only)
        vm.stopBroadcast();

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "owner", msg.sender);
        vm.serializeAddress(json, "poolManager", poolManager);
        vm.serializeAddress(json, "factory", address(factory));
        vm.serializeAddress(json, "escrow", address(escrow));
        vm.serializeAddress(json, "holderFeeSharing", address(sharing));
        vm.serializeAddress(json, "locker", address(locker));
        vm.serializeAddress(json, "hook", address(hook));
        vm.serializeBytes32(json, "hookSalt", salt);
        vm.serializeAddress(json, "graduationExecutor", address(v4Executor));
        vm.serializeAddress(json, "mondayExecutor", address(mondayExecutor));
        vm.serializeAddress(json, "launchAndBuyRouter", address(router));
        vm.serializeAddress(json, "feeVault", feeVault);
        vm.serializeAddress(json, "treasury", protocolFeeRecipient);
        vm.serializeAddress(json, "feesRecipient", feesRecipient);
        string memory out = vm.serializeAddress(json, "launchDeployer", address(launchDeployer));
        vm.createDir("deployments", true);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("factory", address(factory));
        console2.log("hook", address(hook));
        console2.log("v4Executor", address(v4Executor));
        console2.log("mondayExecutor", address(mondayExecutor));
        console2.log("router", address(router));
        console2.log("wrote", path);
    }

    /// @dev Sets pair economics from a USD launch-FDV target and the asset's USD price (price*1e8; $1 => 1e8).
    ///      phantomQuote = launchFdvUsd / price, in asset units; graduationThreshold = phantomQuote * (sqrt(10)-1).
    function _setPair(LaunchpadFactory factory, address pairToken, uint8 decimals, uint256 priceE8, uint256 launchFdvUsd, bool mondayOnly)
        internal
    {
        uint256 phantom = launchFdvUsd * (10 ** uint256(decimals)) * 1e8 / priceE8;
        uint256 threshold = phantom * GRAD_MULT_E8 / 1e8;
        factory.setPairEconomics(pairToken, phantom, threshold, decimals, true);
        if (mondayOnly) factory.setPairMondayOnly(pairToken, true);
    }
}
