#!/bin/bash

set -e

if [ ! -f .env ]; then
    echo "❌ Error: .env file not found."
    exit 1
fi

source .env

SCRIPT_PATH="script/DeployMockUSDT.s.sol:DeployMockUSDT"

if [ -z "$1" ]; then
    echo "❌ Error: No network name provided."
    echo "Usage: ./deploy_mock_usdt.sh <network> [--simulate]"
    echo "Available networks: anvil, sepolia"
    exit 1
fi

NETWORK=$1
SIMULATE=$2

CMD="forge script $SCRIPT_PATH"

if [ "$SIMULATE" == "--simulate" ] || [ "$SIMULATE" == "--dry-run" ]; then
    echo "🟡 Simulation mode: not broadcasting."
else
    CMD="$CMD --broadcast"
fi

case "$NETWORK" in
anvil)
    echo "🚀 Deploying MockUSDT to Anvil"
    CMD="$CMD --rpc-url $ANVIL_RPC_URL --chain-id 31337"
    ;;
sepolia)
    echo "🚀 Deploying MockUSDT to Sepolia"
    CMD="$CMD --rpc-url $SEPOLIA_RPC_URL --chain-id 11155111 --verify --etherscan-api-key $SEPOLIA_ETHERSCAN_KEY"
    ;;
*)
    echo "❌ Unsupported network"
    exit 1
    ;;
esac

echo "🔧 Running: $CMD"
eval "$CMD"

echo "✅ Deployment complete."