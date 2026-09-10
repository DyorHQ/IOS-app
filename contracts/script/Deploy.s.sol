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
import {MondayGraduationExecutor} from "../src/MondayGraduationExecutor.sol";
import {IMondayV3Factory} from "../src/interfaces/IMondayV3.sol";
import {LaunchAndBuyRouter} from "../src/LaunchAndBuyRouter.sol";
import {LaunchDeployer} from "../src/LaunchDeployer.sol";
import {Types, ILaunchpadFactory} from "../src/interfaces/ILaunchpad.sol";
import {HookAddress} from "../src/libraries/HookAddress.sol";

/// @notice Deploys the whole launchpad on Monad mainnet against the canonical Uniswap v4 PoolManager.
///         The broadcasting key becomes the owner of the factory (and therefore of all policy).
///
///         Dry run (no transactions):
///           forge script script/Deploy.s.sol:Deploy --rpc-url monad
///         Real deployment, from the wallet that should own the protocol:
///           forge script script/Deploy.s.sol:Deploy --rpc-url monad --broadcast --private-key $OWNER_KEY
///         Every parameter below can be overridden with an environment variable of the same name.
contract Deploy is Script {
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function run() external {
        address poolManager = vm.envOr("POOL_MANAGER", address(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e));
        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", msg.sender);
        uint256 launchFee = vm.envOr("LAUNCH_FEE_WEI", uint256(1 ether));
        uint16 protocolShareBps = uint16(vm.envOr("PROTOCOL_FEE_SHARE_BPS", uint256(5000)));
        uint16 maxCreatorTaxBps = uint16(vm.envOr("MAX_CREATOR_TAX_BPS", uint256(1000)));
        uint256 supply = vm.envOr("SUPPLY", uint256(1_000_000_000e18));
        uint16 curveFeeBps = uint16(vm.envOr("CURVE_FEE_BPS", uint256(100)));
        uint16 poolFeeBps = uint16(vm.envOr("POOL_FEE_BPS", uint256(100)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        uint256 phantomQuote = vm.envOr("PHANTOM_QUOTE_WEI", uint256(4_000 ether));
        uint256 graduationThreshold = vm.envOr("GRADUATION_THRESHOLD_WEI", uint256(16_000 ether));
        // Graduation venue: Monday Trade's spot AMM (Uniswap-v3-style). Native-MON launches graduate into a WMON pool.
        address mondayFactory = vm.envOr("MONDAY_FACTORY", address(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21));
        address wmon = vm.envOr("WMON", address(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A));

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

        MondayGraduationExecutor executor = new MondayGraduationExecutor(IMondayV3Factory(mondayFactory), address(factory), address(locker), wmon);
        LaunchAndBuyRouter router = new LaunchAndBuyRouter(ILaunchpadFactory(address(factory)));
        LaunchDeployer launchDeployer = new LaunchDeployer(address(factory));
        factory.setModules(address(hook), address(executor), address(locker), address(escrow), address(sharing), address(router), address(launchDeployer));

        uint16[] memory schedule = new uint16[](4);
        schedule[0] = 9800; // second 0: 98% snipe tax
        schedule[1] = 2500; // second 1: 25%
        schedule[2] = 300; // second 2: 3%
        schedule[3] = 30; // second 3: 0.3%, then 0
        factory.addLaunchConfig(
            Types.LaunchConfig({supply: supply, curveFeeBps: curveFeeBps, poolFeeBps: poolFeeBps, tickSpacing: tickSpacing, snipeTaxSchedule: schedule, enabled: true})
        );
        factory.setPairEconomics(address(0), phantomQuote, graduationThreshold, 18, true);
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
        vm.serializeAddress(json, "graduationExecutor", address(executor));
        vm.serializeAddress(json, "launchAndBuyRouter", address(router));
        string memory out = vm.serializeAddress(json, "launchDeployer", address(launchDeployer));
        vm.createDir("deployments", true);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("factory", address(factory));
        console2.log("hook", address(hook));
        console2.log("router", address(router));
        console2.log("wrote", path);
    }
}
