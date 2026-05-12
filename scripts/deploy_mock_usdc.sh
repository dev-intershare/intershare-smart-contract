#!/bin/bash
set -e

SCRIPT="script/DeployMockUSDC.s.sol:DeployMockUSDC"
ALLOWED="anvil sepolia"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/_deploy.sh" "$SCRIPT" "$1" "$2" "$ALLOWED"