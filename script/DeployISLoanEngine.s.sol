// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ISLoanEngine} from "../src/ISLoanEngine.sol";

struct NetworkConfig {
    uint256 deployerKey;
    address owner;
}

contract DeployISLoanEngine is Script {
    error DeployISLoanEngine__UnsupportedNetwork();
    error DeployISLoanEngine__OwnerCannotBeZero();

    function run() external {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilEthConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            revert DeployISLoanEngine__UnsupportedNetwork();
        }

        if (activeNetworkConfig.owner == address(0)) {
            revert DeployISLoanEngine__OwnerCannotBeZero();
        }

        console.log("------- Deployed ISLoanEngine -------");
        console.log("Deploying to chain ID:", block.chainid);
        vm.startBroadcast(activeNetworkConfig.deployerKey);
        ISLoanEngine engine = new ISLoanEngine(activeNetworkConfig.owner);
        console.log("ISLoanEngine deployed to:", address(engine));
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
