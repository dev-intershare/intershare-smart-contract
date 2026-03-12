#!/bin/bash

set -e

# Determine project root (one level above /scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

SCRIPT_PATH=$1
NETWORK=$2
SIMULATE=$3
ALLOWED_NETWORKS=$4

if [ -z "$SCRIPT_PATH" ] || [ -z "$NETWORK" ]; then
    echo "❌ Usage: deploy.sh <script-path> <network> [--simulate] [allowed-networks]"
    exit 1
fi

if [ -n "$ALLOWED_NETWORKS" ]; then
    if [[ ! " $ALLOWED_NETWORKS " =~ " $NETWORK " ]]; then
        echo "❌ Network '$NETWORK' is not allowed."
        echo "Allowed networks: $ALLOWED_NETWORKS"
        exit 1
    fi
fi

source .env

CMD="forge script $SCRIPT_PATH"

if [[ "$SIMULATE" != "--simulate" && "$SIMULATE" != "--dry-run" && "$SIMULATE" != "--dry" ]]; then
    CMD="$CMD --broadcast"
else
    echo "🟡 Simulation mode: not broadcasting."
fi

case "$NETWORK" in
anvil)
    CMD="$CMD --rpc-url $ANVIL_RPC_URL --chain-id 31337"
    ;;
sepolia)
    CMD="$CMD --rpc-url $SEPOLIA_RPC_URL --chain-id 11155111 --verify --etherscan-api-key $SEPOLIA_ETHERSCAN_KEY"
    ;;
mainnet)
    CMD="$CMD --rpc-url $MAINNET_RPC_URL --chain-id 1 --verify --etherscan-api-key $MAINNET_ETHERSCAN_KEY"
    ;;
*)
    echo "❌ Unsupported network '$NETWORK'"
    exit 1
    ;;
esac

echo "🔧 Running: $CMD"
eval "$CMD"

echo "✅ Deployment complete."