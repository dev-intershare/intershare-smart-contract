// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDT} from "src/mocks/MockUSDT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDTTest is Test {
    MockUSDT internal usdt;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        usdt = new MockUSDT(owner);
    }

    function testConstructorSetsMetadataAndOwner() public view {
        assertEq(usdt.name(), "Tether USD");
        assertEq(usdt.symbol(), "USDT");
        assertEq(usdt.decimals(), 6);
        assertEq(usdt.owner(), owner);
    }

    function testMintByOwner() public {
        vm.prank(owner);
        usdt.mint(user, 1_000_000);

        assertEq(usdt.balanceOf(user), 1_000_000);
        assertEq(usdt.totalSupply(), 1_000_000);
    }

    function testMintRevertsWhenNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        usdt.mint(user, 1_000_000);
    }

    function testMintToZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        usdt.mint(address(0), 1_000_000);
    }

    function testMultipleMintsAccumulateBalanceAndSupply() public {
        vm.startPrank(owner);
        usdt.mint(user, 1_000_000);
        usdt.mint(user, 2_500_000);
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), 3_500_000);
        assertEq(usdt.totalSupply(), 3_500_000);
    }

    function testTransferAfterMint() public {
        vm.prank(owner);
        usdt.mint(user, 5_000_000);

        vm.prank(user);
        bool success = usdt.transfer(stranger, 1_250_000);

        assertTrue(success);
        assertEq(usdt.balanceOf(user), 3_750_000);
        assertEq(usdt.balanceOf(stranger), 1_250_000);
    }

    function testTransferRevertsWhenInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert();
        usdt.transfer(stranger, 1);
    }

    function testApproveAndTransferFrom() public {
        vm.prank(owner);
        usdt.mint(user, 10_000_000);

        vm.prank(user);
        bool approved = usdt.approve(stranger, 4_000_000);
        assertTrue(approved);
        assertEq(usdt.allowance(user, stranger), 4_000_000);

        vm.prank(stranger);
        bool success = usdt.transferFrom(user, stranger, 3_000_000);
        assertTrue(success);

        assertEq(usdt.balanceOf(user), 7_000_000);
        assertEq(usdt.balanceOf(stranger), 3_000_000);
        assertEq(usdt.allowance(user, stranger), 1_000_000);
    }

    function testTransferFromRevertsWithoutAllowance() public {
        vm.prank(owner);
        usdt.mint(user, 1_000_000);

        vm.prank(stranger);
        vm.expectRevert();
        usdt.transferFrom(user, stranger, 1);
    }

    function testTransferFromRevertsWhenAllowanceTooLow() public {
        vm.prank(owner);
        usdt.mint(user, 1_000_000);

        vm.prank(user);
        usdt.approve(stranger, 100_000);

        vm.prank(stranger);
        vm.expectRevert();
        usdt.transferFrom(user, stranger, 100_001);
    }

    function testOwnerCanTransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        usdt.transferOwnership(newOwner);

        assertEq(usdt.owner(), newOwner);

        vm.prank(newOwner);
        usdt.mint(user, 500_000);

        assertEq(usdt.balanceOf(user), 500_000);
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
        usdt.transferOwnership(newOwner);
    }

    function testRenounceOwnershipDisablesMinting() public {
        vm.prank(owner);
        usdt.renounceOwnership();

        assertEq(usdt.owner(), address(0));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                owner
            )
        );
        usdt.mint(user, 1_000_000);
    }
}
