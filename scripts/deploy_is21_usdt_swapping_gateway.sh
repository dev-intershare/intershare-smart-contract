#!/bin/bash
set -e

SCRIPT="script/DeployIS21USDTSwappingGateway.s.sol:DeployIS21USDTSwappingGateway"
ALLOWED="anvil sepolia mainnet"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/_deploy.sh" "$SCRIPT" "$1" "$2" "$ALLOWED"