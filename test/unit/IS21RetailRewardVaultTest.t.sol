// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IS21RetailRewardVault} from "src/vaults/IS21RetailRewardVault.sol";

contract MockIS21 is ERC20 {
    constructor() ERC20("Mock IS21", "mIS21") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DummyReceiver {}

contract IS21RetailRewardVaultTest is Test {
    MockIS21 internal token;
    MockIS21 internal otherToken;
    IS21RetailRewardVault internal vault;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal stability = makeAddr("stability");
    address internal rewardManager = makeAddr("rewardManager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant START_BALANCE = 1_000_000 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000 ether;
    uint256 internal constant REWARD_AMOUNT = 100 ether;
    uint64 internal constant EPOCH = 1 hours;

    receive() external payable {}

    function setUp() external {
        token = new MockIS21();
        otherToken = new MockIS21();

        vault = new IS21RetailRewardVault(
            address(token),
            owner,
            treasury,
            stability
        );

        token.mint(alice, START_BALANCE);
        token.mint(bob, START_BALANCE);
        token.mint(carol, START_BALANCE);
        token.mint(rewardManager, START_BALANCE);

        vm.prank(owner);
        vault.approveRewardManager(rewardManager);

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);

        vm.prank(carol);
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

    function _activateAliceAndStartRewards(
        uint256 depositAmount,
        uint256 rewardAmount,
        uint64 epochCount
    ) internal {
        _aliceDeposit(depositAmount);
        _warpEpochs(1);
        _addRewards(rewardAmount, epochCount);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR / VIEWS
    //////////////////////////////////////////////////////////////*/

    function testConstructorRevertsIfOwnerIsZero() external {
        vm.expectRevert();
        new IS21RetailRewardVault(address(token), address(0), treasury, stability);
    }

    function testConstructorRevertsIfAssetIsZero() external {
        vm.expectRevert();
        new IS21RetailRewardVault(address(0), owner, treasury, stability);
    }

    function testConstructorRevertsIfTreasuryIsZero() external {
        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__ZeroAddressNotAllowed.selector
        );
        new IS21RetailRewardVault(address(token), owner, address(0), stability);
    }

    function testConstructorRevertsIfStabilityIsZero() external {
        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__ZeroAddressNotAllowed.selector
        );
        new IS21RetailRewardVault(address(token), owner, treasury, address(0));
    }

    function testInitialState() external view {
        assertEq(vault.getVersion(), "1.0.0");
        assertEq(vault.owner(), owner);
        assertEq(vault.asset(), address(token));
        assertEq(vault.getTreasuryAddress(), treasury);
        assertEq(vault.getStabilityReserveAddress(), stability);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.getCurrentEpoch(), 0);
        assertEq(vault.getLastAccruedEpoch(), 0);
        assertEq(vault.getTotalWeightedAssets(), 0);
        assertEq(vault.getPendingTotalWeightedAssets(), 0);
        assertEq(vault.getAccRewardPerWeightedAsset(), 0);
        assertEq(vault.getTotalReservedRewards(), 0);
        assertEq(vault.getUndistributedRewards(), 0);
        assertEq(vault.previewClaimRewards(alice), 0);
        assertEq(vault.previewClaimRewards(address(0)), 0);
        assertEq(vault.previewCurrentMultiplierBps(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function testApproveRewardManagerOnlyOwner() external {
        address newManager = makeAddr("newManager");

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

    function testSetTreasuryAddress() external {
        address newTreasury = makeAddr("newTreasury");

        vm.expectRevert();
        vm.prank(alice);
        vault.setTreasuryAddress(newTreasury);

        vm.prank(owner);
        vault.setTreasuryAddress(newTreasury);

        assertEq(vault.getTreasuryAddress(), newTreasury);
    }

    function testSetStabilityReserveAddress() external {
        address newReserve = makeAddr("newReserve");

        vm.expectRevert();
        vm.prank(alice);
        vault.setStabilityReserveAddress(newReserve);

        vm.prank(owner);
        vault.setStabilityReserveAddress(newReserve);

        assertEq(vault.getStabilityReserveAddress(), newReserve);
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
        vault.deposit(1 ether, alice);

        vm.prank(owner);
        vault.unpause();

        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function testDepositUpdatesPrincipalAndQueuesWeightForNextEpoch() external {
        uint256 tsBefore = block.timestamp;

        _aliceDeposit(DEPOSIT_AMOUNT);

        IS21RetailRewardVault.UserPosition memory user = vault.getUserPosition(alice);

        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT);
        assertEq(user.principalAssets, DEPOSIT_AMOUNT);
        assertEq(user.weightedAssets, 0);
        assertEq(user.pendingRewards, 0);
        assertEq(user.weightedTimestamp, tsBefore);

        assertEq(vault.getTotalWeightedAssets(), 0);
        assertEq(vault.getPendingTotalWeightedAssets(), DEPOSIT_AMOUNT);
        assertEq(vault.getUserPendingWeightedAssets(alice), DEPOSIT_AMOUNT);
    }

    function testSecondDepositAveragesWeightedTimestamp() external {
        _aliceDeposit(400 ether);
        uint64 firstTs = vault.getUserPosition(alice).weightedTimestamp;

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        vault.deposit(600 ether, alice);

        IS21RetailRewardVault.UserPosition memory user = vault.getUserPosition(alice);

        uint256 expectedTs = ((400 ether * uint256(firstTs)) +
            (600 ether * block.timestamp)) / 1000 ether;

        assertEq(user.principalAssets, 1000 ether);
        assertEq(user.weightedTimestamp, expectedTs);
        assertEq(vault.balanceOf(alice), 1000 ether);
        assertEq(vault.totalAssets(), 1000 ether);
    }

    function testMaxWithdrawAndMaxRedeemAreZeroInSameBlockAsDeposit() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function testWithdrawRevertsInSameBlockAsDeposit() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert();
        vm.prank(alice);
        vault.withdraw(100 ether, alice, alice);
    }

    function testWithdrawUpdatesPrincipalAndClearsTimestampIfZero() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);

        IS21RetailRewardVault.UserPosition memory user = vault.getUserPosition(alice);

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(user.principalAssets, 0);
        assertEq(user.weightedTimestamp, 0);
        assertEq(vault.getUserPendingWeightedAssets(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          SHARE TRANSFER RULES
    //////////////////////////////////////////////////////////////*/

    function testRegularShareTransferReverts() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__ShareTransfersDisabled.selector
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
            IS21RetailRewardVault.IS21RetailRewardVault__CannotSendToContract.selector
        );
        vm.prank(alice);
        (bool success, ) = address(vault).call(
            abi.encodeCall(vault.transfer, (address(vault), 1 ether))
        );
        success;
    }

    /*//////////////////////////////////////////////////////////////
                             REWARD ADDING
    //////////////////////////////////////////////////////////////*/

    function testAddRewardsRevertsIfCallerIsNotRewardManager() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        _warpEpochs(1);

        vm.expectRevert(
            IS21RetailRewardVault
                .IS21RetailRewardVault__OnlyRewardManagerCanExecute
                .selector
        );
        vm.prank(alice);
        vault.addRewards(REWARD_AMOUNT, 4);
    }

    function testAddRewardsRevertsIfEpochCountIsZero() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        _warpEpochs(1);

        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__InvalidEpochCount.selector
        );
        vm.prank(rewardManager);
        vault.addRewards(REWARD_AMOUNT, 0);
    }

    function testAddRewardsRevertsIfNoActiveStakersYet() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__NoActiveStakers.selector
        );
        vm.prank(rewardManager);
        vault.addRewards(REWARD_AMOUNT, 4);
    }

    function testAddRewardsSplitsAndConfiguresStream() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        _warpEpochs(1);

        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 stabilityBefore = token.balanceOf(stability);

        _addRewards(REWARD_AMOUNT, 4);

        IS21RetailRewardVault.RewardStream memory stream = vault.getRewardStream();

        uint256 treasuryCut = 10 ether;
        uint256 reserveCut = 2 ether;
        uint256 stakerCut = 88 ether;

        assertEq(token.balanceOf(treasury), treasuryBefore + treasuryCut);
        assertEq(token.balanceOf(stability), stabilityBefore + reserveCut);
        assertEq(vault.getTotalReservedRewards(), stakerCut);

        assertEq(stream.startEpoch, 1);
        assertEq(stream.endEpoch, 5);
        assertEq(stream.rewardPerEpoch, 22 ether);
        assertEq(stream.firstEpochBonus, 0);
        assertEq(vault.getRemainingScheduledRewards(), 88 ether);
    }

    function testAddRewardsRollsLeftoverIntoNewStream() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, 100 ether, 4);

        _warpEpochs(1);
        _addRewards(100 ether, 2);

        IS21RetailRewardVault.RewardStream memory stream = vault.getRewardStream();

        assertEq(stream.startEpoch, 2);
        assertEq(stream.endEpoch, 4);
        assertEq(stream.rewardPerEpoch, 77 ether);
        assertEq(stream.firstEpochBonus, 0);

        assertEq(vault.getTotalReservedRewards(), 176 ether);
        assertEq(vault.getUndistributedRewards(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          PREVIEW / CLAIM REWARDS
    //////////////////////////////////////////////////////////////*/

    function testPreviewClaimRewardsAfterOneEpoch() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);

        _warpEpochs(1);

        assertEq(vault.previewClaimRewards(alice), 22 ether);
    }

    function testPreviewClaimRewardsAcrossMultipleElapsedEpochs() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);

        _warpEpochs(3);

        assertEq(vault.previewClaimRewards(alice), 66 ether);
    }

    function testClaimRewardsTransfersTokensAndReducesReservedRewards()
        external
    {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);
        _warpEpochs(2);
        vm.roll(block.number + 1);

        uint256 aliceBalBefore = token.balanceOf(alice);

        vm.prank(alice);
        uint256 claimed = vault.claimRewards();

        IS21RetailRewardVault.UserPosition memory user = vault.getUserPosition(alice);

        assertEq(claimed, 44 ether);
        assertEq(token.balanceOf(alice), aliceBalBefore + 44 ether);
        assertEq(user.pendingRewards, 0);
        assertEq(vault.getTotalReservedRewards(), 44 ether);
        assertEq(vault.getUndistributedRewards(), 0);
        assertEq(vault.previewClaimRewards(alice), 0);
    }

    function testClaimRewardsToTransfersToReceiver() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);
        _warpEpochs(1);
        vm.roll(block.number + 1);

        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        uint256 claimed = vault.claimRewardsTo(bob);

        assertEq(claimed, 22 ether);
        assertEq(token.balanceOf(bob), bobBefore + 22 ether);
    }

    function testClaimRewardsRevertsIfNothingClaimable() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        vm.roll(block.number + 1);

        vm.expectRevert(
            IS21RetailRewardVault
                .IS21RetailRewardVault__InsufficientClaimableRewards
                .selector
        );
        vm.prank(alice);
        vault.claimRewards();
    }

    function testClaimRewardsRevertsSameBlockAsDeposit() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__SameBlockClaimNotAllowed.selector
        );
        vm.prank(alice);
        vault.claimRewards();
    }

    function testClaimRewardsToVaultReverts() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);
        _warpEpochs(1);
        vm.roll(block.number + 1);

        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__CannotSendToContract.selector
        );
        vm.prank(alice);
        vault.claimRewardsTo(address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                             COMPOUND TESTS
    //////////////////////////////////////////////////////////////*/

    function testCompoundAllRewardsIncreasesPrincipalAndShares() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);
        _warpEpochs(1);
        vm.roll(block.number + 1);

        uint64 tsBefore = vault.getUserPosition(alice).weightedTimestamp;

        vm.prank(alice);
        (uint256 compounded, uint256 mintedShares) = vault.compoundRewards();

        IS21RetailRewardVault.UserPosition memory user = vault.getUserPosition(alice);

        assertEq(compounded, 22 ether);
        assertEq(mintedShares, 22 ether);
        assertEq(user.principalAssets, 1022 ether);
        assertEq(vault.totalAssets(), 1022 ether);
        assertEq(vault.balanceOf(alice), 1022 ether);
        assertEq(user.pendingRewards, 0);
        assertEq(user.weightedTimestamp, tsBefore);
    }

    function testCompoundSpecificAmount() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);
        _warpEpochs(2);
        vm.roll(block.number + 1);

        vm.prank(alice);
        (uint256 compounded, uint256 mintedShares) = vault.compoundRewards(
            10 ether
        );

        IS21RetailRewardVault.UserPosition memory user = vault.getUserPosition(alice);

        assertEq(compounded, 10 ether);
        assertEq(mintedShares, 10 ether);
        assertEq(user.principalAssets, 1010 ether);
        assertEq(user.pendingRewards, 34 ether);
        assertEq(vault.balanceOf(alice), 1010 ether);
        assertEq(vault.totalAssets(), 1010 ether);
    }

    function testCompoundRevertsIfRequestedAmountExceedsClaimable() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);
        _warpEpochs(1);
        vm.roll(block.number + 1);

        vm.expectRevert(
            IS21RetailRewardVault
                .IS21RetailRewardVault__AmountExceedsClaimableRewards
                .selector
        );
        vm.prank(alice);
        vault.compoundRewards(23 ether);
    }

    function testCompoundRevertsIfNothingClaimable() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        vm.roll(block.number + 1);

        vm.expectRevert(
            IS21RetailRewardVault
                .IS21RetailRewardVault__InsufficientClaimableRewards
                .selector
        );
        vm.prank(alice);
        vault.compoundRewards();
    }

    function testCompoundRevertsSameBlockAsDeposit() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21RetailRewardVault
                .IS21RetailRewardVault__SameBlockCompoundNotAllowed
                .selector
        );
        vm.prank(alice);
        vault.compoundRewards();
    }

    /*//////////////////////////////////////////////////////////////
                         MULTIPLIER / REFRESH TESTS
    //////////////////////////////////////////////////////////////*/

    function testPreviewCurrentMultiplierStartsAt1x() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        assertEq(vault.previewCurrentMultiplierBps(alice), 10_000);
    }

    function testPreviewCurrentMultiplierBecomes15xAfter30Days() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 30 days);

        assertEq(vault.previewCurrentMultiplierBps(alice), 15_000);
    }

    function testPreviewCurrentMultiplierBecomes2xAfter90Days() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 90 days);

        assertEq(vault.previewCurrentMultiplierBps(alice), 20_000);
    }

    function testPreviewCurrentMultiplierBecomes2xAtThreshold() external {
        vm.prank(alice);
        vault.deposit(100_000 ether, alice);

        assertEq(vault.previewCurrentMultiplierBps(alice), 20_000);
    }

    function testRefreshPositionMovesQueuedWeightIntoActiveAfterEpoch()
        external
    {
        _aliceDeposit(DEPOSIT_AMOUNT);

        assertEq(vault.getTotalWeightedAssets(), 0);
        assertEq(vault.getPendingTotalWeightedAssets(), DEPOSIT_AMOUNT);

        _warpEpochs(1);

        vm.prank(alice);
        vault.refreshPosition();

        IS21RetailRewardVault.UserPosition memory user = vault.getUserPosition(alice);

        assertEq(user.weightedAssets, DEPOSIT_AMOUNT);
        assertEq(vault.getTotalWeightedAssets(), DEPOSIT_AMOUNT);
        assertEq(vault.getPendingTotalWeightedAssets(), DEPOSIT_AMOUNT);
        assertEq(vault.getUserLastSettledEpoch(alice), 1);
    }

    /*//////////////////////////////////////////////////////////////
                       UNDISTRIBUTED REWARD TESTS
    //////////////////////////////////////////////////////////////*/

    function testRewardsBecomeUndistributedWhenNoWeightExistsDuringEmission()
        external
    {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);

        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);

        _warpEpochs(2);

        vm.prank(alice);
        vault.refreshPosition();

        assertGt(vault.getUndistributedRewards(), 0);
    }

    function testWithdrawUndistributedRewardsByManager() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);

        vm.roll(block.number + 1);
        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);

        _warpEpochs(2);

        vm.prank(alice);
        vault.refreshPosition();

        uint256 undistributed = vault.getUndistributedRewards();
        assertGt(undistributed, 0);

        uint256 before = token.balanceOf(bob);

        vm.prank(rewardManager);
        vault.withdrawUndistributedRewards(undistributed, bob);

        assertEq(vault.getUndistributedRewards(), 0);
        assertEq(token.balanceOf(bob), before + undistributed);
    }

    function testWithdrawUndistributedRewardsRevertsIfTooMuch() external {
        vm.expectRevert(
            IS21RetailRewardVault
                .IS21RetailRewardVault__InsufficientUndistributedRewards
                .selector
        );
        vm.prank(rewardManager);
        vault.withdrawUndistributedRewards(1 ether, bob);
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

    function testRescueAssetTokenOnlyFreeBalance() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        token.mint(address(vault), 25 ether);

        uint256 before = token.balanceOf(bob);

        vm.prank(owner);
        vault.rescueErc20(address(token), 25 ether, bob);

        assertEq(token.balanceOf(bob), before + 25 ether);
    }

    function testRescueAssetTokenRevertsIfTouchingReservedOrPrincipal()
        external
    {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21RetailRewardVault
                .IS21RetailRewardVault__InsufficientFreeBalanceForRescue
                .selector
        );
        vm.prank(owner);
        vault.rescueErc20(address(token), 1 ether, bob);
    }

    /*//////////////////////////////////////////////////////////////
                      FULL POSITION TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function testTransferFullPositionRevertsToSelf() external {
        _aliceDeposit(DEPOSIT_AMOUNT);

        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__CannotTransferToSelf.selector
        );
        vm.prank(alice);
        vault.transferFullPosition(alice);
    }

    function testTransferFullPositionRevertsIfReceiverNotEmpty() external {
        _aliceDeposit(DEPOSIT_AMOUNT);
        _bobDeposit(1 ether);

        vm.roll(block.number + 1);

        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__ReceiverMustBeEmpty.selector
        );
        vm.prank(alice);
        vault.transferFullPosition(bob);
    }

    function testTransferFullPositionMovesEntireEconomicPosition() external {
        _activateAliceAndStartRewards(DEPOSIT_AMOUNT, REWARD_AMOUNT, 4);
        _warpEpochs(1);

        vm.prank(alice);
        vault.refreshPosition();

        IS21RetailRewardVault.UserPosition memory beforeAlice = vault.getUserPosition(
            alice
        );
        uint256 shares = vault.balanceOf(alice);
        uint256 pendingQueuedWeight = vault.getUserPendingWeightedAssets(alice);

        vm.prank(alice);
        vault.transferFullPosition(bob);

        IS21RetailRewardVault.UserPosition memory afterAlice = vault.getUserPosition(
            alice
        );
        IS21RetailRewardVault.UserPosition memory afterBob = vault.getUserPosition(
            bob
        );

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), shares);

        assertEq(afterAlice.principalAssets, 0);
        assertEq(afterAlice.weightedAssets, 0);
        assertEq(afterAlice.pendingRewards, 0);

        assertEq(afterBob.principalAssets, beforeAlice.principalAssets);
        assertEq(afterBob.weightedAssets, beforeAlice.weightedAssets);
        assertEq(afterBob.pendingRewards, beforeAlice.pendingRewards);
        assertEq(afterBob.weightedTimestamp, beforeAlice.weightedTimestamp);
        assertEq(vault.getUserPendingWeightedAssets(bob), pendingQueuedWeight);
    }

    /*//////////////////////////////////////////////////////////////
                           FALLBACK / RECEIVE
    //////////////////////////////////////////////////////////////*/

    function testReceiveReverts() external {
        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__ETHNotAccepted.selector
        );
        payable(address(vault)).transfer(1 ether);
    }

    function testFallbackReverts() external {
        vm.expectRevert(
            IS21RetailRewardVault.IS21RetailRewardVault__ETHNotAccepted.selector
        );
        (bool ok, ) = address(vault).call{value: 1 ether}(
            abi.encodeWithSignature("doesNotExist()")
        );
        ok;
    }
}
