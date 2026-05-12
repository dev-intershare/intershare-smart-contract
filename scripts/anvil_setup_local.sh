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
# Config
# =========================

RPC_URL="${ANVIL_RPC_URL:-http://127.0.0.1:8545}"
PRIVATE_KEY="${ANVIL_PRIVATE_KEY:-}"
OWNER_ADDRESS="${ANVIL_OWNER_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"

IS21_ADDRESS="${ANVIL_IS21_ADDRESS:-}"
FUND_MANAGER_GATEWAY_ADDRESS="${ANVIL_IS21_FUND_MANAGER_GATEWAY_ADDRESS:-0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512}"

# Optional. If set, this address will also be authorized on the fund manager gateway.
SWAP_GATEWAY_ADDRESS="${ANVIL_SWAP_GATEWAY_ADDRESS:-0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9}"

# Same owner address for easy local testing.
AUTHORIZED_CALLER_ADDRESS="${AUTHORIZED_CALLER_ADDRESS:-$OWNER_ADDRESS}"
FUND_MANAGER_ADDRESS="${FUND_MANAGER_ADDRESS:-$OWNER_ADDRESS}"

if [ -z "$PRIVATE_KEY" ]; then
  echo "❌ ANVIL_PRIVATE_KEY not set in .env"
  exit 1
fi

if [ -z "$IS21_ADDRESS" ]; then
  echo "❌ ANVIL_IS21_ADDRESS not set in .env"
  exit 1
fi

echo "----------------------------------------"
echo "🔧 IS21 Anvil Permission Setup"
echo "----------------------------------------"
echo "RPC URL:                  $RPC_URL"
echo "IS21 token:               $IS21_ADDRESS"
echo "Fund manager gateway:     $FUND_MANAGER_GATEWAY_ADDRESS"
echo "Owner:                    $OWNER_ADDRESS"
echo "Authorized caller:        $AUTHORIZED_CALLER_ADDRESS"
echo "Fund manager:             $FUND_MANAGER_ADDRESS"
echo "Swap gateway address:     $SWAP_GATEWAY_ADDRESS"
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
# 1. Approve fund manager gateway on IS21
# =========================

echo "🏦 Approving fund manager gateway on IS21 contract..."

cast send "$IS21_ADDRESS" \
  "approveFundManager(address)" \
  "$FUND_MANAGER_GATEWAY_ADDRESS" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo "✅ Fund manager gateway approved on IS21."

# =========================
# 2. Authorize local caller on fund manager gateway
# =========================

echo "🔐 Authorizing local caller on fund manager gateway..."

cast send "$FUND_MANAGER_GATEWAY_ADDRESS" \
  "authorizeCaller(address)" \
  "$AUTHORIZED_CALLER_ADDRESS" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo "✅ Local caller authorized on fund manager gateway."

# =========================
# 3. Approve local fund manager on fund manager gateway
# =========================

echo "👤 Approving local fund manager on fund manager gateway..."

cast send "$FUND_MANAGER_GATEWAY_ADDRESS" \
  "approveFundManager(address)" \
  "$FUND_MANAGER_ADDRESS" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo "✅ Local fund manager approved on fund manager gateway."

# =========================
# 4. Authorize swap gateway contract
# =========================

if [ -n "$SWAP_GATEWAY_ADDRESS" ]; then
  echo "🔁 Authorizing swap gateway contract on fund manager gateway..."

  cast send "$FUND_MANAGER_GATEWAY_ADDRESS" \
    "authorizeCaller(address)" \
    "$SWAP_GATEWAY_ADDRESS" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY"

  echo "✅ Swap gateway contract authorized on fund manager gateway."
else
  echo "ℹ️ ANVIL_SWAP_GATEWAY_ADDRESS not set. Skipping swap gateway authorization."
fi

# =========================
# Summary reads
# =========================

echo "----------------------------------------"
echo "📊 Permission Summary"
echo "----------------------------------------"

IS21_FUND_MANAGERS=$(cast call "$IS21_ADDRESS" \
  "getFundManagers()(address[])" \
  --rpc-url "$RPC_URL")

GATEWAY_AUTHORIZED_CALLERS=$(cast call "$FUND_MANAGER_GATEWAY_ADDRESS" \
  "getAuthorizedCallers()(address[])" \
  --rpc-url "$RPC_URL")

GATEWAY_FUND_MANAGERS=$(cast call "$FUND_MANAGER_GATEWAY_ADDRESS" \
  "getFundManagers()(address[])" \
  --rpc-url "$RPC_URL")

echo "IS21 fund managers:"
echo "$IS21_FUND_MANAGERS"
echo ""
echo "Gateway authorized callers:"
echo "$GATEWAY_AUTHORIZED_CALLERS"
echo ""
echo "Gateway fund managers:"
echo "$GATEWAY_FUND_MANAGERS"
echo "----------------------------------------"
echo "✅ IS21 Anvil permission setup complete."