// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IS21InstitutionalRewardVault} from "src/vaults/IS21InstitutionalRewardVault.sol";

contract MockInstitutionalIS21 is ERC20 {
    constructor() ERC20("Mock IS21", "mIS21") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DummyInstitutionalReceiver {}

contract IS21InstitutionalRewardVaultTest is Test {
    MockInstitutionalIS21 internal token;
    MockInstitutionalIS21 internal otherToken;
    IS21InstitutionalRewardVault internal vault;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal stability = makeAddr("stability");
    address internal fundManager = makeAddr("fundManager");
    address internal rewardManager = makeAddr("rewardManager");
    address internal alice = makeAddr("aliceInstitution");
    address internal bob = makeAddr("bobInstitution");
    address internal carol = makeAddr("carolInstitution");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant START_BALANCE = 10_000_000 ether;
    uint256 internal constant MINIMUM_POSITION = 150_000 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 200_000 ether;
    uint256 internal constant SMALL_DEPOSIT = 20_000 ether;
    uint256 internal constant REWARD_AMOUNT = 100 ether;
    uint64 internal constant EPOCH = 1 hours;

    receive() external payable {}

    function setUp() external {
        token = new MockInstitutionalIS21();
        otherToken = new MockInstitutionalIS21();

        vault = new IS21InstitutionalRewardVault(
            address(token),
            owner,
            treasury,
            stability
        );

        token.mint(alice, START_BALANCE);
        token.mint(bob, START_BALANCE);
        token.mint(carol, START_BALANCE);
        token.mint(stranger, START_BALANCE);
        token.mint(rewardManager, START_BALANCE);

        vm.startPrank(owner);
        vault.approveFundManager(fundManager);
        vault.approveRewardManager(rewardManager);
        vm.stopPrank();

        vm.startPrank(fundManager);
        vault.whitelistInstitution(alice);
        vault.whitelistInstitution(bob);
        vm.stopPrank();

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);

        vm.prank(carol);
        token.approve(address(vault), type(uint256).max);

        vm.prank(stranger);
        token.approve(address(vault), type(uint256).max);

        vm.prank(rewardManager);
        token.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _warpEpochs(uint256 epochs) internal {
        vm.warp(block.timestamp + (epochs * EPOCH));
    }

    function _aliceDeposit(uint256 amount) internal {
        vm.prank(alice);
        vault.deposit(amount, alice);
    }

    function _bobDeposit(uint256 amount) internal {
        vm.prank(bob);
        vault.deposit(amount, bob);
    }

    function _addRewards(uint256 amount, uint64 epochCount) internal {
        vm.prank(rewardManager);
        vault.addRewards(amount, epochCount);
    }

    function _aliceDepositAndStartRewards(
        uint256 depositAmount,
        uint256 rewardAmount,
        uint64 epochCount
    ) internal {
        _aliceDeposit(depositAmount);
        _addRewards(rewardAmount, epochCount);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR / VIEWS
    //////////////////////////////////////////////////////////////*/

    function testConstructorRevertsIfAssetIsZero() external {
        vm.expectRevert();
        new IS21InstitutionalRewardVault(
            address(0),
            owner,
            treasury,
            stability
        );
    }

    function testConstructorRevertsIfOwnerIsZero() external {
        vm.expectRevert();
        new IS21InstitutionalRewardVault(
            address(token),
            address(0),
            treasury,
            stability
        );
    }

    function testConstructorRevertsIfTreasuryIsZero() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__ZeroAddressNotAllowed
                .selector
        );

        new IS21InstitutionalRewardVault(
            address(token),
            owner,
            address(0),
            stability
        );
    }

    function testConstructorRevertsIfStabilityIsZero() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__ZeroAddressNotAllowed
                .selector
        );

        new IS21InstitutionalRewardVault(
            address(token),
            owner,
            treasury,
            address(0)
        );
    }

    function testInitialState() external view {
        assertEq(vault.name(), "Institutional Staked InterShare21");
        assertEq(vault.symbol(), "isIS21");
        assertEq(vault.getVersion(), "1.0.0");
        assertEq(vault.owner(), owner);
        assertEq(vault.asset(), address(token));
        assertEq(vault.getTreasuryAddress(), treasury);
        assertEq(vault.getStabilityReserveAddress(), stability);
        assertEq(vault.getMinimumPositionAssets(), MINIMUM_POSITION);
        assertEq(vault.getWithdrawalPenaltyPeriod(), 30 days);
        assertEq(vault.getWithdrawalPenaltyBps(), 0);
        assertEq(vault.getEpochDuration(), EPOCH);
        assertEq(vault.getCurrentEpoch(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.getRemainingScheduledRewards(), 0);
        assertEq(vault.getCurrentPositionAssets(alice), 0);
        assertEq(vault.getUnrealizedProfitLoss(alice), 0);
        assertTrue(vault.isInstitutionWhitelisted(alice));
        assertTrue(vault.isInstitutionWhitelisted(bob));
        assertFalse(vault.isInstitutionWhitelisted(carol));
    }

    function testGetInstitutionPosition() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        IS21InstitutionalRewardVault.InstitutionPosition memory position = vault
            .getInstitutionPosition(alice);

        assertEq(position.principalDeposited, DEPOSIT_AMOUNT);
        assertEq(position.currentAssets, DEPOSIT_AMOUNT);
        assertEq(position.unrealizedProfitLoss, 0);
        assertEq(position.shareBalance, DEPOSIT_AMOUNT);
        assertEq(position.weightedDepositTimestamp, block.timestamp);
        assertEq(position.lastDepositBlock, block.number);
        assertTrue(position.whitelisted);
        assertTrue(position.withinPenaltyPeriod);
    }

    /*//////////////////////////////////////////////////////////////
                            FUND MANAGER TESTS
    //////////////////////////////////////////////////////////////*/

    function testApproveFundManagerOnlyOwner() external {
        address newManager = makeAddr("newManager");

        vm.expectRevert();
        vm.prank(alice);
        vault.approveFundManager(newManager);

        vm.prank(owner);
        vault.approveFundManager(newManager);

        assertTrue(vault.isFundManager(newManager));
    }

    function testRevokeFundManagerOnlyOwner() external {
        vm.expectRevert();
        vm.prank(alice);
        vault.revokeFundManager(fundManager);

        vm.prank(owner);
        vault.revokeFundManager(fundManager);

        assertFalse(vault.isFundManager(fundManager));
    }

    function testWhitelistInstitutionOnlyFundManager() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__OnlyFundManagerCanExecute
                .selector
        );
        vm.prank(alice);
        vault.whitelistInstitution(carol);

        vm.prank(fundManager);
        vault.whitelistInstitution(carol);

        assertTrue(vault.isInstitutionWhitelisted(carol));
    }

    function testWhitelistInstitutionsBatch() external {
        address dave = makeAddr("daveInstitution");
        address erin = makeAddr("erinInstitution");

        address[] memory institutions = new address[](2);
        institutions[0] = dave;
        institutions[1] = erin;

        vm.prank(fundManager);
        vault.whitelistInstitutions(institutions);

        assertTrue(vault.isInstitutionWhitelisted(dave));
        assertTrue(vault.isInstitutionWhitelisted(erin));
    }

    function testRemoveInstitutionOnlyFundManager() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__OnlyFundManagerCanExecute
                .selector
        );
        vm.prank(alice);
        vault.removeInstitution(alice);

        vm.prank(fundManager);
        vault.removeInstitution(alice);

        assertFalse(vault.isInstitutionWhitelisted(alice));
    }

    function testRemovedInstitutionCannotDepositButCanWithdrawExistingPosition()
        external
    {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.prank(fundManager);
        vault.removeInstitution(alice);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__InstitutionNotWhitelisted
                .selector
        );
        vm.prank(alice);
        vault.deposit(SMALL_DEPOSIT, alice);

        vm.roll(block.number + 1);

        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.getCurrentPositionAssets(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            REWARD MANAGER TESTS
    //////////////////////////////////////////////////////////////*/

    function testApproveRewardManagerOnlyOwner() external {
        address newManager = makeAddr("newRewardManager");

        vm.expectRevert();
        vm.prank(alice);
        vault.approveRewardManager(newManager);

        vm.prank(owner);
        vault.approveRewardManager(newManager);

        assertTrue(vault.isRewardManager(newManager));
    }

    function testRevokeRewardManagerOnlyOwner() external {
        vm.expectRevert();
        vm.prank(alice);
        vault.revokeRewardManager(rewardManager);

        vm.prank(owner);
        vault.revokeRewardManager(rewardManager);

        assertFalse(vault.isRewardManager(rewardManager));
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIG TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetTreasuryAddressOnlyOwner() external {
        address newTreasury = makeAddr("newTreasury");

        vm.expectRevert();
        vm.prank(alice);
        vault.setTreasuryAddress(newTreasury);

        vm.prank(owner);
        vault.setTreasuryAddress(newTreasury);

        assertEq(vault.getTreasuryAddress(), newTreasury);
    }

    function testSetStabilityReserveAddressOnlyOwner() external {
        address newReserve = makeAddr("newReserve");

        vm.expectRevert();
        vm.prank(alice);
        vault.setStabilityReserveAddress(newReserve);

        vm.prank(owner);
        vault.setStabilityReserveAddress(newReserve);

        assertEq(vault.getStabilityReserveAddress(), newReserve);
    }

    function testSetMinimumPositionAssetsOnlyFundManager() external {
        uint256 newMinimum = 250_000 ether;

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__OnlyFundManagerCanExecute
                .selector
        );
        vm.prank(alice);
        vault.setMinimumPositionAssets(newMinimum);

        vm.prank(fundManager);
        vault.setMinimumPositionAssets(newMinimum);

        assertEq(vault.getMinimumPositionAssets(), newMinimum);
    }

    function testSetMinimumPositionAssetsRevertsIfZero() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__AmountMustBeMoreThanZero
                .selector
        );

        vm.prank(fundManager);
        vault.setMinimumPositionAssets(0);
    }

    function testSetWithdrawalPenaltyPeriodOnlyFundManager() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__OnlyFundManagerCanExecute
                .selector
        );
        vm.prank(alice);
        vault.setWithdrawalPenaltyPeriod(60 days);

        vm.prank(fundManager);
        vault.setWithdrawalPenaltyPeriod(60 days);

        assertEq(vault.getWithdrawalPenaltyPeriod(), 60 days);
    }

    function testSetWithdrawalPenaltyBpsOnlyFundManager() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__OnlyFundManagerCanExecute
                .selector
        );
        vm.prank(alice);
        vault.setWithdrawalPenaltyBps(500);

        vm.prank(fundManager);
        vault.setWithdrawalPenaltyBps(500);

        assertEq(vault.getWithdrawalPenaltyBps(), 500);
    }

    function testSetWithdrawalPenaltyBpsRevertsIfAboveBps() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__InvalidBps
                .selector
        );

        vm.prank(fundManager);
        vault.setWithdrawalPenaltyBps(10_001);
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function testPauseAndUnpause() external {
        vm.prank(owner);
        vault.pause();

        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);

        vm.expectRevert();
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(owner);
        vault.unpause();

        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT / MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function testDepositRevertsIfInstitutionNotWhitelisted() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__InstitutionNotWhitelisted
                .selector
        );

        vm.prank(carol);
        vault.deposit(DEPOSIT_AMOUNT, carol);
    }

    function testInitialDepositRevertsIfBelowMinimum() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__MinimumDepositNotMet
                .selector
        );

        vm.prank(alice);
        vault.deposit(MINIMUM_POSITION - 1, alice);
    }

    function testDepositUpdatesPrincipalSharesAndTimestamp() external {
        uint256 tsBefore = block.timestamp;

        _aliceDeposit(DEPOSIT_AMOUNT);

        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
        assertEq(vault.totalSupply(), DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT);
        assertEq(vault.getCurrentPositionAssets(alice), DEPOSIT_AMOUNT);
        assertEq(vault.getPrincipalDeposited(alice), DEPOSIT_AMOUNT);
        assertEq(vault.getUnrealizedProfitLoss(alice), 0);
        assertEq(vault.getWeightedDepositTimestamp(alice), tsBefore);
        assertEq(vault.getLastDepositBlock(alice), block.number);
    }

    function testSecondSmallDepositAllowedAfterMinimumPositionExists()
        external
    {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.warp(block.timestamp + 10 days);

        uint64 firstTs = vault.getWeightedDepositTimestamp(alice);

        vm.prank(alice);
        vault.deposit(SMALL_DEPOSIT, alice);

        uint256 expectedPrincipal = DEPOSIT_AMOUNT + SMALL_DEPOSIT;
        uint256 expectedTs = ((DEPOSIT_AMOUNT * uint256(firstTs)) +
            (SMALL_DEPOSIT * block.timestamp)) / expectedPrincipal;

        assertEq(vault.getPrincipalDeposited(alice), expectedPrincipal);
        assertEq(vault.getCurrentPositionAssets(alice), expectedPrincipal);
        assertEq(vault.getWeightedDepositTimestamp(alice), expectedTs);
    }

    function testMintRevertsIfInstitutionNotWhitelisted() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__InstitutionNotWhitelisted
                .selector
        );

        vm.prank(carol);
        vault.mint(DEPOSIT_AMOUNT, carol);
    }

    function testMintWorksForWhitelistedInstitution() external {
        vm.prank(alice);
        uint256 assets = vault.mint(DEPOSIT_AMOUNT, alice);

        assertEq(assets, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT);
        assertEq(vault.getPrincipalDeposited(alice), DEPOSIT_AMOUNT);
    }

    function testMaxDepositAndMaxMintAreZeroForUnwhitelistedInstitution()
        external
        view
    {
        assertEq(vault.maxDeposit(carol), 0);
        assertEq(vault.maxMint(carol), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            SAME BLOCK PROTECTION
    //////////////////////////////////////////////////////////////*/

    function testMaxWithdrawAndMaxRedeemAreZeroInSameBlockAsDeposit() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function testWithdrawRevertsInSameBlockAsDeposit() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__SameBlockWithdrawNotAllowed
                .selector
        );

        vm.prank(alice);
        vault.withdraw(1 ether, alice, alice);
    }

    function testRedeemRevertsInSameBlockAsDeposit() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__SameBlockWithdrawNotAllowed
                .selector
        );

        vm.prank(alice);
        vault.redeem(1 ether, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW / REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function testPartialWithdrawUpdatesPrincipalProportionally() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        vm.roll(block.number + 1);

        uint256 withdrawAmount = 50_000 ether;

        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(vault.getPrincipalDeposited(alice), 150_000 ether);
        assertEq(vault.getCurrentPositionAssets(alice), 150_000 ether);
        assertEq(vault.balanceOf(alice), 150_000 ether);
    }

    function testPartialWithdrawRevertsIfRemainingBelowMinimum() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        vm.roll(block.number + 1);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__RemainingBalanceBelowMinimum
                .selector
        );

        vm.prank(alice);
        vault.withdraw(60_000 ether, alice, alice);
    }

    function testFullWithdrawAllowedEvenIfRemainingWouldBeBelowMinimum()
        external
    {
        _aliceDeposit(DEPOSIT_AMOUNT);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.getPrincipalDeposited(alice), 0);
        assertEq(vault.getCurrentPositionAssets(alice), 0);
        assertEq(vault.getWeightedDepositTimestamp(alice), 0);
        assertEq(vault.getLastDepositBlock(alice), 0);
    }

    function testRedeemFullPositionClearsAccounting() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        vm.roll(block.number + 1);

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.getPrincipalDeposited(alice), 0);
        assertEq(vault.getCurrentPositionAssets(alice), 0);
        assertEq(vault.getWeightedDepositTimestamp(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            PENALTY TESTS
    //////////////////////////////////////////////////////////////*/

    function testPenaltyPreviewIsZeroWhenPenaltyBpsIsZero() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        assertTrue(vault.isWithinPenaltyPeriod(alice));
        assertEq(vault.previewWithdrawalPenalty(alice, 10_000 ether), 0);
    }

    function testPenaltyAppliesInsidePenaltyPeriod() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.prank(fundManager);
        vault.setWithdrawalPenaltyBps(1_000); // 10%

        vm.roll(block.number + 1);

        uint256 withdrawAmount = 10_000 ether;
        uint256 expectedPenalty = 1_000 ether;
        uint256 expectedNet = 9_000 ether;

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 stabilityBefore = token.balanceOf(stability);

        assertEq(
            vault.previewWithdrawalPenalty(alice, withdrawAmount),
            expectedPenalty
        );

        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(token.balanceOf(alice), aliceBefore + expectedNet);
        assertEq(token.balanceOf(stability), stabilityBefore + expectedPenalty);
        assertEq(vault.getPrincipalDeposited(alice), 190_000 ether);
    }

    function testPenaltyDoesNotApplyAfterPenaltyPeriod() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.prank(fundManager);
        vault.setWithdrawalPenaltyBps(1_000); // 10%

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        uint256 withdrawAmount = 10_000 ether;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 stabilityBefore = token.balanceOf(stability);

        assertFalse(vault.isWithinPenaltyPeriod(alice));
        assertEq(vault.previewWithdrawalPenalty(alice, withdrawAmount), 0);

        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(token.balanceOf(alice), aliceBefore + withdrawAmount);
        assertEq(token.balanceOf(stability), stabilityBefore);
    }

    function testPreviewNetWithdrawAssets() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.prank(fundManager);
        vault.setWithdrawalPenaltyBps(500); // 5%

        assertEq(
            vault.previewNetWithdrawAssets(alice, 10_000 ether),
            9_500 ether
        );
    }

    /*//////////////////////////////////////////////////////////////
                            REWARD STREAM TESTS
    //////////////////////////////////////////////////////////////*/

    function testAddRewardsRevertsIfCallerIsNotRewardManager() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__OnlyRewardManagerCanExecute
                .selector
        );

        vm.prank(alice);
        vault.addRewards(REWARD_AMOUNT, 4);
    }

    function testAddRewardsRevertsIfEpochCountIsZero() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__InvalidEpochCount
                .selector
        );

        vm.prank(rewardManager);
        vault.addRewards(REWARD_AMOUNT, 0);
    }

    function testAddRewardsRevertsIfNoActiveInstitutionShares() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__NoActiveInstitutionShares
                .selector
        );

        vm.prank(rewardManager);
        vault.addRewards(REWARD_AMOUNT, 4);
    }

    function testAddRewardsSplitsAndConfiguresStream() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 stabilityBefore = token.balanceOf(stability);

        _addRewards(REWARD_AMOUNT, 4);

        IS21InstitutionalRewardVault.RewardStream memory stream = vault
            .getRewardStream();

        uint256 treasuryCut = 10 ether;
        uint256 reserveCut = 2 ether;
        uint256 vaultCut = 88 ether;

        assertEq(token.balanceOf(treasury), treasuryBefore + treasuryCut);
        assertEq(token.balanceOf(stability), stabilityBefore + reserveCut);
        assertEq(token.balanceOf(address(vault)), DEPOSIT_AMOUNT + vaultCut);

        assertEq(stream.startEpoch, 0);
        assertEq(stream.endEpoch, 4);
        assertEq(stream.rewardPerEpoch, 22 ether);
        assertEq(stream.firstEpochBonus, 0);

        assertEq(vault.getRemainingScheduledRewards(), 88 ether);

        // Unvested rewards are excluded from totalAssets.
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
        assertEq(vault.getCurrentPositionAssets(alice), DEPOSIT_AMOUNT);
        assertEq(vault.getUnrealizedProfitLoss(alice), 0);
    }

    function testRewardsVestIntoSharePriceAfterOneEpoch() external {
        _aliceDepositAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);

        _warpEpochs(1);

        assertEq(vault.getRemainingScheduledRewards(), 66 ether);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT + 22 ether);

        assertApproxEqAbs(
            vault.getCurrentPositionAssets(alice),
            DEPOSIT_AMOUNT + 22 ether,
            1
        );

        assertApproxEqAbs(
            uint256(vault.getUnrealizedProfitLoss(alice)),
            22 ether,
            1
        );

        assertEq(vault.getVestedVaultRewards(), 22 ether);
    }

    function testRewardsFullyVestAfterAllEpochs() external {
        _aliceDepositAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);

        _warpEpochs(4);

        assertEq(vault.getRemainingScheduledRewards(), 0);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT + 88 ether);

        assertApproxEqAbs(
            vault.getCurrentPositionAssets(alice),
            DEPOSIT_AMOUNT + 88 ether,
            1
        );

        assertApproxEqAbs(
            uint256(vault.getUnrealizedProfitLoss(alice)),
            88 ether,
            1
        );
    }

    function testAddRewardsRollsLeftoverIntoNewStream() external {
        _aliceDepositAndStartRewards(DEPOSIT_AMOUNT, 100 ether, 4);

        _warpEpochs(1);

        assertEq(vault.getRemainingScheduledRewards(), 66 ether);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT + 22 ether);

        _addRewards(100 ether, 2);

        IS21InstitutionalRewardVault.RewardStream memory stream = vault
            .getRewardStream();

        // Old leftover = 66 ether, new vault reward = 88 ether, total = 154 ether.
        assertEq(stream.startEpoch, 1);
        assertEq(stream.endEpoch, 3);
        assertEq(stream.rewardPerEpoch, 77 ether);
        assertEq(stream.firstEpochBonus, 0);
        assertEq(vault.getRemainingScheduledRewards(), 154 ether);

        // Already vested 22 ether remains in the share price.
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT + 22 ether);
    }

    function testSecondInstitutionDepositsAtCurrentSharePrice() external {
        _aliceDepositAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);

        _warpEpochs(1);

        uint256 totalAssetsBeforeBob = vault.totalAssets();
        uint256 totalSupplyBeforeBob = vault.totalSupply();

        _bobDeposit(DEPOSIT_AMOUNT);

        uint256 expectedBobShares = (DEPOSIT_AMOUNT * totalSupplyBeforeBob) /
            totalAssetsBeforeBob;

        assertEq(vault.balanceOf(bob), expectedBobShares);
        assertEq(vault.getPrincipalDeposited(bob), DEPOSIT_AMOUNT);
        assertLt(vault.balanceOf(bob), DEPOSIT_AMOUNT);

        assertApproxEqAbs(
            vault.getCurrentPositionAssets(alice),
            DEPOSIT_AMOUNT + 22 ether,
            1
        );
    }

    /*//////////////////////////////////////////////////////////////
                            SHARE TRANSFER RULES
    //////////////////////////////////////////////////////////////*/

    function testRegularShareTransferReverts() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__ShareTransfersDisabled
                .selector
        );

        vm.prank(alice);
        (bool success, ) = address(vault).call(
            abi.encodeCall(vault.transfer, (bob, 1 ether))
        );
        success;
    }

    function testTransferToVaultAddressReverts() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__CannotSendToContract
                .selector
        );

        vm.prank(alice);
        (bool success, ) = address(vault).call(
            abi.encodeCall(vault.transfer, (address(vault), 1 ether))
        );
        success;
    }

    /*//////////////////////////////////////////////////////////////
                            FULL POSITION TRANSFER
    //////////////////////////////////////////////////////////////*/

    function testTransferFullPositionRevertsToSelf() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__CannotTransferToSelf
                .selector
        );

        vm.prank(alice);
        vault.transferFullPosition(alice);
    }

    function testTransferFullPositionRevertsIfReceiverNotWhitelisted()
        external
    {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__InstitutionNotWhitelisted
                .selector
        );

        vm.prank(alice);
        vault.transferFullPosition(carol);
    }

    function testTransferFullPositionRevertsIfReceiverNotEmpty() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        _bobDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__ReceiverMustBeEmpty
                .selector
        );

        vm.prank(alice);
        vault.transferFullPosition(bob);
    }

    function testTransferFullPositionMovesPositionAccounting() external {
        _aliceDepositAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);

        _warpEpochs(1);

        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 alicePrincipalBefore = vault.getPrincipalDeposited(alice);
        uint64 aliceWeightedTimestampBefore = vault.getWeightedDepositTimestamp(
            alice
        );

        vm.prank(alice);
        vault.transferFullPosition(bob);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), aliceSharesBefore);

        assertEq(vault.getPrincipalDeposited(alice), 0);
        assertEq(vault.getPrincipalDeposited(bob), alicePrincipalBefore);

        assertEq(vault.getWeightedDepositTimestamp(alice), 0);
        assertEq(
            vault.getWeightedDepositTimestamp(bob),
            aliceWeightedTimestampBefore
        );
    }

    /*//////////////////////////////////////////////////////////////
                            RESCUE TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function testRescueNonAssetToken() external {
        otherToken.mint(address(vault), 50 ether);

        uint256 before = otherToken.balanceOf(bob);

        vm.prank(owner);
        vault.rescueErc20(address(otherToken), 50 ether, bob);

        assertEq(otherToken.balanceOf(bob), before + 50 ether);
        assertEq(otherToken.balanceOf(address(vault)), 0);
    }

    function testRescueAssetTokenRevertsIfTouchingShareholderAssets() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__InsufficientFreeBalanceForRescue
                .selector
        );

        vm.prank(owner);
        vault.rescueErc20(address(token), 1 ether, bob);
    }

    function testRescueAssetTokenRevertsIfTouchingUnvestedRewards() external {
        _aliceDepositAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);

        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__InsufficientFreeBalanceForRescue
                .selector
        );

        vm.prank(owner);
        vault.rescueErc20(address(token), 1 ether, bob);
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    function testReceiveReverts() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__ETHNotAccepted
                .selector
        );

        payable(address(vault)).transfer(1 ether);
    }

    function testFallbackReverts() external {
        vm.expectRevert(
            IS21InstitutionalRewardVault
                .IS21InstitutionalRewardVault__ETHNotAccepted
                .selector
        );

        (bool ok, ) = address(vault).call{value: 1 ether}(
            abi.encodeWithSignature("doesNotExist()")
        );
        ok;
    }
}
