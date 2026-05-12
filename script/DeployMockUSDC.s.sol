// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

struct NetworkConfig {
    uint256 deployerKey;
    address owner;
}

contract DeployMockUSDC is Script {
    error DeployMockUSDC__UnsupportedNetwork();
    error DeployMockUSDC__OwnerCannotBeZero();

    function run() external {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            revert DeployMockUSDC__UnsupportedNetwork();
        }

        if (activeNetworkConfig.owner == address(0)) {
            revert DeployMockUSDC__OwnerCannotBeZero();
        }

        console.log("------- Deploying MockUSDC -------");
        console.log("Deploying to chain ID:", block.chainid);

        vm.startBroadcast(activeNetworkConfig.deployerKey);

        MockUSDC usdc = new MockUSDC(activeNetworkConfig.owner);

        console.log("MockUSDC deployed at:", address(usdc));
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
