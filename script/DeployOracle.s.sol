// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { RiskOracle } from "../src/RiskOracle.sol";

/// @notice Step 1 — deploy the RiskOracle on Base Sepolia.
///         Usage: forge script script/DeployOracle.s.sol --rpc-url https://sepolia.base.org --broadcast
///         The deployer becomes the agent (it will publish AI risk scores).
contract DeployOracle is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        RiskOracle oracle = new RiskOracle(vm.addr(deployerKey));
        vm.stopBroadcast();
        console.log("RiskOracle deployed at:", address(oracle));
        console.log("agent:", vm.addr(deployerKey));
    }
}
