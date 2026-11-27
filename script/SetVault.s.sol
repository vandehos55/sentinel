// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { SentinelReactive } from "../src/SentinelReactive.sol";

/// @notice Step 4 — point the SentinelReactive contract at the Vault (Lasna).
///         Usage: forge script script/SetVault.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast
///         Env: REACTIVE_ADDRESS, VAULT_ADDRESS, PRIVATE_KEY.
contract SetVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address reactiveAddr = vm.envAddress("REACTIVE_ADDRESS");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        vm.startBroadcast(deployerKey);
        SentinelReactive(payable(reactiveAddr)).setVault(vaultAddr);
        vm.stopBroadcast();
        console.log("SentinelReactive", reactiveAddr, "now points at Vault", vaultAddr);
    }
}
