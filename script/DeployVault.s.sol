// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { Vault } from "../src/Vault.sol";
import { IPayable } from "reactive-lib-omni/src/interfaces/IPayable.sol";

/// @notice Step 3 — deploy the Vault on Base Sepolia.
///         Usage: forge script script/DeployVault.s.sol --rpc-url https://sepolia.base.org --broadcast
///         Env: REACTIVE_ADDRESS (SentinelReactive on Lasna), SAFE_ADDRESS, PRIVATE_KEY.
///         The callback proxy is the documented Base Sepolia proxy.
contract DeployVault is Script {
    address internal constant BASE_SEPOLIA_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        address safe = vm.envAddress("SAFE_ADDRESS");
        vm.startBroadcast(deployerKey);
        Vault vault = new Vault(IPayable(payable(BASE_SEPOLIA_PROXY)), reactive, safe);
        vm.stopBroadcast();
        console.log("Vault deployed at:", address(vault));
        console.log("callback proxy:", BASE_SEPOLIA_PROXY);
        console.log("callback sender (reactive):", reactive);
        console.log("safe address:", safe);
    }
}
