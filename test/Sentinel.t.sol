// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { RiskOracle } from "../src/RiskOracle.sol";
import { Vault } from "../src/Vault.sol";
import { SentinelReactive } from "../src/SentinelReactive.sol";
import { ISystemContract } from "reactive-lib-omni/src/interfaces/ISystemContract.sol";
import { IReactive } from "reactive-lib-omni/src/interfaces/IReactive.sol";
import { AbstractCallback } from "reactive-lib-omni/src/base/AbstractCallback.sol";
import { IPayable } from "reactive-lib-omni/src/interfaces/IPayable.sol";

/// @notice Minimal stand-in for the Lasna system contract (0x8888...), which has
///         no code in the local test environment. Foundry reverts on calls to
///         non-contract addresses, so the mock's runtime code is etched at the
///         system address in setUp. State lives at the etched address, so tests
///         assert callbacks via vm.expectCall, not via this contract's storage.
contract MockSystem {
    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory) external {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract SentinelTest is Test {
    // Lasna system contract / Base Sepolia callback proxy (live addresses).
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant BASE_SEPOLIA_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint64 internal constant CALLBACK_GAS_LIMIT = 500_000;

    address internal owner = address(0xA11CE);
    address internal agent = address(0xA6E77);
    address internal safe = address(0x5AFE);
    address internal stranger = address(0x57A6E);

    RiskOracle internal oracle;
    Vault internal vault;
    SentinelReactive internal reactive;

    event RiskScoreUpdated(uint256 score, uint256 updatedAt, string reason);

    function setUp() public {
        // Etch the mock system contract at the Lasna system address so the
        // reactive contract's subscription does not revert.
        MockSystem mock = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        vm.startPrank(owner);
        oracle = new RiskOracle(agent);
        // Reactive contract first (deployment order per the Reactive docs):
        // it needs the oracle address for its subscription.
        reactive = new SentinelReactive(
            address(oracle),
            BASE_SEPOLIA_CHAIN_ID,
            80, // threshold
            BASE_SEPOLIA_CHAIN_ID,
            CALLBACK_GAS_LIMIT
        );
        // Vault second: it needs the reactive contract's address immutably.
        vault = new Vault(
            IPayable(payable(BASE_SEPOLIA_PROXY)),
            address(reactive),
            safe
        );
        // Break the cycle on the reactive side.
        reactive.setVault(address(vault));
        vm.stopPrank();
    }

    // ---- RiskOracle ----

    function testOracleAgentCanPublish() public {
        vm.expectEmit(true, false, false, true, address(oracle));
        emit RiskScoreUpdated(42, block.timestamp, "calm market");
        vm.prank(agent);
        oracle.updateScore(42, "calm market");
        assertEq(oracle.latestScore(), 42);
        assertEq(oracle.latestUpdatedAt(), block.timestamp);
        assertEq(oracle.latestReason(), "calm market");
    }

    function testOracleRejectsNonAgent() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RiskOracle.NotAgent.selector, stranger, agent));
        oracle.updateScore(10, "nope");
    }

    function testOracleRejectsScoreAbove100() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(RiskOracle.ScoreOutOfRange.selector, 101));
        oracle.updateScore(101, "impossible");
    }

    function testOracleSetAgent() public {
        address newAgent = address(0xBEEF);
        vm.prank(owner);
        oracle.setAgent(newAgent);
        assertEq(oracle.agent(), newAgent);
        vm.prank(newAgent);
        oracle.updateScore(5, "new agent works");
        assertEq(oracle.latestScore(), 5);
    }

    // ---- Vault ----

    function testVaultDepositAndOwnerWithdraw() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vault.deposit{ value: 0.1 ether }();
        assertEq(address(vault).balance, 0.1 ether);
        vm.prank(owner);
        vault.ownerWithdraw(owner, 0.04 ether);
        assertEq(address(vault).balance, 0.06 ether);
    }

    function testVaultEmergencyWithdrawHappyPath() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vault.deposit{ value: 0.05 ether }();
        uint256 safeBefore = safe.balance;
        vm.prank(BASE_SEPOLIA_PROXY);
        vault.emergencyWithdraw(address(reactive));
        // 0.05 - 0.005 reserve = 0.045 to safe; reserve stays to settle the fee.
        assertEq(safe.balance - safeBefore, 0.045 ether);
        assertEq(address(vault).balance, 0.005 ether);
    }

    function testVaultEmergencyWithdrawRejectsNonProxy() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vault.deposit{ value: 0.05 ether }();
        vm.prank(stranger);
        vm.expectRevert();
        vault.emergencyWithdraw(address(reactive));
    }

    function testVaultEmergencyWithdrawRejectsWrongReactive() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vault.deposit{ value: 0.05 ether }();
        vm.prank(BASE_SEPOLIA_PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector, stranger, address(reactive)
            )
        );
        vault.emergencyWithdraw(stranger);
    }

    function testVaultEmergencyWithdrawEmptyBalance() public {
        uint256 safeBefore = safe.balance;
        vm.prank(BASE_SEPOLIA_PROXY);
        vault.emergencyWithdraw(address(reactive));
        assertEq(safe.balance - safeBefore, 0);
        assertEq(address(vault).balance, 0);
    }

    // ---- SentinelReactive ----

    function _scoreLog(uint256 score_, string memory reason_) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(oracle),
            topic0: uint256(keccak256("RiskScoreUpdated(uint256,uint256,string)")),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(score_, block.timestamp, reason_),
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _expectedCallbackCall() internal view returns (bytes memory) {
        bytes memory payload = abi.encodeWithSignature("emergencyWithdraw(address)", address(0));
        return abi.encodeCall(
            ISystemContract.requestCallbackV_1_0,
            (
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: BASE_SEPOLIA_CHAIN_ID,
                    recipient: address(vault),
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            )
        );
    }

    function testReactRejectsNonSystem() public {
        vm.prank(stranger);
        vm.expectRevert();
        reactive.react(_scoreLog(90, "high"));
    }

    function testReactLowScoreUpdatesStateNoCallback() public {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(42, "calm market"));
        assertEq(reactive.lastScore(), 42);
        assertEq(reactive.triggerCount(), 0);
    }

    function testReactCrossingRequestsCallback() public {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(30, "calm"));
        vm.expectCall(SYSTEM_ADDR, _expectedCallbackCall());
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(85, "ETH dumped 12% in an hour"));
        assertEq(reactive.lastScore(), 85);
        assertEq(reactive.triggerCount(), 1);
        assertEq(reactive.lastTriggeredAt(), block.timestamp);
    }

    function testReactRepeatedHighScoreFiresOnce() public {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(85, "high"));
        assertEq(reactive.triggerCount(), 1);
        // Same high score again: state updates, but NO second callback.
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(90, "still high"));
        assertEq(reactive.lastScore(), 90);
        assertEq(reactive.triggerCount(), 1);
    }

    function testReactRefiresAfterScoreRecovers() public {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(85, "high"));
        assertEq(reactive.triggerCount(), 1);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(20, "recovered"));
        assertEq(reactive.triggerCount(), 1);
        vm.expectCall(SYSTEM_ADDR, _expectedCallbackCall());
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(88, "high again"));
        assertEq(reactive.triggerCount(), 2);
    }

    function testReactIgnoresWrongTopic() public {
        IReactive.LogRecord memory log = _scoreLog(95, "high");
        log.topic0 = uint256(keccak256("SomethingElse(uint256)"));
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
        assertEq(reactive.lastScore(), 0);
        assertEq(reactive.triggerCount(), 0);
    }

    function testReactIgnoresWrongChain() public {
        IReactive.LogRecord memory log = _scoreLog(95, "high");
        log.chainId = 1;
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
        assertEq(reactive.lastScore(), 0);
        assertEq(reactive.triggerCount(), 0);
    }

    function testReactPausedDoesNothing() public {
        vm.prank(owner);
        reactive.setPaused(true);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(95, "high"));
        assertEq(reactive.lastScore(), 0);
        assertEq(reactive.triggerCount(), 0);
    }

    function testReactRevertsWhenVaultNotSet() public {
        vm.prank(owner);
        SentinelReactive fresh = new SentinelReactive(
            address(oracle), BASE_SEPOLIA_CHAIN_ID, 80, BASE_SEPOLIA_CHAIN_ID, CALLBACK_GAS_LIMIT
        );
        vm.prank(SYSTEM_ADDR);
        vm.expectRevert(SentinelReactive.VaultNotSet.selector);
        fresh.react(_scoreLog(95, "high"));
    }

    function testSetVaultAccessControl() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SentinelReactive.NotOwner.selector, stranger, owner));
        reactive.setVault(address(0x1234));
    }

    function testSetThreshold() public {
        vm.prank(owner);
        reactive.setThreshold(50);
        assertEq(reactive.threshold(), 50);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(40, "below new threshold"));
        assertEq(reactive.triggerCount(), 0);
        vm.expectCall(SYSTEM_ADDR, _expectedCallbackCall());
        vm.prank(SYSTEM_ADDR);
        reactive.react(_scoreLog(60, "above new threshold"));
        assertEq(reactive.triggerCount(), 1);
    }
}
