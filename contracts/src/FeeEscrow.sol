// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TransferHelper} from "./libraries/TransferHelper.sol";

/// @notice Pull-payment escrow for protocol and creator fees. Anything credited is claimable by its recipient
///         and nobody else; credits are only ever backed by value that actually arrived.
contract FeeEscrow {
    mapping(address => uint256) public balanceOf; // native
    mapping(address => mapping(address => uint256)) public balanceOfToken; // recipient => token => amount

    event Credited(address indexed recipient, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);
    event CreditedToken(address indexed recipient, address indexed token, uint256 amount);
    event ClaimedToken(address indexed recipient, address indexed token, uint256 amount);

    error NothingToClaim();

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
        emit Credited(recipient, msg.value);
    }

    /// @dev Pulls `amount` of `token` from the caller, so a credit can never exceed what was received.
    function creditToken(address recipient, address token, uint256 amount) external {
        TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
        balanceOfToken[recipient][token] += amount;
        emit CreditedToken(recipient, token, amount);
    }

    function claim() external {
        uint256 amount = balanceOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        balanceOf[msg.sender] = 0;
        TransferHelper.sendNative(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function claimToken(address token) external {
        uint256 amount = balanceOfToken[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        balanceOfToken[msg.sender][token] = 0;
        TransferHelper.safeTransfer(token, msg.sender, amount);
        emit ClaimedToken(msg.sender, token, amount);
    }
}
