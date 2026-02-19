// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";

struct NetworkConfig {
    uint256 deployerKey;
}

contract DeployMockUSDT is Script {
    error DeployMockUSDT__UnsupportedNetwork();

    function run() external {
        NetworkConfig memory config;

        if (block.chainid == 31337) {
            config = getAnvilConfig();
        } else if (block.chainid == 11155111) {
            config = getSepoliaConfig();
        } else {
            revert DeployMockUSDT__UnsupportedNetwork();
        }

        console.log("------- Deploying MockUSDT -------");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(config.deployerKey);

        MockUSDT usdt = new MockUSDT();

        console.log("MockUSDT deployed at:", address(usdt));

        vm.stopBroadcast();
    }

    function getAnvilConfig() internal view returns (NetworkConfig memory) {
        return NetworkConfig({deployerKey: vm.envUint("ANVIL_PRIVATE_KEY")});
    }

    function getSepoliaConfig() internal view returns (NetworkConfig memory) {
        return NetworkConfig({deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY")});
    }
}
