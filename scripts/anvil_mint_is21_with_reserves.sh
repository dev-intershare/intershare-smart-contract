#!/bin/bash
set -euo pipefail

# Determine project root, assuming this script is inside /scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

if [ ! -f ".env" ]; then
  echo "❌ .env file not found in project root."
  exit 1
fi

source .env

# =========================
# Helpers
# =========================

read_uint() {
  cast call "$@" | awk '{print $1}'
}

# =========================
# Config
# =========================

RPC_URL="${ANVIL_RPC_URL:-http://127.0.0.1:8545}"
PRIVATE_KEY="${ANVIL_PRIVATE_KEY:-}"
RECIPIENT_ADDRESS="${RECIPIENT_ADDRESS:-${ANVIL_OWNER_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}}"

IS21_ADDRESS="${ANVIL_IS21_ADDRESS:-}"
FUND_MANAGER_GATEWAY_ADDRESS="${ANVIL_IS21_FUND_MANAGER_GATEWAY_ADDRESS:-0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512}"

# Default mint: 200k IS21 backed by +100k USDT and +100k USDC reserve delta
MINT_AMOUNT_IS21="${MINT_AMOUNT_IS21:-200000}"
USDT_RESERVE_DELTA="${USDT_RESERVE_DELTA:-100000}"
USDC_RESERVE_DELTA="${USDC_RESERVE_DELTA:-100000}"

MINT_AMOUNT_WEI="$(cast to-wei "$MINT_AMOUNT_IS21" ether)"
USDT_RESERVE_WEI="$(cast to-wei "$USDT_RESERVE_DELTA" ether)"
USDC_RESERVE_WEI="$(cast to-wei "$USDC_RESERVE_DELTA" ether)"

USDT_BYTES32="$(cast format-bytes32-string "USDT")"
USDC_BYTES32="$(cast format-bytes32-string "USDC")"

if [ -z "$PRIVATE_KEY" ]; then
  echo "❌ ANVIL_PRIVATE_KEY not set in .env"
  exit 1
fi

if [ -z "$IS21_ADDRESS" ]; then
  echo "❌ ANVIL_IS21_ADDRESS not set in .env"
  exit 1
fi

echo "----------------------------------------"
echo "🪙 Mint IS21 On Anvil"
echo "----------------------------------------"
echo "RPC URL:                  $RPC_URL"
echo "IS21 token:               $IS21_ADDRESS"
echo "Fund manager gateway:     $FUND_MANAGER_GATEWAY_ADDRESS"
echo "Recipient:                $RECIPIENT_ADDRESS"
echo "Mint amount:              $MINT_AMOUNT_IS21 IS21"
echo "USDT reserve delta:       $USDT_RESERVE_DELTA USDT"
echo "USDC reserve delta:       $USDC_RESERVE_DELTA USDC"
echo "----------------------------------------"

# =========================
# Safety checks
# =========================

if [ "$(cast chain-id --rpc-url "$RPC_URL")" != "31337" ]; then
  echo "❌ This script is intended for Anvil only. Chain ID is not 31337."
  exit 1
fi

if ! cast code "$IS21_ADDRESS" --rpc-url "$RPC_URL" | grep -vq "^0x$"; then
  echo "❌ No contract found at IS21 address: $IS21_ADDRESS"
  exit 1
fi

if ! cast code "$FUND_MANAGER_GATEWAY_ADDRESS" --rpc-url "$RPC_URL" | grep -vq "^0x$"; then
  echo "❌ No contract found at fund manager gateway address: $FUND_MANAGER_GATEWAY_ADDRESS"
  exit 1
fi

# =========================
# Mint with reserve deltas
# =========================

echo "🪙 Minting $MINT_AMOUNT_IS21 IS21..."

cast send "$FUND_MANAGER_GATEWAY_ADDRESS" \
  "mintWithReservesIncrease(address,(bytes32,uint256)[],uint256)" \
  "$RECIPIENT_ADDRESS" \
  "[($USDT_BYTES32,$USDT_RESERVE_WEI),($USDC_BYTES32,$USDC_RESERVE_WEI)]" \
  "$MINT_AMOUNT_WEI" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo "✅ Mint complete."

# =========================
# Summary reads
# =========================

echo "----------------------------------------"
echo "📊 IS21 / Reserve Summary"
echo "----------------------------------------"

BALANCE_WEI=$(read_uint "$IS21_ADDRESS" \
  "balanceOf(address)(uint256)" \
  "$RECIPIENT_ADDRESS" \
  --rpc-url "$RPC_URL")

TOTAL_SUPPLY_WEI=$(read_uint "$IS21_ADDRESS" \
  "totalSupply()(uint256)" \
  --rpc-url "$RPC_URL")

USDT_RESERVE_TOTAL_WEI=$(read_uint "$IS21_ADDRESS" \
  "getFiatReserve(bytes32)(uint256)" \
  "$USDT_BYTES32" \
  --rpc-url "$RPC_URL")

USDC_RESERVE_TOTAL_WEI=$(read_uint "$IS21_ADDRESS" \
  "getFiatReserve(bytes32)(uint256)" \
  "$USDC_BYTES32" \
  --rpc-url "$RPC_URL")

echo "Recipient balance:    $(cast from-wei "$BALANCE_WEI" ether) IS21"
echo "Total supply:         $(cast from-wei "$TOTAL_SUPPLY_WEI" ether) IS21"
echo "USDT reserve total:   $(cast from-wei "$USDT_RESERVE_TOTAL_WEI" ether) USDT"
echo "USDC reserve total:   $(cast from-wei "$USDC_RESERVE_TOTAL_WEI" ether) USDC"
echo "----------------------------------------"
echo "✅ IS21 mint script complete."