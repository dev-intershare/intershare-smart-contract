// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OracleLib} from "./OracleLib.sol";
import {TokenConfig} from "../types/ISLoanTypes.sol";

/**
 * @title ISLoanEngineCore
 * @author BlueAsset Technology Team
 *
 * @notice Core library for internal accounting, interest accrual, and math utilities
 * used by the ISLoanEngine lending protocol.
 *
 * @dev
 * This module centralizes the following functionality:
 * - Interest accrual for individual or all markets
 * - Normalization/denormalization between token decimals and 18-decimal fixed point
 * - Exponentiation-based interest compounding via _rpow
 *
 * It is a stateless library intended to be called by ISLoanEngine
 * and other system modules that require consistent financial math.
 */
library ISLoanEngineCore {
    using OracleLib for OracleLib.OracleConfig;

    /////////////////////
    // Constants       //
    /////////////////////
    string public constant IS_VERSION = "1.0.0";
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /////////////////////
    // Events          //
    /////////////////////
    event InterestAccrued(
        address indexed token,
        uint256 newSupplyIndex,
        uint256 newBorrowIndex,
        uint40 timestamp
    );

    /////////////////////
    // Core Functions  //
    /////////////////////

    /**
     * @notice Accrues interest for a single token market.
     * @dev
     * - Compounds supply and borrow indices using per-second interest rates.
     * - Skips accrual if no time has passed since the last update.
     * - Should be called before any balance changes in that market.
     * @param token The address of the token (for event emission).
     * @param cfg The token's configuration storage reference.
     */
    function accrueInterest(address token, TokenConfig storage cfg) internal {
        if (!cfg.isSupported) return; // skip unsupported tokens

        uint40 currentTime = uint40(block.timestamp);
        uint40 dt = currentTime - cfg.lastUpdate;
        if (dt == 0) return; // skip if no time elapsed

        uint256 supplyRatePerSecond = cfg.supplyInterestRate / SECONDS_PER_YEAR;
        uint256 borrowRatePerSecond = cfg.borrowInterestRate / SECONDS_PER_YEAR;

        uint256 supplyFactor = _rpow(1e18 + supplyRatePerSecond, dt, 1e18);
        uint256 borrowFactor = _rpow(1e18 + borrowRatePerSecond, dt, 1e18);

        cfg.supplyIndex = (cfg.supplyIndex * supplyFactor) / 1e18;
        cfg.borrowIndex = (cfg.borrowIndex * borrowFactor) / 1e18;
        cfg.lastUpdate = currentTime;

        emit InterestAccrued(
            token,
            cfg.supplyIndex,
            cfg.borrowIndex,
            currentTime
        );
    }

    /**
     * @notice Accrues interest across all supported tokens.
     * @param tokens The array of supported token addresses.
     * @param tokenConfigs Mapping of token configurations.
     */
    function accrueAllInterest(
        address[] memory tokens,
        mapping(address => TokenConfig) storage tokenConfigs
    ) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            accrueInterest(tokens[i], tokenConfigs[tokens[i]]);
        }
    }

    /////////////////////
    // Math Utilities  //
    /////////////////////

    /**
     * @notice Exponentiation by squaring for fixed-point math.
     * @dev Used for compounding per-second interest rates.
     * @param x Base (e.g. 1e18 + ratePerSecond)
     * @param n Exponent (seconds elapsed)
     * @param base Scaling factor (e.g. 1e18)
     * @return z Result scaled by `base`
     */
    function _rpow(
        uint256 x,
        uint256 n,
        uint256 base
    ) private pure returns (uint256 z) {
        z = base;
        while (n > 0) {
            if (n % 2 != 0) {
                z = (z * x) / base;
            }
            x = (x * x) / base;
            n /= 2;
        }
    }

    /**
     * @notice This function normalizes a given amount of a token to 18 decimals.
     * It takes into account the token's original decimals and adjusts the amount
     * accordingly. This is useful for standardizing calculations across tokens
     * with different decimal places.
     * @param amount amount in token's native decimals
     * @param decimals the decimals of the token
     * @return normalized amount scaled to 18 decimals
     */
    function normalizeTo18(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256 normalized) {
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount * (10 ** (18 - decimals));
        } else {
            return amount / (10 ** (decimals - 18));
        }
    }

    /**
     * @notice This function denormalizes a given amount from 18 decimals back to
     * the token's original decimal format. It adjusts the amount based on the
     * token's decimals, allowing for accurate representation in its native form.
     * @param amount amount scaled to 18 decimals
     * @param decimals the decimals of the token
     * @return denormalized amount in token's native decimals
     */
    function denormalizeFrom18(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256 denormalized) {
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount / (10 ** (18 - decimals));
        } else {
            return amount * (10 ** (decimals - 18));
        }
    }
}
