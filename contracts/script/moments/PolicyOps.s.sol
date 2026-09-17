// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";

/// @notice Governance operations on the live Moments factory (owner wallet only; every call is timelocked or
///         metadata-only by construction). Reads deployments/moments-<chainId>.json.
///
///           # propose a new policy for FUTURE Moments (48h timelock), e.g. raise the threshold to $1,000:
///           THRESHOLD_USDC=1000000000 forge script script/moments/PolicyOps.s.sol:PolicyOps --rpc-url monad --broadcast --non-interactive --account owner --sig "proposePolicy()"
///           forge script ... --sig "applyPolicy()"        # anyone, once the timelock has elapsed
///           forge script ... --sig "cancelPolicy()"       # owner
///           PAUSED=true forge script ... --sig "setPaused()"
///           BASE=https://dyorhq.fun/moments/ forge script ... --sig "setBase()"
///           forge script ... --sig "show()"         # read-only
contract PolicyOps is Script {
    MomentsFactory factory;

    function _load() internal {
        string memory json = vm.readFile(string.concat("deployments/moments-", vm.toString(block.chainid), ".json"));
        factory = MomentsFactory(vm.parseJsonAddress(json, ".factory"));
    }

    function _current() internal view returns (MomentTypes.Policy memory p) {
        (p.threshold, p.minPrice, p.creatorBps, p.platformBps, p.reserveBps, p.maxCreatorAllocBps, p.expiryCreatorBps, p.royaltyBps, p.platform, p.treasury) = factory.policy();
    }

    /// Proposes the current policy with any env overrides applied.
    function proposePolicy() external {
        _load();
        MomentTypes.Policy memory p = _current();
        p.threshold = vm.envOr("THRESHOLD_USDC", p.threshold);
        p.minPrice = vm.envOr("MIN_PRICE_USDC", p.minPrice);
        p.creatorBps = uint16(vm.envOr("CREATOR_BPS", uint256(p.creatorBps)));
        p.platformBps = uint16(vm.envOr("PLATFORM_BPS", uint256(p.platformBps)));
        p.reserveBps = uint16(vm.envOr("RESERVE_BPS", uint256(p.reserveBps)));
        p.maxCreatorAllocBps = uint16(vm.envOr("MAX_CREATOR_ALLOC_BPS", uint256(p.maxCreatorAllocBps)));
        p.expiryCreatorBps = uint16(vm.envOr("EXPIRY_CREATOR_BPS", uint256(p.expiryCreatorBps)));
        p.royaltyBps = uint16(vm.envOr("ROYALTY_BPS", uint256(p.royaltyBps)));
        p.platform = vm.envOr("PLATFORM", p.platform);
        p.treasury = vm.envOr("TREASURY", p.treasury);
        vm.startBroadcast();
        factory.proposePolicy(p);
        vm.stopBroadcast();
        console2.log("proposed; applicable at", factory.pendingPolicyAt());
        _print(p);
    }

    function applyPolicy() external {
        _load();
        vm.startBroadcast();
        factory.applyPolicy();
        vm.stopBroadcast();
        console2.log("applied");
        _print(_current());
    }

    function cancelPolicy() external {
        _load();
        vm.startBroadcast();
        factory.cancelPolicy();
        vm.stopBroadcast();
        console2.log("cancelled");
    }

    function setPaused() external {
        _load();
        bool paused = vm.envBool("PAUSED");
        vm.startBroadcast();
        factory.setPublishingPaused(paused);
        vm.stopBroadcast();
        console2.log("publishingPaused =", paused);
    }

    function setBase() external {
        _load();
        string memory base = vm.envString("BASE");
        vm.startBroadcast();
        factory.setExternalBaseURI(base);
        vm.stopBroadcast();
        console2.log("externalBaseURI =", base);
    }

    function show() external {
        _load();
        console2.log("governance", factory.governance());
        console2.log("publishingPaused", factory.publishingPaused());
        console2.log("pendingPolicyAt", factory.pendingPolicyAt());
        console2.log("externalBaseURI", factory.externalBaseURI());
        _print(_current());
    }

    function _print(MomentTypes.Policy memory p) internal pure {
        console2.log("threshold (USDC units)", p.threshold);
        console2.log("minPrice  (USDC units)", p.minPrice);
        console2.log("creator/platform/reserve bps", p.creatorBps, p.platformBps, p.reserveBps);
        console2.log("maxCreatorAlloc / expiryCreator / royalty bps", p.maxCreatorAllocBps, p.expiryCreatorBps, p.royaltyBps);
        console2.log("platform", p.platform);
        console2.log("treasury", p.treasury);
    }
}
