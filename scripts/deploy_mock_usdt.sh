#!/bin/bash
set -e

SCRIPT="script/DeployMockUSDT.s.sol:DeployMockUSDT"
ALLOWED="anvil sepolia"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/_deploy.sh" "$SCRIPT" "$1" "$2" "$ALLOWED"