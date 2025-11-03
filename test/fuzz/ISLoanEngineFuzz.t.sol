// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISLoanEngine} from "../../src/ISLoanEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ISLoanEngineFuzzTest is Test {
    using SafeERC20 for IERC20;

    ISLoanEngine engine;
    ERC20Mock usdt;
    ERC20Mock is21;
    MockV3Aggregator usdtOracle;
    MockV3Aggregator is21Oracle;
    MockPyth pyth;

    address user = address(0x123);
    address fundManager = address(0x456);

    bytes32 usdtPriceId = bytes32("USDT/USD");
    bytes32 is21PriceId = bytes32("IS21/USD");

    function setUp() public {
        // Deploy mocks
        usdt = new ERC20Mock();
        is21 = new ERC20Mock();
        pyth = new MockPyth();

        usdt.mint(address(this), 1_000_000e18);
        is21.mint(address(this), 1_000_000e18);

        // Mock oracles
        usdtOracle = new MockV3Aggregator(8, 1e8); // $1
        is21Oracle = new MockV3Aggregator(8, 1e8); // $1

        // Mock Pyth fallback data
        pyth.setPrice(usdtPriceId, 1e8, -8);
        pyth.setPrice(is21PriceId, 1e8, -8);

        // Deploy loan engine
        engine = new ISLoanEngine(address(this));
        engine.approveFundManager(fundManager);
        engine.approveFundManager(address(this));

        // Register tokens with full oracle config
        engine.addToken(
            address(usdt),
            7500,
            address(usdtOracle),
            address(pyth),
            usdtPriceId
        );

        engine.addToken(
            address(is21),
            8000,
            address(is21Oracle),
            address(pyth),
            is21PriceId
        );

        // Give user funds
        IERC20(address(usdt)).safeTransfer(user, 100_000e18);
        vm.startPrank(user);
        usdt.approve(address(engine), type(uint256).max);
        is21.approve(address(engine), type(uint256).max);
        vm.stopPrank();
    }

    /// -------------------------------------------------------
    /// FUZZ TESTS
    /// -------------------------------------------------------

    function testFuzz_DepositWithdraw(uint256 amount) public {
        vm.assume(amount > 0 && amount < 1_000e18);

        uint256 before = usdt.balanceOf(user);

        vm.startPrank(user);
        engine.deposit(address(usdt), amount);
        engine.withdraw(address(usdt), amount);
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), before);
        assertEq(engine.deposits(user, address(usdt)), 0);
    }

    function testFuzz_BorrowRepay(uint256 depositAmount) public {
        vm.assume(depositAmount > 1e18 && depositAmount < 1_000_000e18);

        usdt.mint(user, depositAmount);
        vm.startPrank(user);
        engine.deposit(address(usdt), depositAmount);

        uint256 borrowAmount = depositAmount / 2;

        uint256 available = engine.availableLiquidity(address(usdt));
        if (borrowAmount > available) {
            vm.expectRevert();
            engine.borrow(address(usdt), borrowAmount);
        } else {
            engine.borrow(address(usdt), borrowAmount);
            engine.repay(address(usdt), borrowAmount);
        }
        vm.stopPrank();
    }

    function testFuzz_HealthFactorAlwaysPositive(
        uint256 depositAmount,
        uint256 borrowAmount
    ) public {
        vm.assume(depositAmount > 1e18 && depositAmount < 100_000e18);
        vm.assume(borrowAmount > 0 && borrowAmount < depositAmount);

        vm.startPrank(user);
        engine.deposit(address(usdt), depositAmount);

        uint256 available = engine.availableLiquidity(address(is21));
        if (borrowAmount <= available) {
            engine.borrow(address(is21), borrowAmount);
            uint256 hf = engine.getHealthFactor(user);
            assertGe(hf, 1e18, "Health factor below safe threshold");
        } else {
            vm.expectRevert();
            engine.borrow(address(is21), borrowAmount);
        }
        vm.stopPrank();
    }

    function testFuzz_LiquidationOnlyWhenHealthFactorLow(
        uint256 depositAmount,
        uint256 borrowAmount
    ) public {
        vm.assume(depositAmount > 1e18 && depositAmount < 100_000e18);
        vm.assume(borrowAmount > 0 && borrowAmount < depositAmount * 2);

        vm.startPrank(user);
        engine.deposit(address(usdt), depositAmount);

        uint256 available = engine.availableLiquidity(address(is21));
        if (borrowAmount <= available) {
            engine.borrow(address(is21), borrowAmount);
        } else {
            vm.expectRevert();
            engine.borrow(address(is21), borrowAmount);
        }
        vm.stopPrank();

        vm.startPrank(fundManager);
        uint256 hf = engine.getHealthFactor(user);
        if (hf >= 1e18) {
            vm.expectRevert();
            engine.liquidate(user, address(is21), address(usdt), 10e18);
        } else {
            engine.liquidate(user, address(is21), address(usdt), 10e18);
        }
        vm.stopPrank();
    }
}
