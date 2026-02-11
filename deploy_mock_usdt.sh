#!/bin/bash

set -e

# Load environment variables
if [ ! -f .env ]; then
    echo "❌ Error: .env file not found."
    exit 1
fi

source .env

SCRIPT_PATH="script/DeployMockUSDT.s.sol:DeployMockUSDT"

CMD="forge script $SCRIPT_PATH --broadcast --rpc-url $ANVIL_RPC_URL --chain-id 31337"
echo "🚀 Deploying to Anvil (localhost)"
echo "🔧 Running: $CMD"
eval "$CMD"
echo "✅ Deployment to Anvil (localhost) complete."
