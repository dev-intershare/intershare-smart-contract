// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISLoanEngine} from "../../src/ISLoanEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract ISLoanEngineAccessControlTest is Test {
    ISLoanEngine engine;
    ERC20Mock usdc;
    MockV3Aggregator usdcOracle;

    address owner = address(this);
    address manager = address(0xF00D);
    address user = address(0xBEEF);
    address attacker = address(0xBAD);

    function setUp() public {
        usdc = new ERC20Mock();
        usdcOracle = new MockV3Aggregator(8, 1e8);
        engine = new ISLoanEngine(owner);
        engine.approveFundManager(manager);

        vm.startPrank(manager);
        engine.addToken(
            address(usdc),
            8000,
            address(usdcOracle),
            address(0x1234),
            bytes32("USDC/USD")
        );
        vm.stopPrank();
    }

    function test_OnlyOwnerCanApproveFundManager() public {
        address newManager = address(0x123);
        engine.approveFundManager(newManager);
        bool isApproved = engine.isFundManager(newManager);
        assertTrue(isApproved, "Owner should add fund manager");
    }

    function test_RevertOnNonOwnerApproveFundManager() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        engine.approveFundManager(address(0x999));
        vm.stopPrank();
    }

    function test_OnlyFundManagerCanRefreshTokens() public {
        vm.startPrank(manager);
        engine.refreshAllTokens(); // should succeed
        vm.stopPrank();
    }

    function test_RevertOnNonFundManagerRefreshTokens() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        engine.refreshAllTokens();
        vm.stopPrank();
    }

    function test_PauseBlocksSensitiveFunctions() public {
        vm.prank(owner);
        engine.pause();

        vm.startPrank(manager);
        vm.expectRevert(); // should revert due to paused
        engine.refreshAllTokens();
        vm.stopPrank();
    }

    function test_UnpauseRestoresOperation() public {
        vm.prank(owner);
        engine.pause();
        vm.prank(owner);
        engine.unpause();

        vm.startPrank(manager);
        engine.refreshAllTokens(); // should now succeed
        vm.stopPrank();
    }
}
