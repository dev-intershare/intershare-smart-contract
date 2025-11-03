// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IS21Engine, FiatReserves} from "../../src/IS21Engine.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20("Mock", "MOCK") {
    constructor() {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract IS21EngineTest is Test {
    using SafeERC20 for IERC20;

    IS21Engine internal engine;
    MockERC20 internal mock;

    address internal owner = address(0xA11CE);
    address internal manager = address(0xB0B);
    address internal manager2 = address(0xB0B2);
    address internal auditor = address(0xC0C0A);
    address internal user = address(0xD00D);
    address internal stranger = address(0xEEEF);

    function setUp() public {
        vm.label(owner, "OWNER");
        vm.label(manager, "FUND_MANAGER_1");
        vm.label(manager2, "FUND_MANAGER_2");
        vm.label(auditor, "AUDITOR_1");
        vm.label(user, "USER");
        vm.label(stranger, "STRANGER");

        engine = new IS21Engine(owner);
        mock = new MockERC20();

        // Give owner the power to set roles used in many tests
        vm.startPrank(owner);
        engine.approveFundManager(manager);
        engine.approveAuditor(auditor);
        vm.stopPrank();
    }

    /* ---------------- Owner / Role control ---------------- */

    function test_RevokeFundManager() public {
        // Owner revokes manager
        vm.prank(owner);
        engine.revokeFundManager(manager);
        assertFalse(engine.isFundManager(manager));
    }

    /* ---------------- Mint / Burn ---------------- */

    function test_Mint_ToSelf_viaMintIS21() public {
        vm.prank(manager);
        engine.mintIs21(100 ether);
        assertEq(engine.balanceOf(manager), 100 ether);
    }

    function test_Mint_ToOther_viaMintIs21To() public {
        vm.prank(manager);
        engine.mintIs21To(user, 777);
        assertEq(engine.balanceOf(user), 777);
    }

    function test_Mint_Reverts_WhenPaused() public {
        vm.prank(owner);
        engine.pause();

        vm.prank(manager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        engine.mintIs21(1);
    }

    function test_Mint_Reverts_WhenNotFundManager() public {
        // Calls external mint which forwards to mintIs21To (onlyFundManager)
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__OnlyFundManagerCanExecute.selector
            )
        );
        engine.mintIs21(1);
    }

    function test_Mint_Reverts_ZeroAmount() public {
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__AmountMustBeMoreThanZero.selector
            )
        );
        engine.mintIs21(0);
    }

    function test_CannotSendToContract() public {
        vm.startPrank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__CannotSendToContract.selector
            )
        );
        engine.mintIs21To(address(engine), 1e18);
        vm.stopPrank();
    }

    function test_MintTo_Reverts_ZeroAddress() public {
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__NotZeroAddress.selector
            )
        );
        engine.mintIs21To(address(0), 1);
    }

    function test_Burn_ByFundManager() public {
        vm.startPrank(manager);
        engine.mintIs21(1_000);
        engine.burnIs21(250);
        vm.stopPrank();

        assertEq(engine.balanceOf(manager), 750);
        // totalSupply decreased accordingly
        assertEq(engine.totalSupply(), 750);
    }

    function test_Burn_Reverts_TooMuch() public {
        vm.startPrank(manager);
        engine.mintIs21(10);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__BurnAmountExceedsBalance.selector
            )
        );
        engine.burnIs21(11);
        vm.stopPrank();
    }

    function test_Burn_Reverts_ZeroAmount() public {
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__AmountMustBeMoreThanZero.selector
            )
        );
        engine.burnIs21(0);
    }

    /* ---------------- Auditing / Proof hash ---------------- */

    function test_SetReserveProofHash_ByAuditor() public {
        vm.prank(auditor);
        engine.setReserveProofHash("ipfs://cid-123");
        assertEq(engine.getLatestReserveProofHash(), "ipfs://cid-123");
    }

    function test_SetReserveProofHash_Revert_NotAuditor() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__OnlyAuditorCanExecute.selector
            )
        );
        engine.setReserveProofHash("nope");
    }

    function test_VerifyReserves_EmitsEvent() public {
        vm.prank(auditor);
        vm.expectEmit(true, false, false, true);
        emit IS21Engine.ReserveVerified(auditor, block.timestamp, "ok");
        engine.verifyReserves("ok");
    }

    /* ---------------- Fiat reserves ---------------- */

    function test_UpdateSingleReserve_AndRead() public {
        bytes32 usd = bytes32("USD");
        vm.prank(manager);
        vm.expectEmit(true, true, false, true);
        emit IS21Engine.FiatReserveUpdated(
            manager,
            usd,
            123_45,
            block.timestamp
        );
        engine.updateFiatReserve(usd, 123_45);

        assertEq(engine.getFiatReserve(usd), 123_45);
    }

    function test_UpdateMultipleReserves_AndReadArray() public {
        bytes32 usd = bytes32("USD");
        bytes32 eur = bytes32("EUR");
        bytes32 zar = bytes32("ZAR");

        // allocate memory array of length 3
        FiatReserves[] memory arr = new FiatReserves[](3);
        arr[0] = FiatReserves({currency: usd, amount: 100});
        arr[1] = FiatReserves({currency: eur, amount: 200});
        arr[2] = FiatReserves({currency: zar, amount: 300});

        vm.prank(manager);
        engine.updateFiatReserves(arr);

        // allocate memory array of length 3
        bytes32[] memory query = new bytes32[](3);
        query[0] = usd;
        query[1] = eur;
        query[2] = zar;

        uint256[] memory out = engine.getFiatReserves(query);
        assertEq(out.length, 3);
        assertEq(out[0], 100);
        assertEq(out[1], 200);
        assertEq(out[2], 300);
    }

    function test_UpdateReserve_Revert_NotFundManager() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__OnlyFundManagerCanExecute.selector
            )
        );
        engine.updateFiatReserve(bytes32("USD"), 1);
    }

    /* ---------------- ETH rejection ---------------- */

    function test_Receive_RevertsETH() public {
        (bool ok, bytes memory data) = address(engine).call{value: 1 ether}("");
        assertFalse(ok);
        // Custom error selector check
        bytes4 sel = bytes4(data);
        assertEq(sel, IS21Engine.IS21Engine__ETHNotAccepted.selector);
    }

    function test_Fallback_RevertsETH() public {
        // Call with non-empty calldata to trigger fallback
        (bool ok, bytes memory data) = address(engine).call{value: 1 wei}(
            abi.encodeWithSignature("doesNotExist()")
        );
        assertFalse(ok);
        bytes4 sel = bytes4(data);
        assertEq(sel, IS21Engine.IS21Engine__ETHNotAccepted.selector);
    }

    /* ---------------- Rescue ERC20 ---------------- */

    function test_RescueERC20_ByOwner() public {
        // Send MOCK to engine, then owner rescues to user
        mock.mint(address(this), 1_000);
        assertTrue(mock.transfer(address(engine), 600));
        assertEq(mock.balanceOf(address(engine)), 600);

        vm.prank(owner);
        engine.rescueErc20(address(mock), 600, user);

        assertEq(mock.balanceOf(address(engine)), 0);
        assertEq(mock.balanceOf(user), 600);
    }

    function test_RescueERC20_Revert_ZeroTo() public {
        mock.mint(address(this), 100);
        assertTrue(mock.transfer(address(engine), 100));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__NotZeroAddress.selector
            )
        );
        engine.rescueErc20(address(mock), 100, address(0));
    }

    function test_RescueERC20_Revert_ZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IS21Engine.IS21Engine__NotZeroAddress.selector
            )
        );
        engine.rescueErc20(address(0), 100, user);
    }

    function test_RevokeAuditor_NoOpWhenAlreadyFalse() public {
        // fresh non-zero address not used/approved anywhere else
        address someone = makeAddr("freshAuditor");

        // state is already false for this address
        assertFalse(engine.isAuditor(someone));

        // revoke should be a no-op and not revert (nonZeroAddress is satisfied)
        vm.prank(owner);
        engine.revokeAuditor(someone);

        // still false
        assertFalse(engine.isAuditor(someone));
    }

    function test_ApproveFundManager_Idempotent() public {
        // first time: sets to true
        vm.prank(owner);
        engine.approveFundManager(manager);
        assertTrue(engine.isFundManager(manager));

        // second time: no state change (false branch)
        vm.prank(owner);
        engine.approveFundManager(manager);
        assertTrue(engine.isFundManager(manager));
    }

    function test_ApproveAuditor_Idempotent() public {
        vm.prank(owner);
        engine.approveAuditor(auditor);
        assertTrue(engine.isAuditor(auditor));

        vm.prank(owner);
        engine.approveAuditor(auditor); // false branch
        assertTrue(engine.isAuditor(auditor));
    }

    function test_VerifyReserves_Reverts_WhenNotAuditor() public {
        vm.expectRevert(IS21Engine.IS21Engine__OnlyAuditorCanExecute.selector);
        engine.verifyReserves("nope"); // caller is not auditor
    }

    function test_GetFiatReserve_UnknownCurrency_IsZero() public view {
        bytes32 jpy = bytes32("JPY"); // never set
        assertEq(engine.getFiatReserve(jpy), 0);
    }

    function test_UpdateFiatReserves_EmptyArray_NoOp() public {
        FiatReserves[] memory empty = new FiatReserves[](0);

        vm.prank(owner); // make a fund manager first
        engine.approveFundManager(manager);

        vm.prank(manager);

        engine.updateFiatReserves(empty); // loop not entered (implicit branch)
        // nothing to assert; just hitting the path
    }

    function test_GetFiatReserves_EmptyQuery_ReturnsEmpty() public view {
        bytes32[] memory empty = new bytes32[](0);
        uint256[] memory out = engine.getFiatReserves(empty);
        assertEq(out.length, 0);
    }

    function test_Burn_Reverts_WhenNotFundManager() public {
        vm.expectRevert(
            IS21Engine.IS21Engine__OnlyFundManagerCanExecute.selector
        );
        engine.burnIs21(1);
    }

    function test_RevokeFundManager_NoOp_WhenAlreadyFalse() public {
        address fresh = makeAddr("freshManagerNoOp");
        assertFalse(engine.isFundManager(fresh)); // never approved
        vm.prank(owner);
        engine.revokeFundManager(fresh); // no-op
        assertFalse(engine.isFundManager(fresh));
    }

    function test_RevokeAuditor_NoOp_WhenAlreadyFalse() public {
        address fresh = makeAddr("freshAuditorNoOp2");
        assertFalse(engine.isAuditor(fresh)); // never approved
        vm.prank(owner);
        engine.revokeAuditor(fresh); // no-op
        assertFalse(engine.isAuditor(fresh));
    }

    function test_Transfer_Reverts_WhenPaused() public {
        vm.startPrank(manager);
        engine.mintIs21(100);
        vm.stopPrank();

        vm.prank(owner);
        engine.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        bool success = engine.transfer(address(0xBEEF), 1);
        assertFalse(success);
    }

    /* ---------------- Ownable: constructor & basic ownership ---------------- */

    function test_Owner_IsConstructorParam() public view {
        // Ownable(owner) in constructor
        assertEq(engine.owner(), owner);
    }

    function test_OnlyOwner_CannotBeStranger_OnOwnerOnlyFns() public {
        // stranger cannot call any onlyOwner function
        vm.startPrank(stranger);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        engine.approveFundManager(manager2);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        engine.revokeFundManager(manager);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        engine.approveAuditor(address(0xABCD));

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        engine.revokeAuditor(auditor);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        engine.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        engine.unpause();

        // rescueErc20 is owner-only
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        engine.rescueErc20(address(mock), 1, user);

        vm.stopPrank();
    }

    function test_TransferOwnership_EmitsEvent_AndRestrictsAccess() public {
        address newOwner = makeAddr("NEW_OWNER");

        // Expect Ownable event
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Ownable.OwnershipTransferred(owner, newOwner);
        engine.transferOwnership(newOwner);

        assertEq(engine.owner(), newOwner);

        // Old owner now blocked
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                owner
            )
        );
        engine.pause();

        // New owner allowed
        vm.prank(newOwner);
        engine.pause();
        vm.prank(newOwner);
        engine.unpause();
    }

    function test_TransferOwnership_Revert_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableInvalidOwner.selector,
                address(0)
            )
        );
        engine.transferOwnership(address(0));
    }

    function test_RenounceOwnership_BlocksOwnerOnly() public {
        // Renounce from the real owner
        vm.prank(owner);
        engine.renounceOwnership();
        assertEq(engine.owner(), address(0));

        // Former owner can no longer call owner-only functions
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                owner
            )
        );
        engine.pause();

        // Any other account also reverts
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        engine.pause();

        // (Optional) If you call from the test contract itself:
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        engine.pause();
    }

    /* ---------------- Pause/Unpause events & gating ---------------- */

    function test_Pause_Unpause_OnlyOwner_EmitsOurEvents() public {
        // Pause
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IS21Engine.ContractPaused(owner, block.timestamp);
        engine.pause();

        // Transfer blocked while paused (you already test this)
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bool success = engine.transfer(address(0xBEEF), 1);
        assertFalse(success);

        // Unpause
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IS21Engine.ContractUnpaused(owner, block.timestamp);
        engine.unpause();

        // Transfer ok after unpause
        vm.prank(manager);
        engine.mintIs21(10);
        vm.prank(manager);
        bool success2 = engine.transfer(user, 1);
        assertTrue(success2);
    }

    /* ---------------- Rescue ERC20: owner-only & happy path coverage ---------------- */

    function test_RescueERC20_Revert_NotOwner() public {
        mock.mint(address(this), 100);
        assertTrue(mock.transfer(address(engine), 100));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        engine.rescueErc20(address(mock), 100, user);
    }

    /* ---------------- Fund manager approval remains after ownership change ---------------- */

    function test_FundManagerApproval_Persists_AfterOwnershipTransfer() public {
        // Owner approves manager2
        vm.prank(owner);
        engine.approveFundManager(manager2);
        assertTrue(engine.isFundManager(manager2));

        // Transfer ownership
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        engine.transferOwnership(newOwner);

        // manager2 can still mint
        vm.prank(manager2);
        engine.mintIs21(55);
        assertEq(engine.balanceOf(manager2), 55);
    }
}
