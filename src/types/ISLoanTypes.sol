// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OracleLib} from "../libraries/OracleLib.sol";

/**
 * @title ISLoanTypes
 * @notice Shared data types used across the InterShare lending system.
 */
struct TokenConfig {
    bool isSupported;
    uint256 collateralFactor; // scaled by 1e4 (e.g. 7500 = 75%)
    OracleLib.OracleConfig oracle;
    uint8 decimals;
    uint256 supplyIndex;
    uint256 borrowIndex;
    uint40 lastUpdate;
    uint256 supplyInterestRate;
    uint256 borrowInterestRate;
    uint256 liquidationBonus; // scaled by 1e4 (e.g. 10500 = 105%)
}

struct AccountData {
    uint256 totalCollateralUsd;
    uint256 totalDebtUsd;
    uint256 availableBorrowsUsd;
    uint256 healthFactor;
}
