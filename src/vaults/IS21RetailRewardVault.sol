// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title IS21RetailRewardVault (Retail)
 * @author InterShare Team
 *
 * @notice Principal-only ERC4626 staking vault for IS21 with separate epoch-based rewards.
 *
 * @dev Core model:
 * - Asset = IS21.
 * - totalAssets() returns PRINCIPAL ONLY.
 * - Rewards never increase ERC4626 share price.
 * - Reward managers add rewards separately.
 * - Reward split:
 *   - 10% treasury
 *   - 2% stability reserve
 *   - 88% staker rewards
 * - Staker rewards are streamed across epochs.
 * - Only ONE active reward stream exists at a time.
 * - When new rewards are added, any leftover scheduled rewards are rolled into the new stream.
 * - Users may either:
 *   - claim rewards manually
 *   - compound rewards manually
 * - Compounding DOES NOT reset loyalty age.
 * - Fresh deposits DO update weighted average timestamp.
 * - Loyalty multiplier is applied at epoch boundaries only:
 *   - 1x for age < 30 days
 *   - 1.5x for age >= 30 days and < 90 days
 *   - 2x for age >= 90 days
 *   - OR immediate 2x if principal + unclaimed rewards >= 100,000 IS21
 * - Vault shares are non-transferable except for controlled full-position transfer.
 *
 * @dev Important accounting choices:
 * - ERC4626 shares back principal only.
 * - Rewards are tracked separately via epoch-snapshotted weight accounting.
 * - Weight changes from deposits / withdrawals / compounds / multiplier refreshes
 *   apply to the NEXT epoch only.
 * - Reward tokens remain inside the vault contract until claimed or compounded.
 */
contract IS21RetailRewardVault is
    ERC4626,
    ERC20Permit,
    ERC20Pausable,
    ReentrancyGuard,
    Ownable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    ///////////////
    // Errors    //
    ///////////////
    error IS21RetailRewardVault__AmountMustBeMoreThanZero();
    error IS21RetailRewardVault__ZeroAddressNotAllowed();
    error IS21RetailRewardVault__ETHNotAccepted();
    error IS21RetailRewardVault__CannotSendToContract();
    error IS21RetailRewardVault__OnlyRewardManagerCanExecute();
    error IS21RetailRewardVault__InvalidEpochCount();
    error IS21RetailRewardVault__InsufficientClaimableRewards();
    error IS21RetailRewardVault__SameBlockWithdrawNotAllowed();
    error IS21RetailRewardVault__SameBlockClaimNotAllowed();
    error IS21RetailRewardVault__SameBlockCompoundNotAllowed();
    error IS21RetailRewardVault__ShareTransfersDisabled();
    error IS21RetailRewardVault__InsufficientFreeBalanceForRescue();
    error IS21RetailRewardVault__RewardAddressesNotConfigured();
    error IS21RetailRewardVault__InsufficientUndistributedRewards();
    error IS21RetailRewardVault__ReceiverMustBeEmpty();
    error IS21RetailRewardVault__CannotTransferToSelf();
    error IS21RetailRewardVault__AmountExceedsClaimableRewards();
    error IS21RetailRewardVault__NoActiveStakers();

    /////////////////////
    // State Variables //
    /////////////////////
    string public constant IS21_STAKING_VAULT_VERSION = "1.0.0";

    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS = 10_000;

    uint256 private constant TREASURY_BPS = 1_000; // 10%
    uint256 private constant STABILITY_RESERVE_BPS = 200; // 2%

    uint256 private constant MULTIPLIER_1X = 10_000; // 1.0x
    uint256 private constant MULTIPLIER_15X = 15_000; // 1.5x
    uint256 private constant MULTIPLIER_2X = 20_000; // 2.0x

    uint256 private constant LOYALTY_TIER_1_5X_TIME = 30 days;
    uint256 private constant LOYALTY_TIER_2X_TIME = 90 days;
    uint256 private constant THRESHOLD_2X = 100_000 ether;

    uint64 private constant EPOCH_DURATION = 1 hours;
    uint64 private immutable EPOCH_ZERO_TIMESTAMP;

    struct UserPosition {
        uint256 principalAssets; // Principal deposited / compounded into vault
        uint256 weightedAssets; // ACTIVE weight for the current epoch
        uint256 rewardDebt; // informational only
        uint256 pendingRewards; // settled but unclaimed
        uint64 weightedTimestamp; // weighted average timestamp for principal only
        uint64 lastDepositBlock;
        uint64 lastWithdrawBlock;
    }

    struct RewardStream {
        uint64 startEpoch; // inclusive
        uint64 endEpoch; // exclusive
        uint256 rewardPerEpoch; // base reward each epoch
        uint256 firstEpochBonus; // remainder paid in the first epoch only
    }

    // Principal accounting for ERC4626
    uint256 private sTotalPrincipalAssets;

    // Reward accounting
    uint256 private sTotalWeightedAssets; // ACTIVE total weight for current epoch
    uint256 private sPendingTotalWeightedAssets; // QUEUED total weight for next epoch
    uint256 private sAccRewardPerWeightedAsset;
    uint64 private sLastAccruedEpoch; // all epochs before this one are already accrued
    uint256 private sTotalReservedRewards; // rewards reserved for stakers and still inside the vault
    uint256 private sUndistributedRewards; // emitted while no active weighted stakers existed

    RewardStream private sRewardStream;

    mapping(address => UserPosition) private sUserPositions;
    mapping(address => uint256) private sUserPendingWeightedAssets; // next epoch queued weight
    mapping(address => uint64) private sUserLastSettledEpoch; // epoch user is synced to
    mapping(uint64 => uint256) private sAccRewardPerWeightedAssetAtEpoch; // cumulative acc at epoch boundary

    EnumerableSet.AddressSet private sRewardManagers;

    bool private sPositionTransferInProgress;

    address private treasuryWallet;
    address private stabilityWallet;

    ////////////
    // Events //
    ////////////
    event RewardManagerApproved(
        address indexed rewardManager,
        uint256 timestamp
    );
    event RewardManagerRevoked(
        address indexed rewardManager,
        uint256 timestamp
    );

    event TreasuryAddressUpdated(
        address indexed oldTreasury,
        address indexed newTreasury,
        uint256 timestamp
    );
    event StabilityReserveAddressUpdated(
        address indexed oldReserve,
        address indexed newReserve,
        uint256 timestamp
    );

    event RewardsAdded(
        address indexed rewardManager,
        uint256 totalAmount,
        uint256 treasuryAmount,
        uint256 stabilityReserveAmount,
        uint256 stakerAmount,
        uint64 epochCount,
        uint64 startEpoch,
        uint64 endEpoch,
        uint256 rolledLeftover
    );

    event RewardsClaimed(
        address indexed account,
        address indexed receiver,
        uint256 amount,
        uint256 timestamp
    );

    event RewardsCompounded(
        address indexed account,
        uint256 rewardAmount,
        uint256 mintedShares,
        uint256 timestamp
    );

    event UndistributedRewardsWithdrawn(
        address indexed rewardManager,
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );

    event FullPositionTransferred(
        address indexed from,
        address indexed to,
        uint256 shares,
        uint256 principalAssets,
        uint256 pendingRewards,
        uint256 timestamp
    );

    event RewardStreamConfigured(
        uint64 indexed startEpoch,
        uint64 indexed endEpoch,
        uint256 rewardPerEpoch,
        uint256 firstEpochBonus,
        uint256 timestamp
    );

    event PositionRefreshed(
        address indexed account,
        uint256 principalAssets,
        uint256 weightedAssets,
        uint256 pendingRewards,
        uint256 rewardDebt,
        uint256 multiplierBps,
        uint256 timestamp
    );

    event ContractPaused(address indexed caller, uint256 timestamp);
    event ContractUnpaused(address indexed caller, uint256 timestamp);

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert IS21RetailRewardVault__AmountMustBeMoreThanZero();
        _;
    }

    modifier nonZeroAddress(address account) {
        if (account == address(0))
            revert IS21RetailRewardVault__ZeroAddressNotAllowed();
        _;
    }

    modifier onlyRewardManager() {
        if (!sRewardManagers.contains(msg.sender)) {
            revert IS21RetailRewardVault__OnlyRewardManagerCanExecute();
        }
        _;
    }

    modifier cannotSendToContract(address to) {
        if (to == address(this)) {
            revert IS21RetailRewardVault__CannotSendToContract();
        }
        _;
    }

    /////////////////
    // Constructor //
    /////////////////
    constructor(
        address is21Token,
        address ownerAddress,
        address treasuryAddress,
        address stabilityReserveAddress
    )
        ERC4626(IERC20(is21Token))
        ERC20("Retail Staked InterShare21", "rsIS21")
        ERC20Permit("Staked InterShare21")
        Ownable(ownerAddress)
    {
        if (
            is21Token == address(0) ||
            ownerAddress == address(0) ||
            treasuryAddress == address(0) ||
            stabilityReserveAddress == address(0)
        ) {
            revert IS21RetailRewardVault__ZeroAddressNotAllowed();
        }

        treasuryWallet = treasuryAddress;
        stabilityWallet = stabilityReserveAddress;

        EPOCH_ZERO_TIMESTAMP = uint64(block.timestamp);
        sLastAccruedEpoch = 0;
        sAccRewardPerWeightedAssetAtEpoch[0] = 0;
    }

    ////////////////////////////////////
    // External/Public View Functions //
    ////////////////////////////////////

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function getVersion() external pure returns (string memory) {
        return IS21_STAKING_VAULT_VERSION;
    }

    function totalAssets() public view override returns (uint256) {
        return sTotalPrincipalAssets;
    }

    function getEpochDuration() external pure returns (uint64) {
        return EPOCH_DURATION;
    }

    function getEpochZeroTimestamp() external view returns (uint64) {
        return EPOCH_ZERO_TIMESTAMP;
    }

    function getCurrentEpoch() public view returns (uint64) {
        return _currentEpoch();
    }

    function getLastAccruedEpoch() external view returns (uint64) {
        return sLastAccruedEpoch;
    }

    function getTreasuryAddress() external view returns (address) {
        return treasuryWallet;
    }

    function getStabilityReserveAddress() external view returns (address) {
        return stabilityWallet;
    }

    function getRewardManagers() external view returns (address[] memory) {
        return sRewardManagers.values();
    }

    function isRewardManager(address account) external view returns (bool) {
        return sRewardManagers.contains(account);
    }

    function getUserPosition(
        address account
    ) external view returns (UserPosition memory) {
        return sUserPositions[account];
    }

    function getUserPendingWeightedAssets(
        address account
    ) external view returns (uint256) {
        return sUserPendingWeightedAssets[account];
    }

    function getUserLastSettledEpoch(
        address account
    ) external view returns (uint64) {
        return sUserLastSettledEpoch[account];
    }

    function getTotalWeightedAssets() external view returns (uint256) {
        return sTotalWeightedAssets;
    }

    function getPendingTotalWeightedAssets() external view returns (uint256) {
        return sPendingTotalWeightedAssets;
    }

    function getAccRewardPerWeightedAsset() external view returns (uint256) {
        return sAccRewardPerWeightedAsset;
    }

    function getTotalReservedRewards() external view returns (uint256) {
        return sTotalReservedRewards;
    }

    function getUndistributedRewards() external view returns (uint256) {
        return sUndistributedRewards;
    }

    function getRewardStream() external view returns (RewardStream memory) {
        return sRewardStream;
    }

    function getRemainingScheduledRewards() external view returns (uint256) {
        return _remainingScheduledRewards(_currentEpoch());
    }

    /**
     * @notice Previews the claimable rewards for msg.sender.
     * @return The currently previewed claimable rewards.
     */
    function previewClaimRewards() external view returns (uint256) {
        return previewClaimRewards(msg.sender);
    }

    /**
     * @notice Previews the claimable rewards for an account.
     * @param account The account to preview rewards for.
     * @return The currently previewed claimable rewards.
     * @dev Returns 0 for the zero address.
     */
    function previewClaimRewards(
        address account
    ) public view returns (uint256) {
        if (account == address(0)) {
            return 0;
        }

        UserPosition memory user = sUserPositions[account];
        uint64 currentEpoch = _currentEpoch();
        uint64 lastSettledEpoch = sUserLastSettledEpoch[account];

        uint256 claimable = user.pendingRewards;

        if (currentEpoch > lastSettledEpoch) {
            if (user.weightedAssets > 0) {
                uint256 accAtLast = _accRewardPerWeightedAssetAtEpoch(
                    lastSettledEpoch
                );
                uint256 accAtNext = _accRewardPerWeightedAssetAtEpoch(
                    lastSettledEpoch + 1
                );

                claimable +=
                    (user.weightedAssets * (accAtNext - accAtLast)) /
                    PRECISION;
            }

            if (currentEpoch > lastSettledEpoch + 1) {
                uint256 pendingWeight = sUserPendingWeightedAssets[account];
                if (pendingWeight > 0) {
                    uint256 accFrom = _accRewardPerWeightedAssetAtEpoch(
                        lastSettledEpoch + 1
                    );
                    uint256 accTo = _accRewardPerWeightedAssetAtEpoch(
                        currentEpoch
                    );

                    claimable +=
                        (pendingWeight * (accTo - accFrom)) /
                        PRECISION;
                }
            }
        }

        return claimable;
    }

    /**
     * @notice Returns the multiplier that would apply if refreshed now.
     * @dev Since weights are epoch-latched, this previews the NEXT epoch multiplier.
     */
    function previewCurrentMultiplierBps() external view returns (uint256) {
        return previewCurrentMultiplierBps(msg.sender);
    }

    /**
     * @notice Returns the multiplier that would apply if refreshed now.
     * @dev Since weights are epoch-latched, this previews the NEXT epoch multiplier.
     */
    function previewCurrentMultiplierBps(
        address account
    ) public view returns (uint256) {
        UserPosition memory user = sUserPositions[account];
        uint256 claimable = previewClaimRewards(account);

        return
            _determineMultiplierBps(
                _nextEpochReferenceTimestamp(),
                uint256(user.weightedTimestamp),
                user.principalAssets,
                claimable
            );
    }

    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxWithdraw(
        address owner_
    ) public view override returns (uint256) {
        if (paused()) return 0;
        if (sUserPositions[owner_].lastDepositBlock == uint64(block.number))
            return 0;
        return convertToAssets(balanceOf(owner_));
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (sUserPositions[owner_].lastDepositBlock == uint64(block.number))
            return 0;
        return balanceOf(owner_);
    }

    /////////////////////////////////////
    // External/Public Write Functions //
    /////////////////////////////////////

    /**
     * @notice Refreshes msg.sender's rewards and queues next-epoch multiplier/weight state.
     * @dev Accrues completed epochs, settles pending rewards, and updates next epoch weight.
     */
    function refreshPosition() external nonReentrant whenNotPaused {
        _accrueGlobal();
        _settleAndSyncUser(msg.sender);
        _queueUserWeightForNextEpoch(msg.sender);

        UserPosition memory user = sUserPositions[msg.sender];

        uint256 multiplierBps = _determineMultiplierBps(
            _nextEpochReferenceTimestamp(),
            uint256(user.weightedTimestamp),
            user.principalAssets,
            previewClaimRewards(msg.sender)
        );

        emit PositionRefreshed(
            msg.sender,
            user.principalAssets,
            user.weightedAssets,
            user.pendingRewards,
            user.rewardDebt,
            multiplierBps,
            block.timestamp
        );
    }

    function approveRewardManager(
        address rewardManager
    ) external onlyOwner nonZeroAddress(rewardManager) nonReentrant {
        if (sRewardManagers.add(rewardManager)) {
            emit RewardManagerApproved(rewardManager, block.timestamp);
        }
    }

    function revokeRewardManager(
        address rewardManager
    ) external onlyOwner nonZeroAddress(rewardManager) nonReentrant {
        if (sRewardManagers.remove(rewardManager)) {
            emit RewardManagerRevoked(rewardManager, block.timestamp);
        }
    }

    function setTreasuryAddress(
        address newTreasury
    ) external onlyOwner nonZeroAddress(newTreasury) nonReentrant {
        address oldTreasury = treasuryWallet;
        treasuryWallet = newTreasury;
        emit TreasuryAddressUpdated(oldTreasury, newTreasury, block.timestamp);
    }

    function setStabilityReserveAddress(
        address newReserve
    ) external onlyOwner nonZeroAddress(newReserve) nonReentrant {
        address oldReserve = stabilityWallet;
        stabilityWallet = newReserve;
        emit StabilityReserveAddressUpdated(
            oldReserve,
            newReserve,
            block.timestamp
        );
    }

    /**
     * @notice Adds IS21 reward tokens and creates a new single reward stream.
     * @param totalAmount Total IS21 supplied by reward manager.
     * @param epochCount Number of epochs over which the 88% staker amount is streamed.
     *
     * @dev Existing leftover scheduled rewards are rolled into the new stream.
     */
    function addRewards(
        uint256 totalAmount,
        uint64 epochCount
    )
        external
        onlyRewardManager
        moreThanZero(totalAmount)
        nonReentrant
        whenNotPaused
    {
        if (epochCount == 0) {
            revert IS21RetailRewardVault__InvalidEpochCount();
        }

        if (treasuryWallet == address(0) || stabilityWallet == address(0)) {
            revert IS21RetailRewardVault__RewardAddressesNotConfigured();
        }

        _accrueGlobal();

        // Require active stakers for the stream's starting epoch.
        if (sTotalWeightedAssets == 0) {
            revert IS21RetailRewardVault__NoActiveStakers();
        }

        IERC20 assetToken = IERC20(asset());
        assetToken.safeTransferFrom(msg.sender, address(this), totalAmount);

        uint256 treasuryAmount = (totalAmount * TREASURY_BPS) / BPS;
        uint256 reserveAmount = (totalAmount * STABILITY_RESERVE_BPS) / BPS;
        uint256 stakerAmount = totalAmount - treasuryAmount - reserveAmount;

        if (treasuryAmount > 0) {
            assetToken.safeTransfer(treasuryWallet, treasuryAmount);
        }

        if (reserveAmount > 0) {
            assetToken.safeTransfer(stabilityWallet, reserveAmount);
        }

        uint64 currentEpoch = _currentEpoch();
        uint256 leftover = _remainingScheduledRewards(currentEpoch);
        uint256 totalForNewStream = leftover + stakerAmount;

        if (totalForNewStream == 0) {
            revert IS21RetailRewardVault__AmountMustBeMoreThanZero();
        }

        uint256 rewardPerEpoch = totalForNewStream / epochCount;
        uint256 firstEpochBonus = totalForNewStream % epochCount;

        sRewardStream = RewardStream({
            startEpoch: currentEpoch,
            endEpoch: currentEpoch + epochCount,
            rewardPerEpoch: rewardPerEpoch,
            firstEpochBonus: firstEpochBonus
        });

        // Reserved rewards only increase by newly supplied stakerAmount.
        // Leftover already existed inside reserved accounting.
        sTotalReservedRewards += stakerAmount;

        emit RewardStreamConfigured(
            currentEpoch,
            currentEpoch + epochCount,
            rewardPerEpoch,
            firstEpochBonus,
            block.timestamp
        );

        emit RewardsAdded(
            msg.sender,
            totalAmount,
            treasuryAmount,
            reserveAmount,
            stakerAmount,
            epochCount,
            currentEpoch,
            currentEpoch + epochCount,
            leftover
        );
    }

    /**
     * @notice Claim all currently claimable IS21 rewards to msg.sender.
     */
    function claimRewards()
        external
        nonReentrant
        whenNotPaused
        returns (uint256 claimed)
    {
        claimed = _claimRewardsTo(msg.sender);
    }

    /**
     * @notice Claim all currently claimable IS21 rewards to a chosen receiver.
     */
    function claimRewardsTo(
        address receiver
    ) external nonReentrant whenNotPaused returns (uint256 claimed) {
        claimed = _claimRewardsTo(receiver);
    }

    /**
     * @notice Compound all currently claimable rewards into principal.
     * @dev Does NOT reset loyalty age. Treated as internal growth of existing principal.
     */
    function compoundRewards()
        external
        nonReentrant
        whenNotPaused
        returns (uint256 compounded, uint256 mintedShares)
    {
        (compounded, mintedShares) = _compoundRewards(
            msg.sender,
            type(uint256).max
        );
    }

    /**
     * @notice Compound a specific amount of currently claimable rewards into principal.
     * @dev Does NOT reset loyalty age.
     */
    function compoundRewards(
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
        moreThanZero(amount)
        returns (uint256 compounded, uint256 mintedShares)
    {
        (compounded, mintedShares) = _compoundRewards(msg.sender, amount);
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) public override nonReentrant whenNotPaused returns (uint256) {
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override nonReentrant whenNotPaused returns (uint256) {
        return super.redeem(shares, receiver, owner_);
    }

    /**
     * @notice Withdraw previously emitted rewards that became undistributed because no active weighted stakers existed.
     */
    function withdrawUndistributedRewards(
        uint256 amount,
        address to
    )
        external
        onlyRewardManager
        nonZeroAddress(to)
        moreThanZero(amount)
        nonReentrant
    {
        _accrueGlobal();

        if (amount > sUndistributedRewards) {
            revert IS21RetailRewardVault__InsufficientUndistributedRewards();
        }

        sUndistributedRewards -= amount;
        IERC20(asset()).safeTransfer(to, amount);

        emit UndistributedRewardsWithdrawn(
            msg.sender,
            to,
            amount,
            block.timestamp
        );
    }

    /**
     * @notice Rescue tokens accidentally sent to the contract, but never principal-backed assets
     *         or reserved rewards or undistributed rewards.
     */
    function rescueErc20(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner nonZeroAddress(token) nonZeroAddress(to) nonReentrant {
        if (token == asset()) {
            uint256 requiredBalance = sTotalPrincipalAssets +
                sTotalReservedRewards +
                sUndistributedRewards;
            uint256 currentBalance = IERC20(token).balanceOf(address(this));
            uint256 freeBalance = currentBalance > requiredBalance
                ? currentBalance - requiredBalance
                : 0;

            if (amount > freeBalance) {
                revert IS21RetailRewardVault__InsufficientFreeBalanceForRescue();
            }
        }

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Transfer full economic position to an empty wallet.
     */
    function transferFullPosition(
        address to
    )
        external
        nonReentrant
        whenNotPaused
        nonZeroAddress(to)
        cannotSendToContract(to)
    {
        if (to == msg.sender) {
            revert IS21RetailRewardVault__CannotTransferToSelf();
        }

        if (!_isEmptyPosition(to)) {
            revert IS21RetailRewardVault__ReceiverMustBeEmpty();
        }

        uint256 sharesToMove = balanceOf(msg.sender);
        if (sharesToMove == 0) {
            revert IS21RetailRewardVault__AmountMustBeMoreThanZero();
        }

        _accrueGlobal();
        _settleAndSyncUser(msg.sender);

        UserPosition storage sender = sUserPositions[msg.sender];
        UserPosition storage receiver = sUserPositions[to];

        uint256 principalToMove = sender.principalAssets;
        uint256 weightedToMove = sender.weightedAssets;
        uint256 rewardDebtToMove = sender.rewardDebt;
        uint256 pendingRewardsToMove = sender.pendingRewards;
        uint64 weightedTimestampToMove = sender.weightedTimestamp;

        uint256 pendingWeightedToMove = sUserPendingWeightedAssets[msg.sender];
        uint64 lastSettledEpochToMove = sUserLastSettledEpoch[msg.sender];

        sPositionTransferInProgress = true;
        _transfer(msg.sender, to, sharesToMove);
        sPositionTransferInProgress = false;

        receiver.principalAssets = principalToMove;
        receiver.weightedAssets = weightedToMove;
        receiver.rewardDebt = rewardDebtToMove;
        receiver.pendingRewards = pendingRewardsToMove;
        receiver.weightedTimestamp = weightedTimestampToMove;
        receiver.lastDepositBlock = uint64(block.number);
        receiver.lastWithdrawBlock = 0;

        sUserPendingWeightedAssets[to] = pendingWeightedToMove;
        sUserLastSettledEpoch[to] = lastSettledEpochToMove;

        delete sUserPositions[msg.sender];
        delete sUserPendingWeightedAssets[msg.sender];
        delete sUserLastSettledEpoch[msg.sender];

        emit FullPositionTransferred(
            msg.sender,
            to,
            sharesToMove,
            principalToMove,
            pendingRewardsToMove,
            block.timestamp
        );
    }

    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender, block.timestamp);
    }

    receive() external payable {
        revert IS21RetailRewardVault__ETHNotAccepted();
    }

    fallback() external payable {
        revert IS21RetailRewardVault__ETHNotAccepted();
    }

    ////////////////////////////////////
    // ERC4626 Overrides / Internals  //
    ////////////////////////////////////

    /**
     * @dev Deposit affects principal and weighted timestamp.
     *      Weight change applies NEXT epoch only.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        _accrueGlobal();
        _settleAndSyncUser(receiver);

        UserPosition storage user = sUserPositions[receiver];

        uint256 oldPrincipal = user.principalAssets;
        uint256 newPrincipal = oldPrincipal + assets;

        if (oldPrincipal == 0) {
            user.weightedTimestamp = uint64(block.timestamp);
        } else {
            uint256 newWeightedTimestamp = ((oldPrincipal *
                uint256(user.weightedTimestamp)) + (assets * block.timestamp)) /
                newPrincipal;
            user.weightedTimestamp = uint64(newWeightedTimestamp);
        }

        user.principalAssets = newPrincipal;
        user.lastDepositBlock = uint64(block.number);

        sTotalPrincipalAssets += assets;

        _queueUserWeightForNextEpoch(receiver);

        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw affects principal but weight change applies NEXT epoch only.
     *      Loyalty timestamp is preserved unless principal becomes zero.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        UserPosition storage user = sUserPositions[owner_];

        if (user.lastDepositBlock == uint64(block.number)) {
            revert IS21RetailRewardVault__SameBlockWithdrawNotAllowed();
        }

        _accrueGlobal();
        _settleAndSyncUser(owner_);

        user.principalAssets -= assets;
        user.lastWithdrawBlock = uint64(block.number);

        if (user.principalAssets == 0) {
            user.weightedTimestamp = 0;
        }

        sTotalPrincipalAssets -= assets;

        _queueUserWeightForNextEpoch(owner_);

        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /**
     * @dev Prevent user-to-user share transfers except during controlled full-position migration.
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) cannotSendToContract(to) {
        if (
            from != address(0) &&
            to != address(0) &&
            !sPositionTransferInProgress
        ) {
            revert IS21RetailRewardVault__ShareTransfersDisabled();
        }

        super._update(from, to, value);
    }

    ////////////////////////////////////
    // Reward Accounting Internals    //
    ////////////////////////////////////

    /**
     * @dev Accrues completed epochs only.
     *
     * CRITICAL FIX:
     * This version writes accumulator checkpoints for EVERY elapsed epoch boundary.
     * That guarantees historical reads like:
     * - acc(lastSettledEpoch)
     * - acc(lastSettledEpoch + 1)
     * - acc(currentEpoch)
     * are always valid for settlement and previews.
     *
     * Weight model remains unchanged:
     * - first unaccrued epoch uses sTotalWeightedAssets
     * - all later elapsed epochs use sPendingTotalWeightedAssets
     */
    function _accrueGlobal() internal {
        uint64 currentEpoch = _currentEpoch();
        uint64 fromEpoch = sLastAccruedEpoch;

        if (currentEpoch <= fromEpoch) {
            return;
        }

        uint256 acc = sAccRewardPerWeightedAsset;
        uint256 activeTotal = sTotalWeightedAssets;
        uint256 pendingTotal = sPendingTotalWeightedAssets;

        for (uint64 epoch = fromEpoch; epoch < currentEpoch; epoch++) {
            uint256 epochWeight = epoch == fromEpoch
                ? activeTotal
                : pendingTotal;
            uint256 emitted = _scheduledRewardsBetween(epoch, epoch + 1);

            if (emitted > 0) {
                if (epochWeight > 0) {
                    acc += (emitted * PRECISION) / epochWeight;
                } else {
                    sUndistributedRewards += emitted;
                    sTotalReservedRewards -= emitted;
                }
            }

            sAccRewardPerWeightedAssetAtEpoch[epoch + 1] = acc;
        }

        sAccRewardPerWeightedAsset = acc;
        sLastAccruedEpoch = currentEpoch;

        // After syncing to current epoch, active and pending both equal the
        // queued weight unless new changes happen later in the current epoch.
        sTotalWeightedAssets = pendingTotal;
        sPendingTotalWeightedAssets = pendingTotal;
    }

    /**
     * @dev Settles already-accrued rewards to pendingRewards and syncs the user
     *      to the current epoch.
     *
     * Settlement model:
     * - user.weightedAssets applies to the first unsettled epoch
     * - sUserPendingWeightedAssets applies from the next epoch onward
     */
    function _settleAndSyncUser(address account) internal {
        UserPosition storage user = sUserPositions[account];

        uint64 currentEpoch = _currentEpoch();
        uint64 lastSettledEpoch = sUserLastSettledEpoch[account];

        if (currentEpoch > lastSettledEpoch) {
            uint256 settledRewards = 0;

            // First unsettled epoch uses ACTIVE weight.
            if (user.weightedAssets > 0) {
                uint256 accAtLast = _accRewardPerWeightedAssetAtEpoch(
                    lastSettledEpoch
                );
                uint256 accAtNext = _accRewardPerWeightedAssetAtEpoch(
                    lastSettledEpoch + 1
                );

                settledRewards +=
                    (user.weightedAssets * (accAtNext - accAtLast)) /
                    PRECISION;
            }

            // Remaining epochs use PENDING queued weight.
            if (currentEpoch > lastSettledEpoch + 1) {
                uint256 pendingWeight = sUserPendingWeightedAssets[account];

                if (pendingWeight > 0) {
                    uint256 accFrom = _accRewardPerWeightedAssetAtEpoch(
                        lastSettledEpoch + 1
                    );
                    uint256 accTo = _accRewardPerWeightedAssetAtEpoch(
                        currentEpoch
                    );

                    settledRewards +=
                        (pendingWeight * (accTo - accFrom)) /
                        PRECISION;
                }
            }

            if (settledRewards > 0) {
                user.pendingRewards += settledRewards;
            }

            // Sync current active weight to the queued weight.
            user.weightedAssets = sUserPendingWeightedAssets[account];
            sUserLastSettledEpoch[account] = currentEpoch;
        }

        // informational only
        user.rewardDebt =
            (user.weightedAssets *
                _accRewardPerWeightedAssetAtEpoch(currentEpoch)) /
            PRECISION;
    }

    /**
     * @dev Recomputes and queues the user's NEXT epoch weight.
     *      Current epoch active weight is untouched.
     */
    function _queueUserWeightForNextEpoch(address account) internal {
        UserPosition storage user = sUserPositions[account];

        uint256 oldPendingWeight = sUserPendingWeightedAssets[account];

        uint256 multiplierBps = _determineMultiplierBps(
            _nextEpochReferenceTimestamp(),
            uint256(user.weightedTimestamp),
            user.principalAssets,
            user.pendingRewards
        );

        uint256 newPendingWeight = (user.principalAssets * multiplierBps) / BPS;

        if (newPendingWeight != oldPendingWeight) {
            sPendingTotalWeightedAssets =
                sPendingTotalWeightedAssets -
                oldPendingWeight +
                newPendingWeight;

            sUserPendingWeightedAssets[account] = newPendingWeight;
        }

        // informational only
        user.rewardDebt =
            (user.weightedAssets *
                _accRewardPerWeightedAssetAtEpoch(_currentEpoch())) /
            PRECISION;
    }

    /**
     * @dev Claim all currently claimable rewards to a receiver.
     */
    function _claimRewardsTo(
        address receiver
    )
        internal
        nonZeroAddress(receiver)
        cannotSendToContract(receiver)
        returns (uint256 claimed)
    {
        UserPosition storage user = sUserPositions[msg.sender];

        if (
            user.lastDepositBlock == uint64(block.number) ||
            user.lastWithdrawBlock == uint64(block.number)
        ) {
            revert IS21RetailRewardVault__SameBlockClaimNotAllowed();
        }

        _accrueGlobal();
        _settleAndSyncUser(msg.sender);

        claimed = user.pendingRewards;
        if (claimed == 0) {
            revert IS21RetailRewardVault__InsufficientClaimableRewards();
        }

        user.pendingRewards = 0;
        sTotalReservedRewards -= claimed;

        _queueUserWeightForNextEpoch(msg.sender);

        IERC20(asset()).safeTransfer(receiver, claimed);

        emit RewardsClaimed(msg.sender, receiver, claimed, block.timestamp);
    }

    /**
     * @dev Compound claimable rewards into principal.
     *      Does NOT reset loyalty age for users who already have principal.
     *      The reward assets already exist inside the vault as reserved rewards,
     *      and are internally reclassified into principal-backed assets.
     *      New weight applies NEXT epoch only.
     */
    function _compoundRewards(
        address account,
        uint256 requestedAmount
    ) internal returns (uint256 compounded, uint256 mintedShares) {
        UserPosition storage user = sUserPositions[account];

        if (
            user.lastDepositBlock == uint64(block.number) ||
            user.lastWithdrawBlock == uint64(block.number)
        ) {
            revert IS21RetailRewardVault__SameBlockCompoundNotAllowed();
        }

        _accrueGlobal();
        _settleAndSyncUser(account);

        uint256 claimable = user.pendingRewards;
        if (claimable == 0) {
            revert IS21RetailRewardVault__InsufficientClaimableRewards();
        }

        compounded = requestedAmount > claimable ? claimable : requestedAmount;
        if (
            requestedAmount != type(uint256).max && requestedAmount > claimable
        ) {
            revert IS21RetailRewardVault__AmountExceedsClaimableRewards();
        }

        // Preview shares before principal grows.
        mintedShares = previewDeposit(compounded);

        user.pendingRewards -= compounded;
        sTotalReservedRewards -= compounded;

        uint256 oldPrincipal = user.principalAssets;
        user.principalAssets = oldPrincipal + compounded;

        // Compounding should NOT reset or average down loyalty age.
        // If the user already has principal, preserve weightedTimestamp unchanged.
        // If the user had zero principal, a new principal position begins now.
        if (oldPrincipal == 0) {
            user.weightedTimestamp = uint64(block.timestamp);
        }

        sTotalPrincipalAssets += compounded;

        _queueUserWeightForNextEpoch(account);
        _mint(account, mintedShares);
        user.lastDepositBlock = uint64(block.number);

        emit Deposit(account, account, compounded, mintedShares);
        emit RewardsCompounded(
            account,
            compounded,
            mintedShares,
            block.timestamp
        );
    }

    /**
     * @dev Multiplier rules, evaluated at epoch boundaries:
     * - Immediate 2x if principal + unclaimed rewards >= 100k IS21
     * - else age-based tiers
     */
    function _determineMultiplierBps(
        uint256 epochReferenceTimestamp,
        uint256 weightedTimestamp,
        uint256 principalAssets,
        uint256 pendingRewards
    ) internal pure returns (uint256) {
        if (principalAssets == 0) {
            return 0;
        }

        if (principalAssets + pendingRewards >= THRESHOLD_2X) {
            return MULTIPLIER_2X;
        }

        uint256 age = 0;
        if (
            weightedTimestamp > 0 && epochReferenceTimestamp > weightedTimestamp
        ) {
            age = epochReferenceTimestamp - weightedTimestamp;
        }

        if (age >= LOYALTY_TIER_2X_TIME) {
            return MULTIPLIER_2X;
        }

        if (age >= LOYALTY_TIER_1_5X_TIME) {
            return MULTIPLIER_15X;
        }

        return MULTIPLIER_1X;
    }

    /**
     * @dev Returns cumulative accRewardPerWeightedAsset at an epoch boundary.
     *      Works for:
     *      - historical synced epochs from storage
     *      - current / future preview within the current unsynced window
     */
    function _accRewardPerWeightedAssetAtEpoch(
        uint64 targetEpoch
    ) internal view returns (uint256) {
        uint64 lastAccrued = sLastAccruedEpoch;

        if (targetEpoch < lastAccrued) {
            return sAccRewardPerWeightedAssetAtEpoch[targetEpoch];
        }

        if (targetEpoch == lastAccrued) {
            return sAccRewardPerWeightedAsset;
        }

        uint64 currentEpoch = _currentEpoch();
        if (targetEpoch > currentEpoch) {
            targetEpoch = currentEpoch;
        }

        uint256 acc = sAccRewardPerWeightedAsset;
        uint256 activeTotal = sTotalWeightedAssets;
        uint256 pendingTotal = sPendingTotalWeightedAssets;

        // First previewed epoch uses active total.
        uint64 firstBoundary = lastAccrued + 1;

        uint256 emittedFirst = _scheduledRewardsBetween(
            lastAccrued,
            firstBoundary
        );

        if (emittedFirst > 0 && activeTotal > 0) {
            acc += (emittedFirst * PRECISION) / activeTotal;
        }

        if (targetEpoch == firstBoundary) {
            return acc;
        }

        if (targetEpoch > firstBoundary) {
            uint256 emittedRest = _scheduledRewardsBetween(
                firstBoundary,
                targetEpoch
            );

            if (emittedRest > 0 && pendingTotal > 0) {
                acc += (emittedRest * PRECISION) / pendingTotal;
            }
        }

        return acc;
    }

    /**
     * @dev Returns scheduled reward amount for epoch range [fromEpoch, toEpoch).
     */
    function _scheduledRewardsBetween(
        uint64 fromEpoch,
        uint64 toEpoch
    ) internal view returns (uint256 amount) {
        RewardStream memory stream = sRewardStream;

        if (toEpoch <= fromEpoch) return 0;
        if (stream.endEpoch <= stream.startEpoch) return 0;
        if (toEpoch <= stream.startEpoch) return 0;
        if (fromEpoch >= stream.endEpoch) return 0;

        uint64 overlapStart = fromEpoch > stream.startEpoch
            ? fromEpoch
            : stream.startEpoch;
        uint64 overlapEnd = toEpoch < stream.endEpoch
            ? toEpoch
            : stream.endEpoch;

        if (overlapEnd <= overlapStart) return 0;

        uint256 epochCount = uint256(overlapEnd - overlapStart);
        amount = epochCount * stream.rewardPerEpoch;

        // firstEpochBonus is paid only once, on the first epoch of the stream
        if (overlapStart == stream.startEpoch) {
            amount += stream.firstEpochBonus;
        }
    }

    /**
     * @dev Returns the scheduled reward amount not yet emitted from currentEpoch onward.
     */
    function _remainingScheduledRewards(
        uint64 currentEpoch
    ) internal view returns (uint256) {
        RewardStream memory stream = sRewardStream;

        if (stream.endEpoch <= stream.startEpoch) return 0;
        if (currentEpoch >= stream.endEpoch) return 0;

        uint64 start = currentEpoch > stream.startEpoch
            ? currentEpoch
            : stream.startEpoch;
        return _scheduledRewardsBetween(start, stream.endEpoch);
    }

    function _currentEpoch() internal view returns (uint64) {
        return
            uint64((block.timestamp - EPOCH_ZERO_TIMESTAMP) / EPOCH_DURATION);
    }

    /**
     * @dev Reference timestamp for CURRENT epoch multiplier evaluation.
     */
    function _currentEpochReferenceTimestamp() internal view returns (uint256) {
        return
            uint256(EPOCH_ZERO_TIMESTAMP) +
            (uint256(_currentEpoch()) * uint256(EPOCH_DURATION));
    }

    /**
     * @dev Reference timestamp for NEXT epoch multiplier evaluation.
     */
    function _nextEpochReferenceTimestamp() internal view returns (uint256) {
        return
            uint256(EPOCH_ZERO_TIMESTAMP) +
            ((uint256(_currentEpoch()) + 1) * uint256(EPOCH_DURATION));
    }

    function _isEmptyPosition(address account) internal view returns (bool) {
        UserPosition memory user = sUserPositions[account];

        return
            balanceOf(account) == 0 &&
            user.principalAssets == 0 &&
            user.weightedAssets == 0 &&
            user.rewardDebt == 0 &&
            user.pendingRewards == 0 &&
            user.weightedTimestamp == 0 &&
            sUserPendingWeightedAssets[account] == 0;
    }
}
