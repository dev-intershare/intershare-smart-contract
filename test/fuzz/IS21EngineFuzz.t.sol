// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IS21Engine, FiatReserves} from "../../src/IS21Engine.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// Simple ERC20 with public mint for rescue tests
contract MockERC20 is ERC20 {
    constructor() ERC20("MockToken", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract IS21EngineFuzz is Test {
    IS21Engine internal engine;

    address internal owner = address(0xA11CE);
    address internal manager = address(0xBEEF1);
    address internal auditor = address(0xABDF2);

    function setUp() public {
        engine = new IS21Engine(owner);

        // set roles
        vm.prank(owner);
        engine.approveFundManager(manager);

        vm.prank(owner);
        engine.approveAuditor(auditor);
    }

    // --------------------------
    // Mint / Burn fuzzing
    // --------------------------

    function testFuzz_MintTo_Succeeds_WhenFundManager(
        address to,
        uint256 amount
    ) public {
        vm.assume(to != address(0));
        amount = bound(amount, 1, type(uint128).max); // keep gas sane

        vm.prank(manager);
        engine.mintIs21To(to, amount);

        assertEq(engine.balanceOf(to), amount);
        assertEq(engine.totalSupply(), amount);
    }

    function testFuzz_Burn_Succeeds(uint256 mintAmt, uint256 burnAmt) public {
        mintAmt = bound(mintAmt, 1, type(uint128).max);
        burnAmt = bound(burnAmt, 1, mintAmt); // <-- avoid 0

        vm.prank(manager);
        engine.mintIs21(mintAmt);

        vm.prank(manager);
        engine.burnIs21(burnAmt);

        assertEq(engine.balanceOf(manager), mintAmt - burnAmt);
        assertEq(engine.totalSupply(), mintAmt - burnAmt);
    }

    function testFuzz_Mint_Reverts_WhenPaused(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.prank(owner);
        engine.pause();

        vm.prank(manager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        engine.mintIs21(amount);
    }

    function testFuzz_Burn_Reverts_WhenPaused(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        // mint first so we have balance
        vm.prank(manager);
        engine.mintIs21(amount);

        // pause
        vm.prank(owner);
        engine.pause();

        vm.prank(manager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        engine.burnIs21(amount);
    }

    // --------------------------
    // Role restrictions
    // --------------------------

    function testFuzz_OnlyFundManager_CannotMint(
        address notManager,
        uint256 amount
    ) public {
        vm.assume(notManager != address(0));
        vm.assume(notManager != manager);
        vm.assume(notManager != owner);

        amount = bound(amount, 1, type(uint128).max);

        vm.prank(notManager);
        vm.expectRevert(
            IS21Engine.IS21Engine__OnlyFundManagerCanExecute.selector
        );
        engine.mintIs21(amount);
    }

    // --------------------------
    // Reserves fuzzing
    // --------------------------

    function testFuzz_UpdateSingleReserve_Read(
        bytes32 currency,
        uint256 amt
    ) public {
        // allow any currency id, any amt
        vm.prank(manager);
        engine.updateFiatReserve(currency, amt);

        assertEq(engine.getFiatReserve(currency), amt);
    }

    function testFuzz_UpdateMultipleReserves_AndReadArray(
        uint8 lenRaw,
        uint256 seed
    ) public {
        // shrink to a small upper bound so test is fast
        uint256 len = bound(uint256(lenRaw), 1, 10);

        // build struct array with unique currencies derived from seed + index
        FiatReserves[] memory arr = new FiatReserves[](len);
        bytes32[] memory queries = new bytes32[](len);

        for (uint256 i = 0; i < len; i++) {
            // derive unique currency keys from seed and index
            bytes32 cur = keccak256(abi.encode(seed, i));
            // small-ish amounts to keep gas low
            uint256 amount = uint256(keccak256(abi.encode(seed, i, "amt"))) %
                1e18;

            arr[i] = FiatReserves({currency: cur, amount: amount});
            queries[i] = cur;
        }

        vm.prank(manager);
        engine.updateFiatReserves(arr);

        uint256[] memory out = engine.getFiatReserves(queries);
        assertEq(out.length, len);
        for (uint256 i = 0; i < len; i++) {
            assertEq(out[i], arr[i].amount);
        }
    }

    // --------------------------
    // rescueERC20 fuzzing
    // --------------------------

    function testFuzz_RescueERC20_ByOwner(address to, uint256 amt) public {
        vm.assume(to != address(0));
        vm.assume(to != address(engine)); // prevent self-transfer

        amt = bound(amt, 1, 1e24);

        MockERC20 mock = new MockERC20();
        mock.mint(address(engine), amt);

        // Rescue tokens
        vm.prank(owner);
        engine.rescueErc20(address(mock), amt, to);

        // Assert balances
        assertEq(mock.balanceOf(address(engine)), 0);
        assertEq(mock.balanceOf(to), amt);
    }

    // --------------------------
    // Misc sanity invariants
    // --------------------------

    /// Total supply equals sum of all balances we touched (simple spot check for two accounts)
    function testFuzz_TotalSupplyTracksSimple(
        address a,
        address b,
        uint256 x,
        uint256 y
    ) public {
        vm.assume(a != address(0) && b != address(0));
        vm.assume(a != b);

        x = bound(x, 0, 1e24);
        y = bound(y, 0, 1e24);

        vm.startPrank(manager);
        if (x > 0) engine.mintIs21To(a, x);
        if (y > 0) engine.mintIs21To(b, y);
        vm.stopPrank();

        uint256 ts = engine.totalSupply();
        uint256 sum = engine.balanceOf(a) + engine.balanceOf(b);
        // we only check the accounts we minted to; others are zero in this test
        assertEq(ts, sum);
    }
}
