// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title OracleLib
 * @author BlueAsset Technology Team
 *
 * @notice The OracleLib provides a unified and resilient price oracle system
 * integrating both Chainlink and Pyth Network data feeds for price discovery.
 * It ensures robust, normalized, and up-to-date price data across the protocol,
 * offering automatic fallback to secondary oracles if the primary source fails
 * or becomes stale.
 *
 * @dev Key Principles:
 * - Chainlink Primary Oracle: Fetches secure and widely adopted token/USD prices.
 * - Pyth Fallback Oracle: Acts as a redundancy layer to ensure availability.
 * - Normalization: All prices are scaled to 1e18 to ensure consistency across tokens.
 * - Freshness: Chainlink prices older than MAX_DELAY (1 hour) are rejected.
 * - Safety: Catches and ignores oracle call errors gracefully to maintain resilience.
 *
 * @dev This library is designed for read-only access within lending, collateral,
 * and liquidation logic, ensuring consistent and reliable pricing data across
 * the InterShare ecosystem.
 */
library OracleLib {
    /////////////////////
    // Errors          //
    /////////////////////
    error OracleLib__InvalidPrice();
    error OracleLib__StalePrice();
    error OracleLib__PriceTooOld(uint256 lastUpdate, uint256 maxDelay);
    error OracleLib__AllSourcesFailed();

    /////////////////////
    // Constants       //
    /////////////////////
    uint256 internal constant MAX_DELAY = 1 hours; // Maximum Chainlink staleness allowed
    uint256 internal constant PYTH_DEFAULT_AGE = 60; // Maximum acceptable Pyth data age (seconds)

    /////////////////////
    // Structs         //
    /////////////////////
    /**
     * @notice Configuration parameters for a token's oracle setup.
     * @dev Includes both Chainlink and Pyth sources for redundancy.
     */
    struct OracleConfig {
        AggregatorV3Interface chainlinkFeed; // Chainlink price feed contract (token/USD)
        IPyth pythFeed; // Pyth Network oracle contract
        bytes32 pythPriceId; // Pyth price ID for the token/USD feed
    }

    ///////////////////////////////////
    //  External/Public Functions    //
    ///////////////////////////////////

    /**
     * @notice Retrieves the latest normalized price (scaled to 1e18) for a token.
     * @dev Uses Chainlink as the primary source and Pyth as a fallback in case of failure
     *      or stale data. The function ensures price consistency and normalization.
     *
     * Steps:
     *  1. Attempts to fetch from Chainlink.
     *  2. If Chainlink is stale or unavailable, fallback to Pyth.
     *  3. Normalizes the price to 18 decimals regardless of oracle source.
     *
     * @param cfg Oracle configuration (Chainlink + Pyth)
     * @return price Latest normalized price, scaled to 1e18
     */
    function getPrice(
        OracleConfig memory cfg
    ) internal view returns (uint256 price) {
        bool chainlinkOk;
        bool pythOk;

        // --- Attempt Primary Source: Chainlink ---
        try cfg.chainlinkFeed.latestRoundData() returns (
            uint80, // roundId
            int256 answer,
            uint256, // startedAt
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (answer > 0 && answeredInRound != 0 && updatedAt != 0) {
                // Reject stale prices
                if (block.timestamp - updatedAt <= MAX_DELAY) {
                    uint8 decimals = cfg.chainlinkFeed.decimals();

                    // Normalize to 1e18
                    if (decimals <= 18) {
                        price = uint256(answer) * (10 ** (18 - decimals));
                    } else {
                        price = uint256(answer) / (10 ** (decimals - 18));
                    }

                    chainlinkOk = true;
                }
            }
        } catch {
            // Ignore Chainlink failure and fallback to Pyth
        }

        // --- Attempt Fallback Source: Pyth Network ---
        if (!chainlinkOk) {
            try
                cfg.pythFeed.getPriceNoOlderThan(
                    cfg.pythPriceId,
                    PYTH_DEFAULT_AGE
                )
            returns (PythStructs.Price memory p) {
                if (p.price > 0) {
                    // Handle negative exponents (e.g., -8 => divide)
                    if (p.expo < 0) {
                        uint256 scale = 10 ** uint32(-p.expo);
                        price = uint256(uint64(p.price)) * (1e18 / scale);
                    } else {
                        uint256 scale = 10 ** uint32(p.expo);
                        price = uint256(uint64(p.price)) * (1e18 * scale);
                    }

                    pythOk = true;
                }
            } catch {
                // Ignore Pyth failure silently
            }
        }

        // --- Validation: Ensure at least one source succeeded ---
        if (!chainlinkOk && !pythOk) {
            revert OracleLib__AllSourcesFailed();
        }
    }
}
