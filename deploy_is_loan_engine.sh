#!/bin/bash

set -e

# Load environment variables
if [ ! -f .env ]; then
    echo "❌ Error: .env file not found."
    exit 1
fi

source .env

SCRIPT_PATH="script/DeployISLoanEngine.s.sol:DeployISLoanEngine"

# Check for network name
if [ -z "$1" ]; then
    echo "❌ Error: No network name provided."
    echo "Usage: ./deploy_is_loan_engine.sh <network> [--simulate]"
    echo "Available networks: anvil, sepolia, mainnet"
    exit 1
fi

NETWORK=$1
SIMULATE=$2   # optional --simulate flag

CMD="forge script $SCRIPT_PATH"

# Add broadcast unless user explicitly simulates
if [ "$SIMULATE" == "--simulate" ] || [ "$SIMULATE" == "--dry-run" ] || [ "$SIMULATE" == "--dry" ]; then
    echo "🟡 Simulation mode: not broadcasting."
else
    CMD="$CMD --broadcast"
fi

case "$NETWORK" in
anvil)
    echo "🚀 Deploying to Anvil (localhost)"
    CMD="$CMD --rpc-url $ANVIL_RPC_URL --chain-id 31337"
    ;;
sepolia)
    echo "🚀 Deploying to Sepolia"
    CMD="$CMD --rpc-url $SEPOLIA_RPC_URL --chain-id 11155111 --verify --etherscan-api-key $SEPOLIA_ETHERSCAN_KEY"
    ;;
mainnet)
    echo "🚀 Deploying to Ethereum Mainnet"
    CMD="$CMD --rpc-url $MAINNET_RPC_URL --chain-id 1 --verify --etherscan-api-key $MAINNET_ETHERSCAN_KEY"
    ;;
*)
    echo "❌ Error: Unsupported network '$NETWORK'"
    echo "Supported networks: anvil, sepolia, mainnet"
    exit 1
    ;;
esac

echo "🔧 Running: $CMD"
eval "$CMD"
echo "✅ Deployment to $NETWORK complete."
