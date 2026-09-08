// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ILaunchpadFactory} from "./interfaces/ILaunchpad.sol";

/// @notice Holds every graduated pool position and the supply left over at graduation, forever. There is no
///         unlock, no owner and no withdrawal: the contract can only add liquidity, never remove it.
contract LaunchLocker is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    address public immutable factory;

    struct Locked {
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(address => Locked) public locked; // launch token => position

    event LiquidityLocked(bytes32 indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1);

    error NotExecutor();
    error NotPoolManager();

    constructor(IPoolManager _poolManager, address _factory) {
        poolManager = _poolManager;
        factory = _factory;
    }

    receive() external payable {}

    /// @notice Mints a full-range position funded from this contract's balances. Only the graduation executor
    ///         can call it, and only after it transferred the reserves in.
    function lock(PoolKey calldata key, uint128 liquidity) external {
        if (msg.sender != ILaunchpadFactory(factory).graduationExecutor()) revert NotExecutor();
        poolManager.unlock(abi.encode(key, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint128 liquidity) = abi.decode(data, (PoolKey, uint128));
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        uint256 amount0 = _settle(key.currency0, delta.amount0());
        uint256 amount1 = _settle(key.currency1, delta.amount1());
        address token = key.currency0.isAddressZero() ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        // For custom pairs both currencies are ERC-20s; the launch token is whichever one isn't the quote.
        // The executor records the mapping through `lockedFor`, so here we only need the position itself.
        locked[token] = Locked({poolId: keccak256(abi.encode(key)), tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity});
        emit LiquidityLocked(keccak256(abi.encode(key)), liquidity, amount0, amount1);
        return "";
    }

    /// @dev Pays what the pool is owed for `currency` (negative delta) from this contract's balance.
    function _settle(Currency currency, int128 amount) internal returns (uint256 paid) {
        if (amount >= 0) return 0;
        paid = uint256(uint128(-amount));
        if (currency.isAddressZero()) {
            poolManager.settle{value: paid}();
        } else {
            poolManager.sync(currency);
            currency.transfer(address(poolManager), paid);
            poolManager.settle();
        }
    }

    /// @notice Launch tokens left in the locker beyond the pool position (excess supply) are visible here.
    function excessSupply(address token) external view returns (uint256) {
        return Currency.wrap(token).balanceOfSelf();
    }
}
