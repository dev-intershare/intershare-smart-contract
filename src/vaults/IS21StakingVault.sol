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
 * @title IS21StakingVault
 * @author InterShare Team
 *
 * @notice ERC4626 staking vault for IS21.
 *
 * @dev Design summary:
 * - Asset = IS21.
 * - Users deposit IS21 and receive non-transferable ERC4626 vault shares.
 * - Principal remains in the vault and is withdrawable through ERC4626.
 * - Rewards are added separately by approved reward managers.
 * - Each reward injection is split:
 *   - 10% treasury
 *   - 2% stability reserve
 *   - 88% staker rewards
 * - Staker rewards are streamed linearly over a chosen duration.
 * - Multiple reward streams may overlap.
 * - Users claim rewards with claimRewards() without touching principal.
 * - Loyalty multiplier is based on weighted average timestamp and threshold logic:
 *   - 1x for < 31 days
 *   - 1.5x for 31-90 days
 *   - 2x for > 90 days
 *   - OR immediately 2x whenever principal + unclaimed rewards >= 100,000 IS21
 * - Unclaimed rewards count toward the 100k threshold.
 * - Claiming rewards can reduce the threshold-based 2x multiplier if the user drops below 100k
 *   and their age tier is lower.
 * - Flash-loan style protection:
 *   - cannot withdraw in same block as deposit
 *   - cannot claim in same block as deposit
 *   - cannot claim in same block as withdraw
 *
 * @dev Important:
 * - Vault shares are deliberately non-transferable between users.
 * - totalAssets() returns PRINCIPAL assets only, excluding reward escrow, so ERC4626 share pricing
 *   is not distorted by separate claimable rewards.
 */
contract IS21StakingVault is
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
    error IS21StakingVault__AmountMustBeMoreThanZero();
    error IS21StakingVault__NotZeroAddress();
    error IS21StakingVault__ETHNotAccepted();
    error IS21StakingVault__CannotSendToContract();
    error IS21StakingVault__OnlyRewardManagerCanExecute();
    error IS21StakingVault__InvalidDuration();
    error IS21StakingVault__InsufficientClaimableRewards();
    error IS21StakingVault__SameBlockWithdrawNotAllowed();
    error IS21StakingVault__SameBlockClaimNotAllowed();
    error IS21StakingVault__ShareTransfersDisabled();
    error IS21StakingVault__InsufficientFreeBalanceForRescue();
    error IS21StakingVault__RewardAddressesNotConfigured();
    error IS21StakingVault__NoActiveStakers();
    error IS21StakingVault__InsufficientUndistributedRewards();
    error IS21StakingVault__ReceiverMustBeEmpty();
    error IS21StakingVault__CannotTransferToSelf();

    /////////////////////
    // State Variables //
    /////////////////////
    string public constant IS21_STAKING_VAULT_VERSION = "1.0.0";

    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS = 10_000;

    uint256 private constant TREASURY_BPS = 1_000; // 10%
    uint256 private constant STABILITY_RESERVE_BPS = 200; // 2%
    uint256 private constant MULTIPLIER_1X = 10_000; // 1X
    uint256 private constant MULTIPLIER_15X = 15_000; // 1.5X
    uint256 private constant MULTIPLIER_2X = 20_000; // 2X
    uint256 private constant LOYALTY_TIER_1_5X_TIME = 30 days;
    uint256 private constant LOYALTY_TIER_2X_TIME = 90 days;
    uint256 private constant THRESHOLD_2X = 100_000 ether;

    struct UserPosition {
        uint256 principalAssets; // User principal deposited into vault
        uint256 weightedAssets; // principalAssets adjusted by multiplier
        uint256 rewardDebt; // weightedAssets * accRewardPerWeightedAsset / PRECISION
        uint256 pendingRewards; // settled but unclaimed rewards
        uint64 weightedTimestamp; // weighted average entry timestamp for principal only
        uint64 lastDepositBlock;
        uint64 lastWithdrawBlock;
    }

    // Principal accounting for ERC4626
    uint256 private sTotalPrincipalAssets;

    // Reward accounting
    uint256 private sTotalWeightedAssets;
    uint256 private sAccRewardPerWeightedAsset;
    uint256 private sLastRewardUpdate;
    uint256 private sCurrentRewardRate; // scaled by PRECISION, reward tokens per second * 1e18
    uint256 private sTotalReservedRewards; // reward tokens held for stakers, not principal-backed
    uint256 private sUndistributedRewards; // rewards emitted while no active weighted stakers existed
    bool private sPositionTransferInProgress;

    // Scheduled reward-rate drops when reward streams end
    uint256[] private sRewardRateChangeTimes;
    mapping(uint256 => uint256) private sRateDecreaseAtTime;
    mapping(uint256 => bool) private sRateChangeTimeExists;
    uint256 private sNextRateChangeIndex;
    mapping(address => UserPosition) private sUserPositions;
    EnumerableSet.AddressSet private sRewardManagers;
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
        uint256 duration,
        uint256 startTime,
        uint256 endTime
    );

    event RewardsClaimed(
        address indexed account,
        address indexed receiver,
        uint256 amount,
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

    event ContractPaused(address indexed caller, uint256 timestamp);
    event ContractUnpaused(address indexed caller, uint256 timestamp);

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert IS21StakingVault__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier nonZeroAddress(address account) {
        if (account == address(0)) {
            revert IS21StakingVault__NotZeroAddress();
        }
        _;
    }

    modifier onlyRewardManager() {
        if (!sRewardManagers.contains(msg.sender)) {
            revert IS21StakingVault__OnlyRewardManagerCanExecute();
        }
        _;
    }

    modifier cannotSendToContract(address to) {
        if (to == address(this)) {
            revert IS21StakingVault__CannotSendToContract();
        }
        _;
    }

    /////////////////
    // Constructor //
    /////////////////
    /**
     * @param is21Token The IS21 token address used as the ERC4626 asset.
     * @param ownerAddress The contract owner.
     * @param treasuryAddress The treasury destination for the 10% split.
     * @param stabilityReserveAddress The stability reserve destination for the 2% split.
     */
    constructor(
        address is21Token,
        address ownerAddress,
        address treasuryAddress,
        address stabilityReserveAddress
    )
        ERC4626(IERC20(is21Token))
        ERC20("Staked InterShare21", "sIS21")
        ERC20Permit("Staked InterShare21")
        Ownable(ownerAddress)
    {
        if (
            ownerAddress == address(0) ||
            treasuryAddress == address(0) ||
            stabilityReserveAddress == address(0) ||
            address(is21Token) == address(0)
        ) {
            revert IS21StakingVault__NotZeroAddress();
        }

        treasuryWallet = treasuryAddress;
        stabilityWallet = stabilityReserveAddress;
        sLastRewardUpdate = block.timestamp;
    }

    ///////////////////////////////////
    //  External/Public Functions    //
    ///////////////////////////////////

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function getVersion() external pure returns (string memory) {
        return IS21_STAKING_VAULT_VERSION;
    }

    /**
     * @notice ERC4626 totalAssets MUST represent principal-backed assets only.
     * @dev Reward escrow is excluded intentionally, otherwise reward tokens would distort share price.
     */
    function totalAssets() public view override returns (uint256) {
        return sTotalPrincipalAssets;
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

    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        if (sUserPositions[owner].lastDepositBlock == uint64(block.number))
            return 0;
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        if (sUserPositions[owner].lastDepositBlock == uint64(block.number))
            return 0;
        return balanceOf(owner);
    }

    function getRewardRateChangeTimes()
        external
        view
        returns (uint256[] memory)
    {
        return sRewardRateChangeTimes;
    }

    function getRateDecreaseAtTime(
        uint256 time
    ) external view returns (uint256) {
        return sRateDecreaseAtTime[time];
    }

    function getUserPosition(
        address account
    ) external view returns (UserPosition memory) {
        return sUserPositions[account];
    }

    function getTotalWeightedAssets() external view returns (uint256) {
        return sTotalWeightedAssets;
    }

    function getAccRewardPerWeightedAsset() external view returns (uint256) {
        return sAccRewardPerWeightedAsset;
    }

    function getCurrentRewardRate() external view returns (uint256) {
        return sCurrentRewardRate;
    }

    function getTotalReservedRewards() external view returns (uint256) {
        return sTotalReservedRewards;
    }

    function getUndistributedRewards() external view returns (uint256) {
        return sUndistributedRewards;
    }

    function getPendingClaimableRewards(
        address account
    ) public view returns (uint256) {
        UserPosition memory user = sUserPositions[account];
        uint256 acc = _previewAccRewardPerWeightedAsset();

        uint256 accrued = 0;
        if (user.weightedAssets > 0) {
            accrued = (user.weightedAssets * acc) / PRECISION - user.rewardDebt;
        }

        return user.pendingRewards + accrued;
    }

    function getCurrentMultiplierBps(
        address account
    ) external view returns (uint256) {
        UserPosition memory user = sUserPositions[account];
        uint256 claimable = getPendingClaimableRewards(account);
        return
            _determineMultiplierBps(
                uint256(user.weightedTimestamp),
                user.principalAssets,
                claimable
            );
    }

    function previewClaimRewards(
        address account
    ) external view returns (uint256) {
        return getPendingClaimableRewards(account);
    }

    /**
     * @notice Owner can approve a reward manager that is allowed to inject reward streams.
     */
    function approveRewardManager(
        address rewardManager
    ) external onlyOwner nonZeroAddress(rewardManager) nonReentrant {
        if (sRewardManagers.add(rewardManager)) {
            emit RewardManagerApproved(rewardManager, block.timestamp);
        }
    }

    /**
     * @notice Owner can revoke a reward manager.
     */
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
     * @notice Adds IS21 reward tokens and creates a new linear reward stream.
     * @param totalAmount Total IS21 supplied by the reward manager.
     * @param duration Duration over which the 88% staker portion vests.
     *
     * @dev Split:
     * - 10% treasury (transferred immediately)
     * - 2% stability reserve (transferred immediately)
     * - 88% reserved for stakers and streamed linearly
     *
     * Multiple reward additions can overlap; the vault aggregates active reward rates and schedules
     * a rate decrease at each stream end.
     */
    function addRewards(
        uint256 totalAmount,
        uint256 duration
    )
        external
        onlyRewardManager
        moreThanZero(totalAmount)
        nonReentrant
        whenNotPaused
    {
        if (duration == 0) {
            revert IS21StakingVault__InvalidDuration();
        }

        if (treasuryWallet == address(0) || stabilityWallet == address(0)) {
            revert IS21StakingVault__RewardAddressesNotConfigured();
        }

        if (sTotalWeightedAssets == 0) {
            revert IS21StakingVault__NoActiveStakers();
        }

        _accrueGlobal();

        IERC20 assetToken = IERC20(asset());
        assetToken.safeTransferFrom(msg.sender, address(this), totalAmount);

        uint256 treasuryAmount = (totalAmount * TREASURY_BPS) / BPS;
        uint256 reserveAmount = (totalAmount * STABILITY_RESERVE_BPS) / BPS;
        uint256 stakerAmount = totalAmount - treasuryAmount - reserveAmount;

        uint256 rewardRate = (stakerAmount * PRECISION) / duration;

        if (stakerAmount == 0 || rewardRate == 0) {
            revert IS21StakingVault__InvalidDuration();
        }

        if (treasuryAmount > 0) {
            assetToken.safeTransfer(treasuryWallet, treasuryAmount);
        }
        if (reserveAmount > 0) {
            assetToken.safeTransfer(stabilityWallet, reserveAmount);
        }

        sTotalReservedRewards += stakerAmount;

        uint256 endTime = block.timestamp + duration;

        sCurrentRewardRate += rewardRate;
        sRateDecreaseAtTime[endTime] += rewardRate;
        _insertRateChangeTime(endTime);

        emit RewardsAdded(
            msg.sender,
            totalAmount,
            treasuryAmount,
            reserveAmount,
            stakerAmount,
            duration,
            block.timestamp,
            endTime
        );
    }

    /**
     * @notice Claim all currently claimable IS21 rewards.
     */
    function claimRewards()
        external
        nonReentrant
        whenNotPaused
        returns (uint256 claimed)
    {
        return _claimRewardsTo(msg.sender);
    }

    function claimRewardsTo(
        address receiver
    ) external nonReentrant whenNotPaused returns (uint256) {
        return _claimRewardsTo(receiver);
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
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /**
     * @notice Rescue tokens accidentally sent to the contract, but never principal-backed assets
     *         or reserved staker rewards.
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
                revert IS21StakingVault__InsufficientFreeBalanceForRescue();
            }
        }

        IERC20(token).safeTransfer(to, amount);
    }

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
            revert IS21StakingVault__InsufficientUndistributedRewards();
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
            revert IS21StakingVault__CannotTransferToSelf();
        }

        if (!_isEmptyPosition(to)) {
            revert IS21StakingVault__ReceiverMustBeEmpty();
        }

        uint256 sharesToMove = balanceOf(msg.sender);
        if (sharesToMove == 0) {
            revert IS21StakingVault__AmountMustBeMoreThanZero();
        }

        _accrueGlobal();
        _settleAndRefreshUser(msg.sender);

        UserPosition storage sender = sUserPositions[msg.sender];
        UserPosition storage receiver = sUserPositions[to];

        uint256 principalToMove = sender.principalAssets;
        uint256 weightedToMove = sender.weightedAssets;
        uint256 rewardDebtToMove = sender.rewardDebt;
        uint256 pendingRewardsToMove = sender.pendingRewards;
        uint64 weightedTimestampToMove = sender.weightedTimestamp;

        // Move the ERC4626 shares using a controlled bypass.
        sPositionTransferInProgress = true;
        _transfer(msg.sender, to, sharesToMove);
        sPositionTransferInProgress = false;

        // Copy the full economic position to the new wallet.
        receiver.principalAssets = principalToMove;
        receiver.weightedAssets = weightedToMove;
        receiver.rewardDebt = rewardDebtToMove;
        receiver.pendingRewards = pendingRewardsToMove;
        receiver.weightedTimestamp = weightedTimestampToMove;

        // Treat the migration as a fresh "deposit block" on the receiver
        // so the receiver cannot instantly withdraw/claim in the same block.
        receiver.lastDepositBlock = uint64(block.number);
        receiver.lastWithdrawBlock = 0;

        // Clear the sender position.
        delete sUserPositions[msg.sender];

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
        revert IS21StakingVault__ETHNotAccepted();
    }

    fallback() external payable {
        revert IS21StakingVault__ETHNotAccepted();
    }

    ////////////////////////////////////
    // ERC4626 Overrides / Internals  //
    ////////////////////////////////////

    /**
     * @notice Claim all currently claimable IS21 rewards to a chosen receiver.
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
            revert IS21StakingVault__SameBlockClaimNotAllowed();
        }

        _accrueGlobal();
        _settleAndRefreshUser(msg.sender);

        claimed = user.pendingRewards;
        if (claimed == 0) {
            revert IS21StakingVault__InsufficientClaimableRewards();
        }

        user.pendingRewards = 0;

        sTotalReservedRewards -= claimed;

        // Claim changes the 100k threshold logic, so refresh future weight after rewards leave.
        _refreshUserWeight(msg.sender);

        IERC20(asset()).safeTransfer(receiver, claimed);

        emit RewardsClaimed(msg.sender, receiver, claimed, block.timestamp);
    }

    /**
     * @dev Hook reward accounting around ERC4626 deposit flow.
     *
     * Receiver gets:
     * - principal increase
     * - weighted-average timestamp refresh
     * - refreshed future reward weight
     *
     * Same-block claim / withdraw protection uses receiver state.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        _accrueGlobal();
        _settleAndRefreshUser(receiver);

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

        _refreshUserWeight(receiver);

        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Hook reward accounting around ERC4626 withdraw/redeem flow.
     *
     * Owner is the economic owner whose principal and loyalty state must be updated.
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
            revert IS21StakingVault__SameBlockWithdrawNotAllowed();
        }

        _accrueGlobal();
        _settleAndRefreshUser(owner_);

        user.principalAssets -= assets;
        user.lastWithdrawBlock = uint64(block.number);

        if (user.principalAssets == 0) {
            user.weightedTimestamp = 0;
        }

        sTotalPrincipalAssets -= assets;

        _refreshUserWeight(owner_);

        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /**
     * @dev Prevent user-to-user transfer of vault shares.
     *      Only mint (from == 0) and burn (to == 0) are allowed.
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
            revert IS21StakingVault__ShareTransfersDisabled();
        }

        super._update(from, to, value);
    }

    ////////////////////////////////////
    //  Reward Accounting Internals   //
    ////////////////////////////////////

    function _insertRateChangeTime(uint256 endTime) internal {
        if (sRateChangeTimeExists[endTime]) return;

        sRateChangeTimeExists[endTime] = true;

        uint256 length = sRewardRateChangeTimes.length;
        sRewardRateChangeTimes.push(endTime);

        uint256 i = length;
        while (i > 0 && sRewardRateChangeTimes[i - 1] > endTime) {
            sRewardRateChangeTimes[i] = sRewardRateChangeTimes[i - 1];
            unchecked {
                --i;
            }
        }
        sRewardRateChangeTimes[i] = endTime;
    }

    /**
     * @dev Accrues global reward state up to block.timestamp by walking across any reward-rate
     *      change boundaries caused by completed reward streams.
     */
    function _accrueGlobal() internal {
        uint256 currentTime = block.timestamp;
        uint256 lastTime = sLastRewardUpdate;

        if (currentTime <= lastTime) {
            return;
        }

        uint256 currentRate = sCurrentRewardRate;
        uint256 acc = sAccRewardPerWeightedAsset;
        uint256 totalWeighted = sTotalWeightedAssets;
        uint256 index = sNextRateChangeIndex;
        uint256 length = sRewardRateChangeTimes.length;

        while (index < length) {
            uint256 changeTime = sRewardRateChangeTimes[index];
            if (changeTime > currentTime) {
                break;
            }

            if (changeTime > lastTime && currentRate > 0) {
                uint256 elapsed = changeTime - lastTime;
                uint256 emitted = (elapsed * currentRate) / PRECISION;

                if (totalWeighted > 0) {
                    acc += (elapsed * currentRate) / totalWeighted;
                } else {
                    sUndistributedRewards += emitted;
                    sTotalReservedRewards -= emitted;
                }
            }

            lastTime = changeTime;
            currentRate -= sRateDecreaseAtTime[changeTime];
            unchecked {
                ++index;
            }
        }

        if (currentTime > lastTime && currentRate > 0) {
            uint256 elapsedFinal = currentTime - lastTime;
            uint256 emittedFinal = (elapsedFinal * currentRate) / PRECISION;

            if (totalWeighted > 0) {
                acc += (elapsedFinal * currentRate) / totalWeighted;
            } else {
                sUndistributedRewards += emittedFinal;
                sTotalReservedRewards -= emittedFinal;
            }
        }

        sAccRewardPerWeightedAsset = acc;
        sCurrentRewardRate = currentRate;
        sLastRewardUpdate = currentTime;
        sNextRateChangeIndex = index;
    }

    /**
     * @dev Settles accrued rewards into user.pendingRewards, then refreshes their future reward weight.
     */
    function _settleAndRefreshUser(address account) internal {
        UserPosition storage user = sUserPositions[account];

        if (user.weightedAssets > 0) {
            uint256 accumulated = (user.weightedAssets *
                sAccRewardPerWeightedAsset) / PRECISION;
            uint256 accrued = accumulated - user.rewardDebt;
            if (accrued > 0) {
                user.pendingRewards += accrued;
            }
        }

        _refreshUserWeight(account);
    }

    /**
     * @dev Recomputes the user's weightedAssets using:
     *      principal only * multiplier
     *      where multiplier may depend on principal + unclaimed rewards for the 100k threshold rule.
     */
    function _refreshUserWeight(address account) internal {
        UserPosition storage user = sUserPositions[account];

        uint256 oldWeightedAssets = user.weightedAssets;
        uint256 multiplierBps = _determineMultiplierBps(
            uint256(user.weightedTimestamp),
            user.principalAssets,
            user.pendingRewards
        );

        uint256 newWeightedAssets = (user.principalAssets * multiplierBps) /
            BPS;

        if (newWeightedAssets != oldWeightedAssets) {
            sTotalWeightedAssets =
                sTotalWeightedAssets -
                oldWeightedAssets +
                newWeightedAssets;
            user.weightedAssets = newWeightedAssets;
        }

        user.rewardDebt =
            (user.weightedAssets * sAccRewardPerWeightedAsset) /
            PRECISION;
    }

    /**
     * @dev Multiplier rules:
     * - Immediate 2x if principal + unclaimed rewards >= 100k IS21
     * - otherwise age based:
     *   - <31 days => 1x
     *   - 31-90 days => 1.5x
     *   - >90 days => 2x
     */
    function _determineMultiplierBps(
        uint256 weightedTimestamp,
        uint256 principalAssets,
        uint256 pendingRewards
    ) internal view returns (uint256) {
        if (principalAssets == 0) {
            return 0;
        }

        if (principalAssets + pendingRewards >= THRESHOLD_2X) {
            return MULTIPLIER_2X;
        }

        uint256 age = 0;
        if (weightedTimestamp > 0 && block.timestamp > weightedTimestamp) {
            age = block.timestamp - weightedTimestamp;
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
     * @dev View-only version of the global accumulator for preview functions.
     */
    function _previewAccRewardPerWeightedAsset()
        internal
        view
        returns (uint256)
    {
        uint256 currentTime = block.timestamp;
        uint256 lastTime = sLastRewardUpdate;

        if (currentTime <= lastTime) {
            return sAccRewardPerWeightedAsset;
        }

        uint256 currentRate = sCurrentRewardRate;
        uint256 acc = sAccRewardPerWeightedAsset;
        uint256 totalWeighted = sTotalWeightedAssets;
        uint256 index = sNextRateChangeIndex;
        uint256 length = sRewardRateChangeTimes.length;

        while (index < length) {
            uint256 changeTime = sRewardRateChangeTimes[index];
            if (changeTime > currentTime) {
                break;
            }

            if (changeTime > lastTime && currentRate > 0) {
                uint256 elapsed = changeTime - lastTime;

                if (totalWeighted > 0) {
                    acc += (elapsed * currentRate) / totalWeighted;
                }
            }

            lastTime = changeTime;
            currentRate -= sRateDecreaseAtTime[changeTime];
            unchecked {
                ++index;
            }
        }

        if (currentTime > lastTime && currentRate > 0) {
            uint256 elapsedFinal = currentTime - lastTime;

            if (totalWeighted > 0) {
                acc += (elapsedFinal * currentRate) / totalWeighted;
            }
        }

        return acc;
    }

    function _isEmptyPosition(address account) internal view returns (bool) {
        UserPosition memory user = sUserPositions[account];

        return
            balanceOf(account) == 0 &&
            user.principalAssets == 0 &&
            user.weightedAssets == 0 &&
            user.rewardDebt == 0 &&
            user.pendingRewards == 0 &&
            user.weightedTimestamp == 0;
    }
}
