// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { SentinelReactive } from "../src/SentinelReactive.sol";

/// @notice Step 2 — deploy the SentinelReactive contract on Reactive Lasna.
///         Usage: forge script script/DeployReactive.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast
///         Env: ORACLE_ADDRESS (RiskOracle on Base Sepolia), PRIVATE_KEY.
///         The contract is funded at deployment (0.05 REACT) so it can pay for
///         reactive transactions from the start. LESSON (2026-11-27 demo): 0.02
///         was NOT enough — deploy + first react() cost 0.0228813 lREACT in
///         debt, which halted event delivery until topped up + coverDebt().
contract DeployReactive is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint64 internal constant CALLBACK_GAS_LIMIT = 500_000;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        vm.startBroadcast(deployerKey);
        SentinelReactive reactive = new SentinelReactive{ value: 0.05 ether }(
            oracle,
            BASE_SEPOLIA_CHAIN_ID,
            80, // threshold
            BASE_SEPOLIA_CHAIN_ID,
            CALLBACK_GAS_LIMIT
        );
        vm.stopBroadcast();
        console.log("SentinelReactive deployed at:", address(reactive));
        console.log("oracle:", oracle);
        console.log("threshold: 80");
    }
}
