#!/bin/bash
set -e

# Determine project root one level above /scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

source .env

if [ -z "$ANVIL_RPC_URL" ]; then
    echo "❌ ANVIL_RPC_URL is missing in .env"
    exit 1
fi

if [ -z "$ANVIL_PRIVATE_KEY" ]; then
    echo "❌ ANVIL_PRIVATE_KEY is missing in .env"
    exit 1
fi

if [ -z "$ANVIL_OWNER_ADDRESS" ]; then
    echo "❌ ANVIL_OWNER_ADDRESS is missing in .env"
    exit 1
fi

if [ -z "$ANVIL_USDT_ADDRESS" ]; then
    echo "❌ ANVIL_USDT_ADDRESS is missing in .env"
    exit 1
fi

if [ -z "$ANVIL_USDC_ADDRESS" ]; then
    echo "❌ ANVIL_USDC_ADDRESS is missing in .env"
    exit 1
fi

# USDT and USDC usually use 6 decimals.
USDT_AMOUNT=25000000000 # 25,000 USDT
USDC_AMOUNT=15000000000 # 15,000 USDC

echo "🚀 Minting local test tokens on Anvil"
echo "Wallet: $ANVIL_OWNER_ADDRESS"
echo ""

echo "Minting 25,000 USDT..."
cast send "$ANVIL_USDT_ADDRESS" \
    "mint(address,uint256)" \
    "$ANVIL_OWNER_ADDRESS" \
    "$USDT_AMOUNT" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$ANVIL_PRIVATE_KEY"

echo ""
echo "Minting 15,000 USDC..."
cast send "$ANVIL_USDC_ADDRESS" \
    "mint(address,uint256)" \
    "$ANVIL_OWNER_ADDRESS" \
    "$USDC_AMOUNT" \
    --rpc-url "$ANVIL_RPC_URL" \
    --private-key "$ANVIL_PRIVATE_KEY"

echo ""
echo "✅ Minting complete."
echo "USDT minted: 25,000"
echo "USDC minted: 15,000"