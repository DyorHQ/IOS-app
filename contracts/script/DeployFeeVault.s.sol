// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MondayFeeVault} from "../src/MondayFeeVault.sol";
import {MondayGraduationExecutor} from "../src/MondayGraduationExecutor.sol";
import {IMondayV3Factory} from "../src/interfaces/IMondayV3.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";

/// @notice Ops upgrade to enable post-graduation LP fee collection and separate the money roles, WITHOUT a full
///         redeploy. It deploys a collectable `MondayFeeVault` plus a fresh `MondayGraduationExecutor` that mints
///         graduated liquidity to the vault, then points the launchpad factory's (swappable) `graduationExecutor`
///         at the new one. Future graduations then route their 1% pool swap fees to the FEES address; the LP
///         principal stays locked (the vault only ever calls burn(…,0)+collect). Already-graduated pools are
///         unaffected — their fees remain locked in the old locker and are not recoverable.
///
///         Three distinct roles:
///           - OWNER    = governance (vault owner; the factory owner is unchanged unless you transfer it separately).
///           - TREASURY = launch fees + the protocol's share of bonding-curve trading fees (via setFeePolicy).
///           - FEES     = post-graduation LP swap fees (the vault's lpFeeRecipient).
///
///         Must be broadcast from the factory OWNER key (setModules/setFeePolicy are onlyOwner):
///           FEES=0x.. TREASURY=0x.. OWNER=0x.. \
///           forge script script/DeployFeeVault.s.sol:DeployFeeVault --rpc-url monad --broadcast --private-key $OWNER_KEY
///         Dry run first (no --broadcast) to print the addresses and confirm the module re-pass.
contract DeployFeeVault is Script {
    function run() external {
        address factoryAddr = vm.envOr("FACTORY", address(0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea));
        address mondayFactory = vm.envOr("MONDAY_FACTORY", address(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21));
        address wmon = vm.envOr("WMON", address(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A));

        address feesRecipient = vm.envAddress("FEES"); // required
        address treasury = vm.envAddress("TREASURY"); // required
        address vaultOwner = vm.envOr("OWNER", msg.sender); // defaults to the broadcasting (factory owner) key

        LaunchpadFactory factory = LaunchpadFactory(factoryAddr);

        // Re-pass the frozen modules unchanged; only the graduation executor is swapped (allowed post-launch).
        address hook = factory.hook();
        address locker = factory.locker();
        address escrow = factory.escrow();
        address sharing = factory.holderFeeSharing();
        address router = factory.router();
        address deployer = factory.launchDeployer();
        uint16 protocolShareBps = factory.protocolFeeShareBps();

        require(feesRecipient != vaultOwner && treasury != vaultOwner && feesRecipient != treasury, "roles must be distinct");
        require(factory.owner() == msg.sender, "broadcast from the factory owner key");

        vm.startBroadcast();

        MondayFeeVault vault = new MondayFeeVault(vaultOwner, feesRecipient);
        MondayGraduationExecutor executor =
            new MondayGraduationExecutor(IMondayV3Factory(mondayFactory), factoryAddr, address(vault), wmon);

        // Point the launchpad at the new executor (frozen modules re-passed unchanged).
        factory.setModules(hook, address(executor), locker, escrow, sharing, router, deployer);
        // Split Owner/Treasury: route launch + curve protocol fees to the treasury (config-only, keeps the share bps).
        factory.setFeePolicy(treasury, protocolShareBps);

        vm.stopBroadcast();

        console2.log("MondayFeeVault      ", address(vault));
        console2.log("New executor        ", address(executor));
        console2.log("FEES (lp fees)      ", feesRecipient);
        console2.log("TREASURY (protocol) ", treasury);
        console2.log("OWNER (vault gov)   ", vaultOwner);
    }
}
