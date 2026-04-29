// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IS21RewardVault} from "../src/vaults/IS21RewardVault.sol";

struct NetworkConfig {
    uint256 deployerKey;
    address owner;
    address is21Address;
    address treasuryWalletAddress;
    address stabilityWalletAddress;
}

contract DeployIS21RewardVault is Script {
    error DeployIS21RewardVault__UnsupportedNetwork();
    error DeployIS21RewardVault__OwnerCannotBeZero();
    error DeployIS21RewardVault__VaultAssetCannotBeZero();
    error DeployIS21RewardVault__TreasuryWalletCannotBeZero();
    error DeployIS21RewardVault__StabilityWalletCannotBeZero();

    function run() external {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilEthConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            revert DeployIS21RewardVault__UnsupportedNetwork();
        }

        if (activeNetworkConfig.owner == address(0)) {
            revert DeployIS21RewardVault__OwnerCannotBeZero();
        }

        if (activeNetworkConfig.is21Address == address(0)) {
            revert DeployIS21RewardVault__VaultAssetCannotBeZero();
        }

        if (activeNetworkConfig.treasuryWalletAddress == address(0)) {
            revert DeployIS21RewardVault__TreasuryWalletCannotBeZero();
        }

        if (activeNetworkConfig.stabilityWalletAddress == address(0)) {
            revert DeployIS21RewardVault__StabilityWalletCannotBeZero();
        }

        console.log("------- Deployed IS21RewardVault -------");
        console.log("Deploying to chain ID:", block.chainid);
        vm.startBroadcast(activeNetworkConfig.deployerKey);
        IS21RewardVault vault = new IS21RewardVault(
            activeNetworkConfig.is21Address,
            activeNetworkConfig.owner,
            activeNetworkConfig.treasuryWalletAddress,
            activeNetworkConfig.stabilityWalletAddress
        );

        console.log("IS21RewardVault deployed to:", address(vault));
        vm.stopBroadcast();
    }

    function getAnvilEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("ANVIL_PRIVATE_KEY"),
                owner: vm.envAddress("ANVIL_OWNER_ADDRESS"),
                is21Address: vm.envAddress("ANVIL_IS21_ADDRESS"),
                treasuryWalletAddress: vm.envAddress(
                    "ANVIL_IS21_RETAIL_VAULT_TREASURY_ADDRESS"
                ),
                stabilityWalletAddress: vm.envAddress(
                    "ANVIL_IS21_RETAIL_VAULT_STABILITY_ADDRESS"
                )
            });
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY"),
                owner: vm.envAddress("SEPOLIA_OWNER_ADDRESS"),
                is21Address: vm.envAddress("SEPOLIA_IS21_ADDRESS"),
                treasuryWalletAddress: vm.envAddress(
                    "SEPOLIA_IS21_RETAIL_VAULT_TREASURY_ADDRESS"
                ),
                stabilityWalletAddress: vm.envAddress(
                    "SEPOLIA_IS21_RETAIL_VAULT_STABILITY_ADDRESS"
                )
            });
    }

    function getMainnetEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("MAINNET_PRIVATE_KEY"),
                owner: vm.envAddress("MAINNET_OWNER_ADDRESS"),
                is21Address: vm.envAddress("MAINNET_IS21_ADDRESS"),
                treasuryWalletAddress: vm.envAddress(
                    "MAINNET_IS21_RETAIL_VAULT_TREASURY_ADDRESS"
                ),
                stabilityWalletAddress: vm.envAddress(
                    "MAINNET_IS21_RETAIL_VAULT_STABILITY_ADDRESS"
                )
            });
    }
}
