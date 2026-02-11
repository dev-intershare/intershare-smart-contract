// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";

contract DeployMockUSDT is Script {
    function run() external {
        vm.startBroadcast();
        MockUSDT usdt = new MockUSDT();
        console.log("MockUSDT deployed at:", address(usdt));
        vm.stopBroadcast();
    }
}
