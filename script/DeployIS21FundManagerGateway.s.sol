// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IS21FundManagerGateway} from "../src/gateways/IS21FundManagerGateway.sol";

struct NetworkConfig {
    uint256 deployerKey;
    address owner;
    address is21Engine;
}

contract DeployIS21FundManagerGateway is Script {
    error DeployIS21FundManagerGateway__UnsupportedNetwork();
    error DeployIS21FundManagerGateway__OwnerCannotBeZero();
    error DeployIS21FundManagerGateway__IS21CannotBeZero();

    function run() external {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilEthConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            revert DeployIS21FundManagerGateway__UnsupportedNetwork();
        }

        if (activeNetworkConfig.owner == address(0)) {
            revert DeployIS21FundManagerGateway__OwnerCannotBeZero();
        }

        if (activeNetworkConfig.is21Engine == address(0)) {
            revert DeployIS21FundManagerGateway__IS21CannotBeZero();
        }

        console.log("------- Deployed IS21FundManagerGateway -------");
        console.log("Deploying to chain ID:", block.chainid);
        vm.startBroadcast(activeNetworkConfig.deployerKey);
        IS21FundManagerGateway gateway = new IS21FundManagerGateway(
            activeNetworkConfig.owner,
            activeNetworkConfig.is21Engine
        );
        console.log("IS21FundManagerGateway deployed to:", address(gateway));
        vm.stopBroadcast();
    }

    function getAnvilEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("ANVIL_PRIVATE_KEY"),
                owner: vm.envAddress("ANVIL_OWNER_ADDRESS"),
                is21Engine: vm.envAddress("ANVIL_IS21_ADDRESS")
            });
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY"),
                owner: vm.envAddress("SEPOLIA_OWNER_ADDRESS"),
                is21Engine: vm.envAddress("SEPOLIA_IS21_ADDRESS")
            });
    }

    function getMainnetEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("MAINNET_PRIVATE_KEY"),
                owner: vm.envAddress("MAINNET_OWNER_ADDRESS"),
                is21Engine: vm.envAddress("MAINNET_IS21_ADDRESS")
            });
    }
}
