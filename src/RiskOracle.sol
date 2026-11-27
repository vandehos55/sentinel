// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title RiskOracle — on-chain record of the Sentinel AI agent's risk assessment.
/// @notice The off-chain AI agent (and only it) publishes a risk score 0-100 plus a
/// short human-readable reason. The Sentinel reactive contract on Reactive
/// Lasna subscribes to RiskScoreUpdated and acts when the score crosses the
/// high-risk threshold. Timestamps (not block numbers) are used throughout:
/// Base Sepolia produces a block every ~200ms, so block counts are not a
/// reliable clock.
contract RiskOracle {
    /// @notice Emitted on every score update. `score` is deliberately NOT indexed:
    /// it arrives in the reactive contract's LogRecord.data, which keeps the
    /// decoding in react() a single abi.decode of (uint256, uint256, string).
    event RiskScoreUpdated(uint256 score, uint256 updatedAt, string reason);

    error NotAgent(address caller, address agent);
    error ScoreOutOfRange(uint256 score);
    error ZeroAddress();

    address public agent;
    address public owner;
    uint256 public latestScore;
    uint256 public latestUpdatedAt;
    string public latestReason;

    modifier onlyAgent() {
        if (msg.sender != agent) revert NotAgent(msg.sender, agent);
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "RiskOracle: not owner");
        _;
    }

    constructorr(address agent_) {
        if (agent_ == address(0)) revert ZeroAddress();
        agent = agent_;
        owner = msg.sender;
    }

    /// @notice Publish a new AI risk assessment.
    function updateScore(uint256 score_, string calldata reason_) external onlyAgent {
        if (score_ > 100) revert ScoreOutOfRange(score_);
        latestScore = score_;
        latestUpdatedAt = block.timestamp;
        latestReason = reason_;
        emit RiskScoreUpdated(score_, block.timestamp, reason_);
    }

    /// @notice Rotate the agent key (e.g. if the agent wallet is ever replaced).
    function setAgent(address agent_) external onlyOwner {
        if (agent_ == address(0)) revert ZeroAddress();
        agent = agent_;
    }

    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert ZeroAddress();
        owner = newOwner_;
    }
}
