// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";

struct NetworkConfig {
    uint256 deployerKey;
    address owner;
}

contract DeployMockUSDT is Script {
    error DeployMockUSDT__UnsupportedNetwork();
    error DeployMockUSDT__OwnerCannotBeZero();

    function run() external {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            revert DeployMockUSDT__UnsupportedNetwork();
        }

        if (activeNetworkConfig.owner == address(0)) {
            revert DeployMockUSDT__OwnerCannotBeZero();
        }

        console.log("------- Deploying MockUSDT -------");
        console.log("Deploying to chain ID:", block.chainid);

        vm.startBroadcast(activeNetworkConfig.deployerKey);

        MockUSDT usdt = new MockUSDT(activeNetworkConfig.owner);

        console.log("MockUSDT deployed at:", address(usdt));
        vm.stopBroadcast();
    }

    function getAnvilConfig() internal view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("ANVIL_PRIVATE_KEY"),
                owner: vm.envAddress("ANVIL_OWNER_ADDRESS")
            });
    }

    function getSepoliaConfig() internal view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY"),
                owner: vm.envAddress("SEPOLIA_OWNER_ADDRESS")
            });
    }
}
