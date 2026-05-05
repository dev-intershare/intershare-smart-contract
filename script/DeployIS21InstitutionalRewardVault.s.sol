// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IS21InstitutionalRewardVault} from "../src/vaults/IS21InstitutionalRewardVault.sol";

struct NetworkConfig {
    uint256 deployerKey;
    address owner;
    address is21Address;
    address treasuryWalletAddress;
    address stabilityWalletAddress;
}

contract DeployIS21InstitutionalRewardVault is Script {
    error DeployIS21InstitutionalRewardVault__UnsupportedNetwork();
    error DeployIS21InstitutionalRewardVault__OwnerCannotBeZero();
    error DeployIS21InstitutionalRewardVault__VaultAssetCannotBeZero();
    error DeployIS21InstitutionalRewardVault__TreasuryWalletCannotBeZero();
    error DeployIS21InstitutionalRewardVault__StabilityWalletCannotBeZero();

    function run() external {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == 31337) {
            activeNetworkConfig = getAnvilEthConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            revert DeployIS21InstitutionalRewardVault__UnsupportedNetwork();
        }

        if (activeNetworkConfig.owner == address(0)) {
            revert DeployIS21InstitutionalRewardVault__OwnerCannotBeZero();
        }

        if (activeNetworkConfig.is21Address == address(0)) {
            revert DeployIS21InstitutionalRewardVault__VaultAssetCannotBeZero();
        }

        if (activeNetworkConfig.treasuryWalletAddress == address(0)) {
            revert DeployIS21InstitutionalRewardVault__TreasuryWalletCannotBeZero();
        }

        if (activeNetworkConfig.stabilityWalletAddress == address(0)) {
            revert DeployIS21InstitutionalRewardVault__StabilityWalletCannotBeZero();
        }

        console.log("------- Deploying IS21InstitutionalRewardVault -------");
        console.log("Deploying to chain ID:", block.chainid);
        console.log("Owner:", activeNetworkConfig.owner);
        console.log("IS21 asset:", activeNetworkConfig.is21Address);
        console.log(
            "Treasury wallet:",
            activeNetworkConfig.treasuryWalletAddress
        );
        console.log(
            "Stability wallet:",
            activeNetworkConfig.stabilityWalletAddress
        );

        vm.startBroadcast(activeNetworkConfig.deployerKey);

        IS21InstitutionalRewardVault vault = new IS21InstitutionalRewardVault(
            activeNetworkConfig.is21Address,
            activeNetworkConfig.owner,
            activeNetworkConfig.treasuryWalletAddress,
            activeNetworkConfig.stabilityWalletAddress
        );

        console.log(
            "IS21InstitutionalRewardVault deployed to:",
            address(vault)
        );

        vm.stopBroadcast();
    }

    function getAnvilEthConfig() public view returns (NetworkConfig memory) {
        return
            NetworkConfig({
                deployerKey: vm.envUint("ANVIL_PRIVATE_KEY"),
                owner: vm.envAddress("ANVIL_OWNER_ADDRESS"),
                is21Address: vm.envAddress("ANVIL_IS21_ADDRESS"),
                treasuryWalletAddress: vm.envAddress(
                    "ANVIL_IS21_INSTITUTIONAL_VAULT_TREASURY_ADDRESS"
                ),
                stabilityWalletAddress: vm.envAddress(
                    "ANVIL_IS21_INSTITUTIONAL_VAULT_STABILITY_ADDRESS"
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
                    "SEPOLIA_IS21_INSTITUTIONAL_VAULT_TREASURY_ADDRESS"
                ),
                stabilityWalletAddress: vm.envAddress(
                    "SEPOLIA_IS21_INSTITUTIONAL_VAULT_STABILITY_ADDRESS"
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
                    "MAINNET_IS21_INSTITUTIONAL_VAULT_TREASURY_ADDRESS"
                ),
                stabilityWalletAddress: vm.envAddress(
                    "MAINNET_IS21_INSTITUTIONAL_VAULT_STABILITY_ADDRESS"
                )
            });
    }
}
