// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract} from "reactive-lib-omni/src/interfaces/ISystemContract.sol";
import { IReactive} from "reactive-lib-omni/src/interfaces/IReactive.sol";
import { AbstractReactive} from "reactive-lib-omni/src/base/AbstractReactive.sol";

/// @title SentinelReactive — the guardian brain on Reactive Lasna.
/// @notice Subscribes to RiskScoreUpdated events from the RiskOracle on the origin
/// chain. When the AI risk score crosses from below the threshold to at or
/// above it (edge-triggered, so a persistently high score fires exactly
/// once per crossing), it requests a callback that runs the Vault's
/// emergency withdrawal on the destination chain.
/// @dev Edge-triggering matters: the reactive contract pays for every reactive
/// transaction in REACT, and the Vault pays for every callback. Re-firing
/// on every repeated high score would burn both balances for nothing.
/// The Vault address is set after deployment via an owner-only setter:
/// the Vault needs this contract's address at construction (immutable
/// _CALLBACK_SENDER), so the cycle breaks on this side, exactly as the
/// Reactive docs prescribe.
contract SentinelReactive is AbstractReactive {
    /// @notice keccak256("RiskScoreUpdated(uint256,uint256,string)")
    bytes32 public constant RISK_SCORE_TOPIC0 = keccak256("RiskScoreUpdated(uint256,uint256,string)");

    event ScoreSeen(uint256 score, uint256 updatedAt, string reason);
    event Triggered(uint256 score, uint256 triggeredAt);
    event VaultUpdated(address indexed vault);
    event ThresholdUpdated(uint256 threshold);
    event PausedUpdated(bool paused);

    error NotOwner(address caller, address owner);
    error VaultNotSet();
    error ZeroAddress();

    uint256 public immutable originChainId;
    address public immutable oracle;
    uint256 public immutable destChainId;
    uint64 public immutable callbackGasLimit;

    address public owner;
    address public vault;
    uint256 public threshold;
    bool public paused;

    uint256 public lastScore;
    uint256 public lastUpdatedAt;
    string public lastReason;
    uint256 public lastTriggeredAt;
    uint256 public triggerCount;

    modifier onlyOwner() {
        if (msg.sender!= owner) revert NotOwner(msg.sender, owner);
        _;
    }

    constructor(
        address oracle_,
        uint256 originChainId_,
        uint256 threshold_,
        uint256 destChainId_,
        uint64 callbackGasLimit_
    ) payable {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = oracle_;
        originChainId = originChainId_;
        threshold = threshold_;
        destChainId = destChainId_;
        callbackGasLimit = callbackGasLimit_;
        owner = msg.sender;

        // Subscribe to RiskScoreUpdated on the origin chain. The score itself is
        // NOT indexed, so it arrives in LogRecord.data.
        SYSTEM.subscribe(
            originChainId_,
            oracle_,
            uint256(RISK_SCORE_TOPIC0),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        // Defensive routing: the subscription already filters, but an explicit
        // check costs nothing and keeps stray logs from ever moving funds.
        if (log_.chainId!= originChainId) return;
        if (log_.contractAddress!= oracle) return;
        if (log_.topic0!= uint256(RISK_SCORE_TOPIC0)) return;
        if (log_.opCode!= 1) return; // RiskScoreUpdated has no indexed params
        if (paused) return;

        (uint256 score, uint256 updatedAt, string memory reason) =
            abi.decode(log_.data, (uint256, uint256, string));

        uint256 previousScore = lastScore;
        lastScore = score;
        lastUpdatedAt = updatedAt;
        lastReason = reason;
        emit ScoreSeen(score, updatedAt, reason);

        // Edge-trigger: fire only on the crossing below -> at/above threshold.
        if (score >= threshold && previousScore < threshold) {
            if (vault == address(0)) revert VaultNotSet();
            lastTriggeredAt = block.timestamp;
            triggerCount += 1;
            emit Triggered(score, block.timestamp);
            _requestEmergencyWithdraw();
        }
    }

    /// @notice Set the Vault that receives the emergency-withdrawal callback.
    /// Owner-only; called once after the Vault is deployed.
    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultUpdated(vault_);
    }

    function setThreshold(uint256 threshold_) external onlyOwner {
        threshold = threshold_;
        emit ThresholdUpdated(threshold_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedUpdated(paused_);
    }

    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert ZeroAddress();
        owner = newOwner_;
    }

    /// @notice Settles outstanding debt to the system contract from this
    /// contract's own balance. Callable by anyone, so a third party can
    /// fund the contract back to life.
    function coverDebt() external {
        _coverDebt();
    }

    function _requestEmergencyWithdraw() internal {
        // The first payload argument is a placeholder: Reactive overwrites its
        // first 160 bits with this contract's address, which the Vault checks
        // with onlyCallbackSender.
        bytes memory payload =
            abi.encodeWithSignature("emergencyWithdraw(address)", address(0));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId,
                recipient: vault,
                gasLimit: callbackGasLimit,
                payload: payload
            })
        );
    }
}
