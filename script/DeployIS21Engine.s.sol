// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IS21Engine} from "../src/IS21Engine.sol";

struct NetworkConfig {
    uint256 deployerKey;
    address owner;
}

contract DeployIS21Engine is Script {
    error DeployIS21Engine__UnsupportedNetwork();
    error DeployIS21Engine__OwnerCannotBeZero();

    function run() external {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilEthConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            revert DeployIS21Engine__UnsupportedNetwork();
        }

        if (activeNetworkConfig.owner == address(0)) {
            revert DeployIS21Engine__OwnerCannotBeZero();
        }

        console.log("------- Deployed IS21Engine -------");
        console.log("Deploying to chain ID:", block.chainid);
        vm.startBroadcast(activeNetworkConfig.deployerKey);
        IS21Engine engine = new IS21Engine(activeNetworkConfig.owner);
        console.log("IS21Engine deployed to:", address(engine));
        vm.stopBroadcast();
    }

    function getAnvilEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("ANVIL_PRIVATE_KEY"),
                owner: vm.envAddress("ANVIL_OWNER_ADDRESS")
            });
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY"),
                owner: vm.envAddress("SEPOLIA_OWNER_ADDRESS")
            });
    }

    function getMainnetEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("MAINNET_PRIVATE_KEY"),
                owner: vm.envAddress("MAINNET_OWNER_ADDRESS")
            });
    }
}
