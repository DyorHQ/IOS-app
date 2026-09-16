// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LaunchpadFactory} from "../../src/LaunchpadFactory.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {HolderFeeSharing} from "../../src/HolderFeeSharing.sol";
import {MemeHook} from "../../src/MemeHook.sol";
import {MondayFeeVault} from "../../src/MondayFeeVault.sol";
import {IMondayV3Factory, IMondayV3Pool} from "../../src/interfaces/IMondayV3.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {Types} from "../../src/interfaces/ILaunchpad.sol";

/// Smoke test of the LIVE 2026-09-16 deployment on a Monad mainnet fork: the real factory, curve, hook, executors,
/// Monday pools, fee vault and the real aBIL token — end to end, exactly as users will hit it.
///   forge test --code-size-limit 100000000 --match-path test/audit/Z_LiveDeployment.t.sol --fork-url monad -vv
contract LiveDeploymentTest is Test {
    using PoolIdLibrary for PoolKey;

    LaunchpadFactory constant FACTORY = LaunchpadFactory(0x10F34A174d9C393a90aFf94BDED7E1Db185446D7);
    HolderFeeSharing constant SHARING = HolderFeeSharing(0x70F8f64c6A4A76A507e322BCef19E6E37abe4eF6);
    MemeHook constant HOOK = MemeHook(payable(0x51A240c13164BcDF3FC11053FddEaC626A4160cc));
    MondayFeeVault constant VAULT = MondayFeeVault(0x42a1C1c1d6BC2544d3f478E4d42F5b5ec75888De);
    IPoolManager constant PM = IPoolManager(0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e);
    IMondayV3Factory constant MONDAY = IMondayV3Factory(0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21);
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ABIL = 0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f;
    address constant TREASURY = 0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045;

    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.createSelectFork("monad");
        vm.deal(creator, 100 ether);
        vm.deal(alice, 2_000_000 ether);
        vm.deal(carol, 100_000 ether);
    }

    function _params(address pair, uint16 tax, bool sharing, Types.GraduationVenue venue, uint256 seed) internal view returns (Types.TokenParams memory p) {
        p.name = "Live Smoke";
        p.symbol = "SMOKE";
        p.logo = "ipfs://x";
        p.description = "smoke";
        p.socials = Types.Socials("", "", "", "", "");
        p.creatorFeeRecipient = creator;
        p.creatorTaxBps = tax;
        p.holderFeeSharing = sharing;
        p.graduationVenue = venue;
        p.expectedEconomics = FACTORY.previewLaunchEconomics(0, pair);
        p.salt = bytes32(seed);
    }

    function _completeNative(BondingCurve curve, address who) internal {
        while (!curve.completed()) {
            vm.prank(who);
            curve.buy{value: 50_000 ether}(50_000 ether, 0, who);
        }
    }

    function test_live_monday_native_launch_graduates_into_vault_position() public {
        uint256 fee = FACTORY.launchFee();
        assertEq(fee, 5 ether);
        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(creator);
        (address t, address c) = FACTORY.launchToken{value: fee}(_params(address(0), 100, true, Types.GraduationVenue.Monday, 1), 0, address(0), new address[](0));
        assertEq(TREASURY.balance - treasuryBefore, fee, "launch fee auto-pushed to the treasury");
        BondingCurve curve = BondingCurve(c);
        assertEq(curve.protocolShareBps(), 5000, "pinned 50/50 split");
        assertEq(curve.MAX_TOTAL_BPS(), 9_900);
        vm.warp(block.timestamp + 5);
        _completeNative(curve, alice);

        Types.LaunchedToken memory l = FACTORY.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "auto-graduated on Monday");
        address pool = address(uint160(uint256(l.poolId)));
        assertEq(pool, MONDAY.getPool(t, WMON, 10_000), "TOKEN/WMON pool on Monday");
        assertGt(IMondayV3Pool(pool).liquidity(), 0);
        int24 sp = IMondayV3Pool(pool).tickSpacing();
        bytes32 key = keccak256(abi.encodePacked(address(VAULT), TickMath.minUsableTick(sp), TickMath.maxUsableTick(sp)));
        (uint128 liq,,,,) = IMondayV3Pool(pool).positions(key);
        assertGt(liq, 0, "position is owned by the fee vault");
        assertTrue(SHARING.excluded(t, pool), "Monday pool excluded from holder accounting");
        assertTrue(SHARING.excluded(t, address(VAULT)), "fee vault excluded");

        // Curve-phase holder rewards are claimable one block later by the real holder.
        vm.roll(block.number + 1);
        assertGt(SHARING.pendingRewards(t, alice), 0);
        vm.prank(alice);
        assertGt(SHARING.claim(t), 0);
        // LP fee harvest is permissionless (pays the fixed fees address).
        VAULT.collectFees(pool);
    }

    function test_live_v4_native_launch_swaps_and_shares_fees() public {
        vm.prank(creator);
        (address t, address c) = FACTORY.launchToken{value: 5 ether}(_params(address(0), 500, true, Types.GraduationVenue.UniswapV4, 2), 0, address(0), new address[](0));
        BondingCurve curve = BondingCurve(c);
        vm.warp(block.timestamp + 5);
        _completeNative(curve, alice);

        Types.LaunchedToken memory l = FACTORY.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "auto-graduated on Uniswap v4");
        PoolKey memory key = FACTORY.poolKeyOf(t);
        assertEq(PoolId.unwrap(key.toId()), l.poolId);
        assertTrue(HOOK.launches(l.poolId).registered);
        assertEq(HOOK.launches(l.poolId).protocolShareBps, 5000, "hook carries the pinned split");

        // Buy through the REAL PoolManager with a test router: the hook charges 1% in MON.
        PoolSwapTest router = new PoolSwapTest(PM);
        vm.prank(carol);
        router.swap{value: 1_000 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1_000 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(LaunchToken(t).balanceOf(carol), 0, "carol bought from the graduated pool");
        assertEq(HOOK.pendingFees(key.toId(), Currency.wrap(address(0))), 10 ether, "1% hook fee on 1,000 MON");
        HOOK.sweepPoolFees(l.poolId, Currency.wrap(address(0)));
        vm.roll(block.number + 1);
        assertGt(SHARING.pendingRewards(t, alice), 0, "holders receive pool fees a block later");
    }

    function test_live_abil_monday_launch() public {
        deal(ABIL, alice, 10_000e18);
        vm.prank(creator);
        (address t, address c) = FACTORY.launchToken{value: 5 ether}(_params(ABIL, 0, false, Types.GraduationVenue.Monday, 3), 0, ABIL, new address[](0));
        BondingCurve curve = BondingCurve(c);
        vm.warp(block.timestamp + 5);
        vm.startPrank(alice);
        while (!curve.completed()) {
            IERC20(ABIL).approve(c, 10e18);
            curve.buy(10e18, 0, alice);
        }
        vm.stopPrank();
        Types.LaunchedToken memory l = FACTORY.getLaunchedToken(t);
        assertEq(uint8(l.phase), uint8(Types.Phase.PoolCreated), "aBIL launch graduated on Monday");
        assertEq(address(uint160(uint256(l.poolId))), MONDAY.getPool(t, ABIL, 10_000));
    }

    function test_live_abil_rejects_v4() public {
        // Build the params first: _params() makes an external view call, which would otherwise consume the
        // prank/expectRevert meant for launchToken.
        Types.TokenParams memory p = _params(ABIL, 0, false, Types.GraduationVenue.UniswapV4, 4);
        vm.prank(creator);
        vm.expectRevert(LaunchpadFactory.PairRequiresMonday.selector);
        FACTORY.launchToken{value: 5 ether}(p, 0, ABIL, new address[](0));
    }
}
