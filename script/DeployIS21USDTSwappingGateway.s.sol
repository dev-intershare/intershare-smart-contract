// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IS21USDTSwappingGateway} from "../src/gateways/IS21USDTSwappingGateway.sol";

struct NetworkConfig {
    uint256 deployerKey;
    address owner;
    address swapSignerAddress;
    address usdtAddress;
    address fundManagerGatewayAddress;
}

contract DeployIS21USDTSwappingGateway is Script {
    error DeployIS21USDTSwappingGateway__UnsupportedNetwork();
    error DeployIS21USDTSwappingGateway__OwnerCannotBeZero();
    error DeployIS21USDTSwappingGateway__USDTCannotBeZero();
    error DeployIS21USDTSwappingGateway__FundManagerCannotBeZero();

    function run() external {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilEthConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            revert DeployIS21USDTSwappingGateway__UnsupportedNetwork();
        }

        if (activeNetworkConfig.owner == address(0)) {
            revert DeployIS21USDTSwappingGateway__OwnerCannotBeZero();
        }

        if (activeNetworkConfig.usdtAddress == address(0)) {
            revert DeployIS21USDTSwappingGateway__USDTCannotBeZero();
        }

        if (activeNetworkConfig.fundManagerGatewayAddress == address(0)) {
            revert DeployIS21USDTSwappingGateway__FundManagerCannotBeZero();
        }

        console.log("------- Deployed IS21USDTSwappingGateway -------");
        console.log("Deploying to chain ID:", block.chainid);
        vm.startBroadcast(activeNetworkConfig.deployerKey);
        IS21USDTSwappingGateway gateway = new IS21USDTSwappingGateway(
            activeNetworkConfig.owner,
            activeNetworkConfig.swapSignerAddress,
            activeNetworkConfig.usdtAddress,
            activeNetworkConfig.fundManagerGatewayAddress
        );
        console.log("IS21USDTSwappingGateway deployed to:", address(gateway));
        vm.stopBroadcast();
    }

    function getAnvilEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("ANVIL_PRIVATE_KEY"),
                owner: vm.envAddress("ANVIL_OWNER_ADDRESS"),
                swapSignerAddress: vm.envAddress("ANVIL_SWAP_SIGNER_ADDRESS"),
                usdtAddress: vm.envAddress("ANVIL_USDT_ADDRESS"),
                fundManagerGatewayAddress: vm.envAddress("ANVIL_IS21_FUND_MANAGER_GATEWAY_ADDRESS")
            });
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY"),
                owner: vm.envAddress("SEPOLIA_OWNER_ADDRESS"),
                swapSignerAddress: vm.envAddress("SEPOLIA_SWAP_SIGNER_ADDRESS"),
                usdtAddress: vm.envAddress("SEPOLIA_USDT_ADDRESS"),
                fundManagerGatewayAddress: vm.envAddress("SEPOLIA_IS21_FUND_MANAGER_GATEWAY_ADDRESS")
            });
    }

    function getMainnetEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("MAINNET_PRIVATE_KEY"),
                owner: vm.envAddress("MAINNET_OWNER_ADDRESS"),
                swapSignerAddress: vm.envAddress("MAINNET_SWAP_SIGNER_ADDRESS"),
                usdtAddress: vm.envAddress("MAINNET_USDT_ADDRESS"),
                fundManagerGatewayAddress: vm.envAddress("MAINNET_IS21_FUND_MANAGER_GATEWAY_ADDRESS")
            });
    }
}
