#!/bin/bash
set -e

SIMULATE=$1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Starting ordered deployment on anvil"

echo "Deploying IS21Engine..."
"$SCRIPT_DIR/deploy_is21_engine.sh" anvil "$SIMULATE"

echo "Deploying IS21FundManagerGateway..."
"$SCRIPT_DIR/deploy_is21_fund_manager_gateway.sh" anvil "$SIMULATE"

echo "Deploying IS21USDTMock..."
"$SCRIPT_DIR/deploy_mock_usdt.sh" anvil "$SIMULATE"

echo "Deploying IS21UsdtSwappingGateway..."
"$SCRIPT_DIR/deploy_is21_usdt_swapping_gateway.sh" anvil "$SIMULATE"

echo "Deploying IS21StakingVault..."
"$SCRIPT_DIR/deploy_is21_staking_vault.sh" anvil "$SIMULATE"

echo "✅ Ordered anvil deployment complete."