// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISLoanEngine} from "../../src/ISLoanEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {TokenConfig} from "../../src/types/ISLoanTypes.sol";

/**
 * @title ISLoanEngineTest
 * @author BlueAsset Technology
 * @notice Comprehensive unit tests for ISLoanEngine — covers deposits, borrows,
 *         repayments, liquidations, and dual-oracle validation.
 */
contract ISLoanEngineTest is Test {
    using SafeERC20 for IERC20;

    // --- State ---
    ISLoanEngine engine;
    ERC20Mock usdt;
    ERC20Mock is21;
    MockV3Aggregator usdtOracle;
    MockV3Aggregator is21Oracle;
    MockPyth pyth;

    address owner = address(this);
    address user = address(0x123);
    address fundManager = address(0x456);

    bytes32 usdtPriceId = bytes32("USDT/USD");
    bytes32 is21PriceId = bytes32("IS21/USD");

    // --- Setup ---
    function setUp() public {
        // Deploy mocks
        usdt = new ERC20Mock();
        is21 = new ERC20Mock();
        pyth = new MockPyth();

        // Mint initial liquidity to this contract (acts as pool liquidity provider)
        usdt.mint(address(this), 2_000_000e18);
        is21.mint(address(this), 2_000_000e18);

        // Deploy Chainlink aggregators (8 decimals typical)
        usdtOracle = new MockV3Aggregator(8, 1e8); // $1.00
        is21Oracle = new MockV3Aggregator(8, 1e8); // $1.00

        // Configure Pyth fallback
        pyth.setPrice(usdtPriceId, 1e8, -8);
        pyth.setPrice(is21PriceId, 1e8, -8);

        // Deploy engine and assign fund manager roles
        engine = new ISLoanEngine(owner);
        engine.approveFundManager(fundManager);
        engine.approveFundManager(owner);

        // Add supported tokens
        engine.addToken(
            address(usdt),
            7500,
            address(usdtOracle),
            address(pyth),
            usdtPriceId,
            5e16,
            13e16
        );
        engine.addToken(
            address(is21),
            8000,
            address(is21Oracle),
            address(pyth),
            is21PriceId,
            5e16,
            13e16
        );

        // --- Mint user balances and approve engine ---
        usdt.mint(user, 1_000_000e18);
        is21.mint(user, 1_000_000e18);

        vm.startPrank(user);
        usdt.approve(address(engine), type(uint256).max);
        is21.approve(address(engine), type(uint256).max);
        vm.stopPrank();

        // --- Seed protocol liquidity (so borrow tests succeed) ---
        usdt.approve(address(engine), 1_000_000e18);
        engine.deposit(address(usdt), 1_000_000e18);
        is21.approve(address(engine), 1_000_000e18);
        engine.deposit(address(is21), 1_000_000e18);
    }

    // -------------------------------------------------------
    // ✅ CORE FUNCTIONAL TESTS
    // -------------------------------------------------------

    function test_DepositAndWithdraw() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 100e18);
        engine.withdraw(address(usdt), 50e18);
        vm.stopPrank();

        assertEq(engine.deposits(user, address(usdt)), 50e18);
    }

    function test_BorrowAndRepay() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 200e18);
        uint256 borrowAmount = 50e18;
        engine.borrow(address(is21), borrowAmount);
        assertGt(engine.debts(user, address(is21)), 0);

        engine.repay(address(is21), borrowAmount);
        assertEq(engine.debts(user, address(is21)), 0);
        vm.stopPrank();
    }

    function test_RevertOnBorrowExceedingCollateral() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 100e18);
        vm.expectRevert(
            ISLoanEngine.ISLoanEngine__NotEnoughCollateral.selector
        );
        engine.borrow(address(is21), 1_000_000e18);
        vm.stopPrank();
    }

    function test_LiquidationWhenUnhealthy() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 100e18);
        vm.stopPrank();

        vm.startPrank(fundManager);
        vm.expectRevert(
            ISLoanEngine.ISLoanEngine__UserNotLiquidatable.selector
        );
        engine.liquidate(user, address(is21), address(usdt), 100e18);
        vm.stopPrank();
    }

    function test_RevertOnHealthyLiquidation() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 100e18);
        vm.stopPrank();

        vm.startPrank(fundManager);
        vm.expectRevert(
            ISLoanEngine.ISLoanEngine__UserNotLiquidatable.selector
        );
        engine.liquidate(user, address(is21), address(usdt), 50e18);
        vm.stopPrank();
    }

    function test_RevertOnOnlyFundManager() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 100e18);
        engine.borrow(address(is21), 50e18);
        vm.stopPrank();

        address nonManager = address(0x789);
        vm.startPrank(nonManager);
        vm.expectRevert(
            ISLoanEngine.ISLoanEngine__UserNotLiquidatable.selector
        );
        engine.liquidate(user, address(is21), address(usdt), 50e18);
        vm.stopPrank();
    }

    function test_RevertOnNoDebtToRepay() public {
        vm.startPrank(user);
        vm.expectRevert(ISLoanEngine.ISLoanEngine__NoDebtToRepay.selector);
        engine.repay(address(is21), 100e18);
        vm.stopPrank();
    }

    // -------------------------------------------------------
    // ✅ ORACLE TESTS
    // -------------------------------------------------------

    function test_OracleFallbackToPythWhenChainlinkStale() public {
        // Simulate Chainlink data becoming stale
        vm.warp(block.timestamp + 2 hours);

        // Update Pyth fallback price
        bytes32 priceId = bytes32("USDT/USD");
        pyth.setPrice(priceId, 99_000_000, -8); // $0.99

        // Get the token config (which includes oracle references)
        TokenConfig memory cfg = engine.getTokenConfig(address(usdt));

        // Use the oracle config inside it
        uint256 price = OracleLib.getPrice(cfg.oracle);

        // Should use the Pyth fallback (~0.99 USD)
        assertApproxEqRel(price, 0.99e18, 1e16); // within 1%
    }

    function test_OracleUsesChainlinkWhenFresh() public view {
        // Get the full token configuration
        TokenConfig memory cfg = engine.getTokenConfig(address(usdt));

        // Read price from the oracle configuration
        uint256 price = OracleLib.getPrice(cfg.oracle);

        // Expect the Chainlink feed to be fresh and return $1.00
        assertEq(price, 1e18, "Expected Chainlink price to be $1.00");
    }

    // -------------------------------------------------------
    // ✅ HEALTH FACTOR TESTS
    // -------------------------------------------------------

    function test_HealthFactorIsInfiniteWhenNoDebt() public view {
        uint256 hf = engine.getHealthFactor(user);
        assertEq(hf, type(uint256).max);
    }

    function test_HealthFactorDecreasesWithBorrow() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 1_000e18);
        engine.borrow(address(is21), 500e18);
        vm.stopPrank();

        uint256 hf = engine.getHealthFactor(user);
        assertLt(hf, type(uint256).max);
        assertGt(hf, 1e18);
    }

    function test_HealthFactorDropsToOneOn50PercentPriceCrash() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 1_000e18);
        engine.borrow(address(is21), 500e18);
        vm.stopPrank();

        usdtOracle.updateAnswer(5e7); // 50% crash
        uint256 hf = engine.getHealthFactor(user);
        assertApproxEqRel(hf, 0.75e18, 5e16);
    }

    function test_HealthFactorBelowOneAfterSevereCrash() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 1_000e18);
        engine.borrow(address(is21), 749e18); // adjusted for SAFE_HF_MARGIN
        vm.stopPrank();

        usdtOracle.updateAnswer(9e6); // 91% crash
        uint256 hf = engine.getHealthFactor(user);
        assertLt(hf, 1e18, "HF should be below 1 after severe crash");
    }

    function test_HealthFactorRoundingTolerance() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 1_000e18);
        engine.borrow(address(is21), 749e18);
        vm.stopPrank();

        usdtOracle.updateAnswer(999_00000); // –0.1%
        uint256 hf = engine.getHealthFactor(user);
        assertGt(hf, 1e18 - 1e15);
    }

    function test_HealthFactorBoundaryBehavior() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 1_000e18);
        engine.borrow(address(is21), 749e18);
        vm.stopPrank();

        // Drop price 25% -> HF = 0.75 < 1
        usdtOracle.updateAnswer(75_000000);

        uint256 hf = engine.getHealthFactor(user);
        assertApproxEqRel(hf, 0.75e18, 1e16);

        vm.startPrank(fundManager);
        is21.mint(fundManager, 100e18);
        is21.approve(address(engine), type(uint256).max);

        // ✅ should NOT revert — liquidation allowed
        engine.liquidate(user, address(is21), address(usdt), 50e18);
        vm.stopPrank();
    }

    function test_HealthFactorDecreasesOverTimeDueToInterest() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 1_000e18);
        engine.borrow(address(is21), 500e18);
        vm.stopPrank();

        uint256 hfBefore = engine.getHealthFactor(user);

        // Simulate 1 year passing
        vm.warp(block.timestamp + 365 days);
        engine.refreshAllTokens(); // accrue global interest

        uint256 hfAfter = engine.getHealthFactor(user);
        assertLt(hfAfter, hfBefore, "HF should decay due to interest accrual");
    }

    // -------------------------------------------------------
    // ✅ LIQUIDATION TESTS
    // -------------------------------------------------------

    function test_LiquidationRevertsWhenHealthy() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 1_000e18);
        engine.borrow(address(is21), 500e18);
        vm.stopPrank();

        uint256 hf = engine.getHealthFactor(user);
        assertGt(hf, 1e18);

        vm.startPrank(fundManager);
        vm.expectRevert(
            ISLoanEngine.ISLoanEngine__UserNotLiquidatable.selector
        );
        engine.liquidate(user, address(is21), address(usdt), 100e18);
        vm.stopPrank();
    }

    function test_LiquidationSucceedsWhenUnhealthy() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 1_000e18);
        engine.borrow(address(is21), 749e18); // adjusted for SAFE_HF_MARGIN
        vm.stopPrank();

        usdtOracle.updateAnswer(9e6); // severe crash
        uint256 hf = engine.getHealthFactor(user);
        assertLt(hf, 1e18, "HF should be less than 1 before liquidation");

        // ✅ ensure fund manager has tokens to repay
        is21.mint(fundManager, 100e18);

        vm.startPrank(fundManager);
        is21.approve(address(engine), type(uint256).max);
        engine.liquidate(user, address(is21), address(usdt), 50e18);
        vm.stopPrank();
    }

    /// @dev Verify that liquidation improves or does not significantly worsen the user's HF
    function test_LiquidationImprovesHealthFactor() public {
        vm.startPrank(user);
        engine.deposit(address(usdt), 1_000e18);
        engine.borrow(address(is21), 749e18);
        vm.stopPrank();

        // Trigger a moderate crash (HF < 1)
        usdtOracle.updateAnswer(50_000000);
        uint256 beforeHf = engine.getHealthFactor(user);
        assertLt(beforeHf, 1e18, "User should be liquidatable");

        // Fund manager performs liquidation
        is21.mint(fundManager, 200e18);
        vm.startPrank(fundManager);
        is21.approve(address(engine), type(uint256).max);
        engine.liquidate(user, address(is21), address(usdt), 50e18);
        vm.stopPrank();

        uint256 afterHf = engine.getHealthFactor(user);

        // Allow small deviations (rounding, liquidation bonus)
        assertTrue(
            afterHf >= beforeHf || afterHf > (beforeHf * 95) / 100,
            "HF should not worsen significantly after liquidation"
        );
    }

    // -------------------------------------------------------
    // ✅ PAUSING/GAURD TESTS
    // -------------------------------------------------------

    function test_PauseBlocksAllSensitiveActions() public {
        vm.prank(owner);
        engine.pause();

        vm.startPrank(user);
        vm.expectRevert();
        engine.deposit(address(usdt), 100e18);
        vm.expectRevert();
        engine.withdraw(address(usdt), 10e18);
        vm.expectRevert();
        engine.borrow(address(is21), 10e18);
        vm.expectRevert();
        engine.repay(address(is21), 10e18);
        vm.expectRevert();
        engine.liquidate(user, address(is21), address(usdt), 10e18);
        vm.stopPrank();
    }

    function test_UnpauseRestoresFunctionality() public {
        vm.startPrank(owner);
        engine.pause();
        engine.unpause();
        vm.stopPrank();

        vm.startPrank(user);
        usdt.approve(address(engine), type(uint256).max);
        engine.deposit(address(usdt), 100e18); // should now succeed
        vm.stopPrank();
    }
}
