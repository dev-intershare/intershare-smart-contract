// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISLoanEngine} from "../../src/ISLoanEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract ISLoanEngineInterestTest is Test {
    ISLoanEngine engine;
    ERC20Mock usdc;
    ERC20Mock dai;
    MockV3Aggregator usdcOracle;
    MockV3Aggregator daiOracle;
    address manager = address(0xF00D);
    address user = address(0xBEEF);

    function setUp() public {
        usdc = new ERC20Mock();
        dai = new ERC20Mock();

        usdcOracle = new MockV3Aggregator(8, 1e8);
        daiOracle = new MockV3Aggregator(8, 1e8);

        engine = new ISLoanEngine(address(this));
        engine.approveFundManager(manager);

        vm.startPrank(manager);
        engine.addToken(
            address(usdc),
            8000,
            address(usdcOracle),
            address(0x1234), // dummy Pyth
            bytes32("USDC/USD")
        );
        engine.addToken(
            address(dai),
            8000,
            address(daiOracle),
            address(0x1234),
            bytes32("DAI/USD")
        );
        vm.stopPrank();
    }

    /// @dev Verify initial interest indices are set to 1e18
    function test_InitialInterestIndices() public view {
        (, , , , uint256 supplyIndex, uint256 borrowIndex, , , , ) = engine
            .tokenConfigs(address(usdc));
        assertEq(supplyIndex, 1e18, "Initial supply index must be 1e18");
        assertEq(borrowIndex, 1e18, "Initial borrow index must be 1e18");
    }

    /// @dev Simulate passage of 30 days and verify interest indices increase correctly
    function test_AccrueInterestOverTime() public {
        vm.startPrank(manager);

        (, , , , uint256 beforeSupply, uint256 beforeBorrow, , , , ) = engine
            .tokenConfigs(address(usdc));

        vm.warp(block.timestamp + 30 days);
        engine.refreshAllTokens();

        (, , , , uint256 afterSupply, uint256 afterBorrow, , , , ) = engine
            .tokenConfigs(address(usdc));

        assertGt(afterSupply, beforeSupply, "supply index should increase");
        assertGt(afterBorrow, beforeBorrow, "borrow index should increase");

        vm.stopPrank();
    }

    /// @dev Ensure accrual updates both tokens when multiple supported tokens exist
    function test_AccrueAllTokens() public {
        vm.startPrank(manager);

        (, , , , uint256 usdcBefore, , , , , ) = engine.tokenConfigs(
            address(usdc)
        );

        (, , , , uint256 daiBefore, , , , , ) = engine.tokenConfigs(
            address(dai)
        );

        vm.warp(block.timestamp + 7 days);
        engine.refreshAllTokens();

        (, , , , uint256 usdcAfter, , , , , ) = engine.tokenConfigs(
            address(usdc)
        );

        (, , , , uint256 daiAfter, , , , , ) = engine.tokenConfigs(
            address(dai)
        );

        assertGt(usdcAfter, usdcBefore, "USDC index should update");
        assertGt(daiAfter, daiBefore, "DAI index should update");

        vm.stopPrank();
    }

    /// @dev Test precision holds for large dt (e.g., 1 year)
    function test_AccrueLargeTimeJump() public {
        vm.startPrank(manager);

        (, , , , , uint256 beforeBorrow, , , , ) = engine.tokenConfigs(
            address(usdc)
        );

        vm.warp(block.timestamp + 365 days);
        engine.refreshAllTokens();

        (, , , , , uint256 afterBorrow, , , , ) = engine.tokenConfigs(
            address(usdc)
        );

        // Borrow index should grow by roughly the borrow APR (13%)
        uint256 expectedMin = (beforeBorrow * 11300) / 10000;
        assertGe(
            afterBorrow,
            expectedMin,
            "Borrow index should grow at least ~13% per year"
        );

        vm.stopPrank();
    }

    /// @dev Confirm events emitted on refresh
    function test_InterestAccruedEventEmitted() public {
        vm.startPrank(manager);
        vm.expectEmit(true, false, false, false);
        emit ISLoanEngine.AllInterestRefreshed(block.timestamp + 1);
        vm.warp(block.timestamp + 1);
        engine.refreshAllTokens();
        vm.stopPrank();
    }
}
