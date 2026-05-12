// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDCTest is Test {
    MockUSDC internal usdc;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockUSDC(owner);
    }

    function testConstructorSetsMetadataAndOwner() public view {
        assertEq(usdc.name(), "USD Coin");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.owner(), owner);
    }

    function testMintByOwner() public {
        vm.prank(owner);
        usdc.mint(user, 1_000_000);

        assertEq(usdc.balanceOf(user), 1_000_000);
        assertEq(usdc.totalSupply(), 1_000_000);
    }

    function testMintRevertsWhenNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        usdc.mint(user, 1_000_000);
    }

    function testMintToZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        usdc.mint(address(0), 1_000_000);
    }

    function testMultipleMintsAccumulateBalanceAndSupply() public {
        vm.startPrank(owner);
        usdc.mint(user, 1_000_000);
        usdc.mint(user, 2_500_000);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), 3_500_000);
        assertEq(usdc.totalSupply(), 3_500_000);
    }

    function testTransferAfterMint() public {
        vm.prank(owner);
        usdc.mint(user, 5_000_000);

        vm.prank(user);
        bool success = usdc.transfer(stranger, 1_250_000);

        assertTrue(success);
        assertEq(usdc.balanceOf(user), 3_750_000);
        assertEq(usdc.balanceOf(stranger), 1_250_000);
    }

    function testTransferRevertsWhenInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert();
        bool success = usdc.transfer(stranger, 1);
        success;
    }

    function testApproveAndTransferFrom() public {
        vm.prank(owner);
        usdc.mint(user, 10_000_000);

        vm.prank(user);
        bool approved = usdc.approve(stranger, 4_000_000);
        assertTrue(approved);
        assertEq(usdc.allowance(user, stranger), 4_000_000);

        vm.prank(stranger);
        bool success = usdc.transferFrom(user, stranger, 3_000_000);
        assertTrue(success);

        assertEq(usdc.balanceOf(user), 7_000_000);
        assertEq(usdc.balanceOf(stranger), 3_000_000);
        assertEq(usdc.allowance(user, stranger), 1_000_000);
    }

    function testTransferFromRevertsWithoutAllowance() public {
        vm.prank(owner);
        usdc.mint(user, 1_000_000);

        vm.prank(stranger);
        vm.expectRevert();
        bool success = usdc.transferFrom(user, stranger, 1);
        success;
    }

    function testTransferFromRevertsWhenAllowanceTooLow() public {
        vm.prank(owner);
        usdc.mint(user, 1_000_000);

        vm.prank(user);
        bool approved = usdc.approve(stranger, 100_000);
        assertTrue(approved);

        vm.prank(stranger);
        vm.expectRevert();
        bool success = usdc.transferFrom(user, stranger, 100_001);
        success;
    }

    function testOwnerCanTransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        usdc.transferOwnership(newOwner);

        assertEq(usdc.owner(), newOwner);

        vm.prank(newOwner);
        usdc.mint(user, 500_000);

        assertEq(usdc.balanceOf(user), 500_000);
    }

    function testTransferOwnershipRevertsWhenNotOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        usdc.transferOwnership(newOwner);
    }

    function testRenounceOwnershipDisablesMinting() public {
        vm.prank(owner);
        usdc.renounceOwnership();

        assertEq(usdc.owner(), address(0));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                owner
            )
        );
        usdc.mint(user, 1_000_000);
    }
}
