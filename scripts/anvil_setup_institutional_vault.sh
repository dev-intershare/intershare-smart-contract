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

VAULT_ADDRESS="${ANVIL_IS21_INSTITUTIONAL_REWARD_VAULT_ADDRESS:-${IS21_INSTITUTIONAL_REWARD_VAULT:-0x5FC8d32690cc91D4c39d9d3abcBD16989F875707}}"
IS21_ADDRESS="${ANVIL_IS21_ADDRESS:-0x5fbdb2315678afecb367f032d93f642f64180aa3}"

PRIVATE_KEY="${ANVIL_PRIVATE_KEY:-}"
OWNER_ADDRESS="${ANVIL_OWNER_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"

# Same address for local Anvil testing
INSTITUTION_ADDRESS="${INSTITUTION_ADDRESS:-$OWNER_ADDRESS}"
VAULT_FUND_MANAGER_ADDRESS="${VAULT_FUND_MANAGER_ADDRESS:-$OWNER_ADDRESS}"
VAULT_REWARD_MANAGER_ADDRESS="${VAULT_REWARD_MANAGER_ADDRESS:-$OWNER_ADDRESS}"

# Vault default minimum is 150,000 IS21
DEPOSIT_AMOUNT_IS21="${DEPOSIT_AMOUNT_IS21:-150000}"
DEPOSIT_AMOUNT_WEI="$(cast to-wei "$DEPOSIT_AMOUNT_IS21" ether)"

# =========================
# Helpers
# =========================

read_uint() {
  cast call "$@" | awk '{print $1}'
}

read_bool() {
  cast call "$@" | awk '{print $1}'
}

format_wei() {
  cast from-wei "$1" ether
}

bigint_lt() {
  python3 - "$1" "$2" <<'PY'
import sys
a = int(sys.argv[1])
b = int(sys.argv[2])
sys.exit(0 if a < b else 1)
PY
}

if [ -z "$PRIVATE_KEY" ]; then
  echo "❌ ANVIL_PRIVATE_KEY not set in .env"
  exit 1
fi

echo "----------------------------------------"
echo "🏦 Institutional Vault Position Setup"
echo "----------------------------------------"
echo "RPC URL:              $RPC_URL"
echo "IS21 token:           $IS21_ADDRESS"
echo "Vault:                $VAULT_ADDRESS"
echo "Owner:                $OWNER_ADDRESS"
echo "Fund manager:         $VAULT_FUND_MANAGER_ADDRESS"
echo "Reward manager:       $VAULT_REWARD_MANAGER_ADDRESS"
echo "Institution address:  $INSTITUTION_ADDRESS"
echo "Deposit amount:       $DEPOSIT_AMOUNT_IS21 IS21"
echo "----------------------------------------"

# =========================
# Safety checks
# =========================

if [ "$(cast chain-id --rpc-url "$RPC_URL")" != "31337" ]; then
  echo "❌ This script is intended for Anvil only. Chain ID is not 31337."
  exit 1
fi

if ! cast code "$VAULT_ADDRESS" --rpc-url "$RPC_URL" | grep -vq "^0x$"; then
  echo "❌ No contract found at vault address: $VAULT_ADDRESS"
  exit 1
fi

if ! cast code "$IS21_ADDRESS" --rpc-url "$RPC_URL" | grep -vq "^0x$"; then
  echo "❌ No contract found at IS21 address: $IS21_ADDRESS"
  exit 1
fi

# =========================
# 1. Confirm minimum position
# =========================

MIN_POSITION_WEI=$(read_uint "$VAULT_ADDRESS" \
  "getMinimumPositionAssets()(uint256)" \
  --rpc-url "$RPC_URL")

MIN_POSITION_IS21="$(format_wei "$MIN_POSITION_WEI")"

echo "📌 Current vault minimum position: $MIN_POSITION_IS21 IS21"

if bigint_lt "$DEPOSIT_AMOUNT_WEI" "$MIN_POSITION_WEI"; then
  echo "❌ Deposit amount is below the vault minimum position."
  echo "Deposit amount: $DEPOSIT_AMOUNT_IS21 IS21"
  echo "Minimum:        $MIN_POSITION_IS21 IS21"
  exit 1
fi

# =========================
# 2. Check IS21 balance
# =========================

BALANCE_WEI=$(read_uint "$IS21_ADDRESS" \
  "balanceOf(address)(uint256)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

BALANCE_IS21="$(format_wei "$BALANCE_WEI")"

echo "💰 Institution IS21 balance: $BALANCE_IS21 IS21"

if bigint_lt "$BALANCE_WEI" "$DEPOSIT_AMOUNT_WEI"; then
  echo "❌ Institution address does not have enough IS21."
  echo "Balance:        $BALANCE_IS21 IS21"
  echo "Required:       $DEPOSIT_AMOUNT_IS21 IS21"
  exit 1
fi

# =========================
# 3. Approve fund manager on institutional vault
# =========================

echo "👤 Checking institutional vault fund manager approval..."

IS_VAULT_FUND_MANAGER=$(read_bool "$VAULT_ADDRESS" \
  "isFundManager(address)(bool)" \
  "$VAULT_FUND_MANAGER_ADDRESS" \
  --rpc-url "$RPC_URL")

if [ "$IS_VAULT_FUND_MANAGER" = "true" ]; then
  echo "✅ Address is already a fund manager on institutional vault."
else
  echo "👤 Approving fund manager on institutional vault..."

  cast send "$VAULT_ADDRESS" \
    "approveFundManager(address)" \
    "$VAULT_FUND_MANAGER_ADDRESS" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY"

  echo "✅ Fund manager approved on institutional vault."
fi

# =========================
# 4. Approve reward manager on institutional vault
# =========================

echo "🎁 Checking institutional vault reward manager approval..."

IS_VAULT_REWARD_MANAGER=$(read_bool "$VAULT_ADDRESS" \
  "isRewardManager(address)(bool)" \
  "$VAULT_REWARD_MANAGER_ADDRESS" \
  --rpc-url "$RPC_URL")

if [ "$IS_VAULT_REWARD_MANAGER" = "true" ]; then
  echo "✅ Address is already a reward manager on institutional vault."
else
  echo "🎁 Approving reward manager on institutional vault..."

  cast send "$VAULT_ADDRESS" \
    "approveRewardManager(address)" \
    "$VAULT_REWARD_MANAGER_ADDRESS" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY"

  echo "✅ Reward manager approved on institutional vault."
fi

# =========================
# 5. Whitelist institution/deposit address
# =========================

IS_WHITELISTED_BEFORE=$(read_bool "$VAULT_ADDRESS" \
  "isInstitutionWhitelisted(address)(bool)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

if [ "$IS_WHITELISTED_BEFORE" = "true" ]; then
  echo "✅ Institution address already whitelisted."
else
  echo "✅ Whitelisting institution address..."

  cast send "$VAULT_ADDRESS" \
    "whitelistInstitution(address)" \
    "$INSTITUTION_ADDRESS" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY"

  echo "✅ Institution address whitelisted."
fi

# =========================
# 6. Approve vault to spend IS21
# =========================

echo "🔓 Approving vault to spend $DEPOSIT_AMOUNT_IS21 IS21..."

cast send "$IS21_ADDRESS" \
  "approve(address,uint256)" \
  "$VAULT_ADDRESS" \
  "$DEPOSIT_AMOUNT_WEI" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo "✅ IS21 approval complete."

# =========================
# 7. Deposit IS21 into vault
# =========================

echo "🏦 Depositing $DEPOSIT_AMOUNT_IS21 IS21 into institutional vault..."

cast send "$VAULT_ADDRESS" \
  "deposit(uint256,address)" \
  "$DEPOSIT_AMOUNT_WEI" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo "✅ Deposit complete."

# =========================
# Summary reads
# =========================

echo "----------------------------------------"
echo "📊 Vault / Position Summary"
echo "----------------------------------------"

IS_WHITELISTED=$(read_bool "$VAULT_ADDRESS" \
  "isInstitutionWhitelisted(address)(bool)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

IS_FUND_MANAGER=$(read_bool "$VAULT_ADDRESS" \
  "isFundManager(address)(bool)" \
  "$VAULT_FUND_MANAGER_ADDRESS" \
  --rpc-url "$RPC_URL")

IS_REWARD_MANAGER=$(read_bool "$VAULT_ADDRESS" \
  "isRewardManager(address)(bool)" \
  "$VAULT_REWARD_MANAGER_ADDRESS" \
  --rpc-url "$RPC_URL")

SHARE_BALANCE_WEI=$(read_uint "$VAULT_ADDRESS" \
  "balanceOf(address)(uint256)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

CURRENT_ASSETS_WEI=$(read_uint "$VAULT_ADDRESS" \
  "getCurrentPositionAssets(address)(uint256)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

PRINCIPAL_WEI=$(read_uint "$VAULT_ADDRESS" \
  "getPrincipalDeposited(address)(uint256)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

UNREALIZED_PL_WEI=$(read_uint "$VAULT_ADDRESS" \
  "getUnrealizedProfitLoss(address)(int256)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

TOTAL_ASSETS_WEI=$(read_uint "$VAULT_ADDRESS" \
  "totalAssets()(uint256)" \
  --rpc-url "$RPC_URL")

TOTAL_SUPPLY_WEI=$(read_uint "$VAULT_ADDRESS" \
  "totalSupply()(uint256)" \
  --rpc-url "$RPC_URL")

MIN_POSITION_WEI=$(read_uint "$VAULT_ADDRESS" \
  "getMinimumPositionAssets()(uint256)" \
  --rpc-url "$RPC_URL")

REMAINING_REWARDS_WEI=$(read_uint "$VAULT_ADDRESS" \
  "getRemainingScheduledRewards()(uint256)" \
  --rpc-url "$RPC_URL")

VESTED_REWARDS_WEI=$(read_uint "$VAULT_ADDRESS" \
  "getVestedVaultRewards()(uint256)" \
  --rpc-url "$RPC_URL")

WITHDRAWAL_PENALTY_BPS=$(read_uint "$VAULT_ADDRESS" \
  "getWithdrawalPenaltyBps()(uint256)" \
  --rpc-url "$RPC_URL")

WITHDRAWAL_PENALTY_PERIOD=$(read_uint "$VAULT_ADDRESS" \
  "getWithdrawalPenaltyPeriod()(uint256)" \
  --rpc-url "$RPC_URL")

WITHIN_PENALTY_PERIOD=$(read_bool "$VAULT_ADDRESS" \
  "isWithinPenaltyPeriod(address)(bool)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

MAX_WITHDRAW_WEI=$(read_uint "$VAULT_ADDRESS" \
  "maxWithdraw(address)(uint256)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

MAX_REDEEM_WEI=$(read_uint "$VAULT_ADDRESS" \
  "maxRedeem(address)(uint256)" \
  "$INSTITUTION_ADDRESS" \
  --rpc-url "$RPC_URL")

echo "Fund manager approved:     $IS_FUND_MANAGER"
echo "Reward manager approved:   $IS_REWARD_MANAGER"
echo "Whitelisted:               $IS_WHITELISTED"
echo "Share balance:             $(format_wei "$SHARE_BALANCE_WEI") isIS21"
echo "Current assets:            $(format_wei "$CURRENT_ASSETS_WEI") IS21"
echo "Principal:                 $(format_wei "$PRINCIPAL_WEI") IS21"
echo "Unrealized P/L wei:        $UNREALIZED_PL_WEI"
echo "Vault totalAssets:         $(format_wei "$TOTAL_ASSETS_WEI") IS21"
echo "Vault totalSupply:         $(format_wei "$TOTAL_SUPPLY_WEI") isIS21"
echo "Minimum position:          $(format_wei "$MIN_POSITION_WEI") IS21"
echo "Remaining rewards:         $(format_wei "$REMAINING_REWARDS_WEI") IS21"
echo "Vested vault rewards:      $(format_wei "$VESTED_REWARDS_WEI") IS21"
echo "Max withdraw:              $(format_wei "$MAX_WITHDRAW_WEI") IS21"
echo "Max redeem:                $(format_wei "$MAX_REDEEM_WEI") isIS21"
echo "Withdrawal penalty bps:    $WITHDRAWAL_PENALTY_BPS"
echo "Penalty period seconds:    $WITHDRAWAL_PENALTY_PERIOD"
echo "Within penalty period:     $WITHIN_PENALTY_PERIOD"
echo "----------------------------------------"
echo "✅ Institutional vault local position setup complete."