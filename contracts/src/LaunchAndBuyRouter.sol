// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types, IBondingCurve, ILaunchpadFactory} from "./interfaces/ILaunchpad.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

/// @notice Optional router: creates a launch and makes the creator's first buy in one transaction, so nobody
///         can get in before the developer buy. The deployer is snipe-tax exempt by construction.
contract LaunchAndBuyRouter {
    ILaunchpadFactory public immutable factory;

    error NativeValueMismatch();

    constructor(ILaunchpadFactory _factory) {
        factory = _factory;
    }

    receive() external payable {}

    function launchAndBuy(
        Types.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve, uint256 tokensOut) {
        uint256 fee = factory.launchFee();
        if (msg.value != (pairToken == address(0) ? fee + quoteIn : fee)) revert NativeValueMismatch();
        (token, curve) = factory.launchTokenFor{value: fee}(params, launchConfigId, pairToken, snipeTaxExemptions, msg.sender);
        if (quoteIn == 0) return (token, curve, 0);

        if (pairToken == address(0)) {
            tokensOut = IBondingCurve(curve).buy{value: quoteIn}(quoteIn, minTokensOut, recipient);
            uint256 leftover = address(this).balance;
            if (leftover > 0) TransferHelper.sendNative(msg.sender, leftover);
        } else {
            TransferHelper.safeTransferFrom(pairToken, msg.sender, address(this), quoteIn);
            TransferHelper.safeApprove(pairToken, curve, quoteIn);
            tokensOut = IBondingCurve(curve).buy(quoteIn, minTokensOut, recipient);
            uint256 leftover = IERC20(pairToken).balanceOf(address(this));
            if (leftover > 0) TransferHelper.safeTransfer(pairToken, msg.sender, leftover);
        }
    }
}
