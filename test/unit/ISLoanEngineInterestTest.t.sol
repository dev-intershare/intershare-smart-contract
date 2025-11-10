// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISLoanEngine} from "../../src/ISLoanEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {TokenConfig} from "../../src/types/ISLoanTypes.sol";

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
            bytes32("USDC/USD"),
            5e16,
            13e16
        );
        engine.addToken(
            address(dai),
            8000,
            address(daiOracle),
            address(0x1234),
            bytes32("DAI/USD"),
            5e16,
            13e16
        );
        vm.stopPrank();
    }

    /// @dev Verify initial interest indices are set to 1e18
    function test_InitialInterestIndices() public view {
        TokenConfig memory cfg = engine.getTokenConfig(address(usdc));
        assertEq(cfg.supplyIndex, 1e18, "Initial supply index must be 1e18");
        assertEq(cfg.borrowIndex, 1e18, "Initial borrow index must be 1e18");
    }

    /// @dev Simulate passage of 30 days and verify interest indices increase correctly
    function test_AccrueInterestOverTime() public {
        vm.startPrank(manager);

        // Get config before interest accrual
        TokenConfig memory beforeCfg = engine.getTokenConfig(address(usdc));
        uint256 beforeSupply = beforeCfg.supplyIndex;
        uint256 beforeBorrow = beforeCfg.borrowIndex;

        // Simulate 30 days passing
        vm.warp(block.timestamp + 30 days);
        engine.refreshAllTokens();

        // Get config after accrual
        TokenConfig memory afterCfg = engine.getTokenConfig(address(usdc));
        uint256 afterSupply = afterCfg.supplyIndex;
        uint256 afterBorrow = afterCfg.borrowIndex;

        // Assert growth
        assertGt(afterSupply, beforeSupply, "supply index should increase");
        assertGt(afterBorrow, beforeBorrow, "borrow index should increase");

        vm.stopPrank();
    }

    /// @dev Ensure accrual updates both tokens when multiple supported tokens exist
    function test_AccrueAllTokens() public {
        vm.startPrank(manager);

        // Get initial indices
        TokenConfig memory usdcBeforeCfg = engine.getTokenConfig(address(usdc));
        TokenConfig memory daiBeforeCfg = engine.getTokenConfig(address(dai));

        uint256 usdcBefore = usdcBeforeCfg.supplyIndex;
        uint256 daiBefore = daiBeforeCfg.supplyIndex;

        // Advance time by 7 days
        vm.warp(block.timestamp + 7 days);

        // Trigger interest accrual for all tokens
        engine.refreshAllTokens();

        // Fetch updated configs
        TokenConfig memory usdcAfterCfg = engine.getTokenConfig(address(usdc));
        TokenConfig memory daiAfterCfg = engine.getTokenConfig(address(dai));

        uint256 usdcAfter = usdcAfterCfg.supplyIndex;
        uint256 daiAfter = daiAfterCfg.supplyIndex;

        // Assert that both indices increased
        assertGt(usdcAfter, usdcBefore, "USDC index should update");
        assertGt(daiAfter, daiBefore, "DAI index should update");

        vm.stopPrank();
    }

    /// @dev Test precision holds for large dt (e.g., 1 year)
    function test_AccrueLargeTimeJump() public {
        vm.startPrank(manager);

        // Get the borrow index before interest accrual
        TokenConfig memory beforeCfg = engine.getTokenConfig(address(usdc));
        uint256 beforeBorrow = beforeCfg.borrowIndex;

        // Simulate 1 year passing
        vm.warp(block.timestamp + 365 days);
        engine.refreshAllTokens();

        // Get the borrow index after interest accrual
        TokenConfig memory afterCfg = engine.getTokenConfig(address(usdc));
        uint256 afterBorrow = afterCfg.borrowIndex;

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
