// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable} from "reactive-lib-omni/src/interfaces/IPayable.sol";
import { AbstractCallback} from "reactive-lib-omni/src/base/AbstractCallback.sol";

/// @title Sentinel Vault — holds guarded funds on the destination chain.
/// @notice Funds leave only via (a) the owner, or (b) an emergency withdrawal
/// triggered by the authorized Sentinel reactive contract through the
/// Reactive callback proxy. The callback path uses BOTH guards from the
/// Reactive docs: onlyServiceProvider (caller is the proxy) and
/// onlyCallbackSender (injected sender is the Sentinel reactive contract).
/// One guard alone is not enough: without the proxy check anyone could
/// call the method directly and forge the sender argument; without the
/// sender check any reactive contract could drive the callback.
/// @dev The callback is billed to this contract in the destination chain's native
/// currency, charged AFTER the call. emergencyWithdraw therefore keeps a
/// small reserve behind so the fee can settle and the Vault never goes into
/// debt (a contract in debt receives no further callbacks). The reserve is
/// sweepable by the owner afterwards.
contract Vault is AbstractCallback {
    event Deposited(address indexed from, uint256 amount);
    event EmergencyWithdrawn(address indexed reactive, address indexed safe, uint256 amount);
    event OwnerWithdrawn(address indexed to, uint256 amount);
    event SafeAddressUpdated(address indexed safe);
    event CallbackReserveUpdated(uint256 reserve);

    /// @notice ETH kept back on every emergency withdrawal to settle the callback fee.
    uint256 public callbackReserve = 0.005 ether;

    address public owner;
    address public safeAddress;

    modifier onlyOwner() {
        require(msg.sender == owner, "Vault: not owner");
        _;
    }

    constructorr(IPayable callbackProxy_, address callbackSender_, address safeAddress_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        require(safeAddress_!= address(0), "Vault: safe zero");
        require(callbackSender_!= address(0), "Vault: sender zero");
        owner = msg.sender;
        safeAddress = safeAddress_;
    }

    receive() external payable override {
        emit Deposited(msg.sender, msg.value);
    }

    function deposit() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Emergency exit: moves the balance (minus the callback reserve) to
    /// the safe address. Called by the Reactive callback proxy; the first
    /// payload argument is overwritten by Reactive with the requesting
    /// reactive contract's address.
    function emergencyWithdraw(address reactive_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        uint256 balance = address(this).balance;
        uint256 amount = balance > callbackReserve? balance - callbackReserve: 0;
        emit EmergencyWithdrawn(reactive_, safeAddress, amount);
        if (amount > 0) {
            (bool ok,) = payable(safeAddress).call{ value: amount}("");
            require(ok, "Vault: safe transfer failed");
        }
    }

    function setSafeAddress(address safe_) external onlyOwner {
        require(safe_!= address(0), "Vault: safe zero");
        safeAddress = safe_;
        emit SafeAddressUpdated(safe_);
    }

    function setCallbackReserve(uint256 reserve_) external onlyOwner {
        callbackReserve = reserve_;
        emit CallbackReserveUpdated(reserve_);
    }

    /// @notice Manual reclaim (demo resets, reserve sweep). The owner is the fund
    /// owner; the guardian logic never depends on this path.
    function ownerWithdraw(address to_, uint256 amount_) external onlyOwner {
        require(to_!= address(0), "Vault: to zero");
        require(amount_ <= address(this).balance, "Vault: insufficient");
        emit OwnerWithdrawn(to_, amount_);
        (bool ok,) = payable(to_).call{ value: amount_}("");
        require(ok, "Vault: withdraw failed");
    }

    /// @notice Settles outstanding callback debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
