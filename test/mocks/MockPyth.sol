// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title MockPyth
 * @notice Minimal Pyth oracle mock for local testing of OracleLib
 * @dev Implements only getPriceNoOlderThan() with stubs for other required IPyth functions
 */
contract MockPyth is IPyth {
    mapping(bytes32 => int64) public prices;
    mapping(bytes32 => int32) public expos;

    function setPrice(bytes32 id, int64 price, int32 expo) external {
        prices[id] = price;
        expos[id] = expo;
    }

    function getValidTimePeriod()
        external
        view
        override
        returns (uint validTimePeriod)
    {}

    function getPrice(
        bytes32 id
    ) external view override returns (PythStructs.Price memory price) {}

    function getEmaPrice(
        bytes32 id
    ) external view override returns (PythStructs.Price memory price) {}

    function getPriceUnsafe(
        bytes32 id
    ) external view override returns (PythStructs.Price memory price) {}

    function getPriceNoOlderThan(
        bytes32 id,
        uint256 /* age */
    ) external view override returns (PythStructs.Price memory) {
        return
            PythStructs.Price({
                price: prices[id],
                conf: 0,
                expo: expos[id],
                publishTime: block.timestamp
            });
    }

    function getEmaPriceUnsafe(
        bytes32 id
    ) external view override returns (PythStructs.Price memory price) {}

    function getEmaPriceNoOlderThan(
        bytes32 id,
        uint age
    ) external view override returns (PythStructs.Price memory price) {}

    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable override {}

    function updatePriceFeedsIfNecessary(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes
    ) external payable override {}

    function getUpdateFee(
        bytes[] calldata updateData
    ) external view override returns (uint feeAmount) {}

    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    )
        external
        payable
        override
        returns (PythStructs.PriceFeed[] memory priceFeeds)
    {}
}
