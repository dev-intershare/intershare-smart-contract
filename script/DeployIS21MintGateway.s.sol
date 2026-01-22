// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IS21MintGateway} from "../src/IS21MintGateway.sol";

struct NetworkConfig {
    uint256 deployerKey;
    address owner;
    uint256 trustedSignerKey;
    address trustedSignerAddress;
    address usdtAddress;
    address is21Address;
}

contract DeployIS21MintGateway is Script {
    error DeployIS21MintGateway__UnsupportedNetwork();
    error DeployIS21MintGateway__OwnerCannotBeZero();
    error DeployIS21MintGateway__USDTCannotBeZero();
    error DeployIS21MintGateway__IS21CannotBeZero();
    error DeployIS21MintGateway__SignerCannotBeZero();

    function run() external {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilEthConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            revert DeployIS21MintGateway__UnsupportedNetwork();
        }

        if (activeNetworkConfig.owner == address(0)) {
            revert DeployIS21MintGateway__OwnerCannotBeZero();
        }

        if (activeNetworkConfig.trustedSignerAddress == address(0)) {
            revert DeployIS21MintGateway__SignerCannotBeZero();
        }

        if (activeNetworkConfig.usdtAddress == address(0)) {
            revert DeployIS21MintGateway__USDTCannotBeZero();
        }

        if (activeNetworkConfig.is21Address == address(0)) {
            revert DeployIS21MintGateway__IS21CannotBeZero();
        }

        console.log("------- Deployed IS21MintGateway -------");
        console.log("Deploying to chain ID:", block.chainid);
        console.log(
            "Trusted signer:",
            activeNetworkConfig.trustedSignerAddress
        );
        vm.startBroadcast(activeNetworkConfig.deployerKey);
        IS21MintGateway gateway = new IS21MintGateway(
            activeNetworkConfig.owner,
            activeNetworkConfig.trustedSignerAddress,
            activeNetworkConfig.usdtAddress,
            activeNetworkConfig.is21Address
        );
        console.log("IS21MintGateway deployed to:", address(gateway));
        vm.stopBroadcast();
    }

    function getAnvilEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("ANVIL_PRIVATE_KEY"),
                owner: vm.envAddress("ANVIL_OWNER_ADDRESS"),
                trustedSignerKey: vm.envUint("ANVIL_GATEWAY_SIGNER_KEY"),
                trustedSignerAddress: vm.envAddress(
                    "ANVIL_GATEWAY_SIGNER_ADDRESS"
                ),
                usdtAddress: vm.envAddress("ANVIL_USDT_ADDRESS"),
                is21Address: vm.envAddress("ANVIL_IS21_ADDRESS")
            });
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY"),
                owner: vm.envAddress("SEPOLIA_OWNER_ADDRESS"),
                trustedSignerKey: vm.envUint("SEPOLIA_GATEWAY_SIGNER_KEY"),
                trustedSignerAddress: vm.envAddress(
                    "SEPOLIA_GATEWAY_SIGNER_ADDRESS"
                ),
                usdtAddress: vm.envAddress("SEPOLIA_USDT_ADDRESS"),
                is21Address: vm.envAddress("SEPOLIA_IS21_ADDRESS")
            });
    }

    function getMainnetEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("MAINNET_PRIVATE_KEY"),
                owner: vm.envAddress("MAINNET_OWNER_ADDRESS"),
                trustedSignerKey: vm.envUint("MAINNET_GATEWAY_SIGNER_KEY"),
                trustedSignerAddress: vm.envAddress(
                    "MAINNET_GATEWAY_SIGNER_ADDRESS"
                ),
                usdtAddress: vm.envAddress("MAINNET_USDT_ADDRESS"),
                is21Address: vm.envAddress("MAINNET_IS21_ADDRESS")
            });
    }
}
