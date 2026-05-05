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
 * @title IS21InstitutionalRewardVault
 * @author InterShare Team
 *
 * @notice Institutional ERC4626 staking vault for IS21.
 *
 * @dev Core model:
 * - Asset = IS21.
 * - Vault share token = isIS21, Institutional Staked InterShare21.
 * - Institutions are whitelisted before they may deposit or mint.
 * - This is a pure shares-based vault: streamed rewards increase ERC4626 share price over time.
 * - No loyalty multipliers.
 * - No manual claim function.
 * - No manual compound function.
 * - Reward managers add IS21 rewards into a scheduled stream.
 * - Reward split:
 *   - 10% treasury
 *   - 2% stability reserve
 *   - 88% institutional vault rewards
 * - Institutional rewards stay in the vault but are excluded from totalAssets() until vested by epoch.
 * - Minimum position threshold is configurable, default 150,000 IS21.
 * - Withdrawal penalty period is configurable, default 30 days.
 * - If a partial withdrawal would leave the institution below the minimum position,
 *   the transaction reverts and the institution must fully exit instead.
 * - Shares are non-transferable except for controlled full-position transfers.
 * - Each institution's net principal is tracked for frontend profitability reporting.
 *
 * @dev Reward streaming model:
 * - EPOCH_DURATION = 1 hour.
 * - Only one active reward stream exists at a time.
 * - When new rewards are added, remaining unvested scheduled rewards are rolled into the new stream.
 * - totalAssets() excludes remaining scheduled rewards so unvested rewards do not affect share price.
 * - As epochs pass, scheduled rewards become vested automatically because remainingScheduledRewards falls.
 *
 * @dev Penalty model:
 * - Penalty applies only to withdrawals/redeems before the user's weighted deposit age
 *   reaches the configured penalty period.
 * - Penalty is charged on withdrawn assets and sent to the stability reserve wallet.
 * - The default penalty rate is 0 bps. This lets the penalty period exist as a configurable
 *   restriction window without taking funds unless a fund manager configures a penalty rate.
 * - Fund managers may configure both the penalty period and penalty bps.
 */
contract IS21InstitutionalRewardVault is
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
    error IS21InstitutionalRewardVault__AmountMustBeMoreThanZero();
    error IS21InstitutionalRewardVault__ZeroAddressNotAllowed();
    error IS21InstitutionalRewardVault__ETHNotAccepted();
    error IS21InstitutionalRewardVault__CannotSendToContract();
    error IS21InstitutionalRewardVault__OnlyFundManagerCanExecute();
    error IS21InstitutionalRewardVault__OnlyRewardManagerCanExecute();
    error IS21InstitutionalRewardVault__InstitutionNotWhitelisted();
    error IS21InstitutionalRewardVault__MinimumDepositNotMet();
    error IS21InstitutionalRewardVault__RemainingBalanceBelowMinimum();
    error IS21InstitutionalRewardVault__InvalidBps();
    error IS21InstitutionalRewardVault__InvalidEpochCount();
    error IS21InstitutionalRewardVault__RewardAddressesNotConfigured();
    error IS21InstitutionalRewardVault__InsufficientFreeBalanceForRescue();
    error IS21InstitutionalRewardVault__ShareTransfersDisabled();
    error IS21InstitutionalRewardVault__ReceiverMustBeEmpty();
    error IS21InstitutionalRewardVault__CannotTransferToSelf();
    error IS21InstitutionalRewardVault__NoActiveInstitutionShares();
    error IS21InstitutionalRewardVault__SameBlockWithdrawNotAllowed();

    /////////////////////
    // State Variables //
    /////////////////////
    string public constant IS21_INSTITUTIONAL_VAULT_VERSION = "1.0.0";

    uint256 private constant BPS = 10_000;
    uint256 private constant TREASURY_BPS = 1_000; // 10%
    uint256 private constant STABILITY_RESERVE_BPS = 200; // 2%
    uint256 private constant DEFAULT_MINIMUM_POSITION = 150_000 ether;
    uint256 private constant DEFAULT_WITHDRAWAL_PENALTY_PERIOD = 30 days;
    uint64 private constant EPOCH_DURATION = 1 hours;

    uint64 private immutable EPOCH_ZERO_TIMESTAMP;

    struct InstitutionPosition {
        uint256 principalDeposited; // Net principal after proportional withdrawal reductions
        uint256 currentAssets; // Current ERC4626 asset value before withdrawal penalties
        int256 unrealizedProfitLoss; // currentAssets - principalDeposited
        uint256 shareBalance;
        uint64 weightedDepositTimestamp;
        uint64 lastDepositBlock;
        bool whitelisted;
        bool withinPenaltyPeriod;
    }

    struct RewardStream {
        uint64 startEpoch; // inclusive
        uint64 endEpoch; // exclusive
        uint256 rewardPerEpoch;
        uint256 firstEpochBonus;
    }

    EnumerableSet.AddressSet private sFundManagers;
    EnumerableSet.AddressSet private sRewardManagers;
    EnumerableSet.AddressSet private sWhitelistedInstitutions;

    mapping(address => uint256) private sPrincipalDeposited;
    mapping(address => uint64) private sWeightedDepositTimestamp;
    mapping(address => uint64) private sLastDepositBlock;

    RewardStream private sRewardStream;

    bool private sPositionTransferInProgress;

    address private treasuryWallet;
    address private stabilityWallet;

    uint256 private sMinimumPositionAssets;
    uint256 private sWithdrawalPenaltyPeriod;
    uint256 private sWithdrawalPenaltyBps; // 10 bps = 0.1%, 500 bps = 5.0%

    ////////////
    // Events //
    ////////////
    event FundManagerApproved(address indexed fundManager, uint256 timestamp);
    event FundManagerRevoked(address indexed fundManager, uint256 timestamp);

    event RewardManagerApproved(
        address indexed rewardManager,
        uint256 timestamp
    );
    event RewardManagerRevoked(
        address indexed rewardManager,
        uint256 timestamp
    );

    event InstitutionWhitelisted(
        address indexed institution,
        uint256 timestamp
    );
    event InstitutionRemoved(address indexed institution, uint256 timestamp);

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

    event MinimumPositionUpdated(
        uint256 oldMinimumPosition,
        uint256 newMinimumPosition,
        uint256 timestamp
    );
    event WithdrawalPenaltyPeriodUpdated(
        uint256 oldPeriod,
        uint256 newPeriod,
        uint256 timestamp
    );
    event WithdrawalPenaltyBpsUpdated(
        uint256 oldPenaltyBps,
        uint256 newPenaltyBps,
        uint256 timestamp
    );

    event RewardStreamConfigured(
        uint64 indexed startEpoch,
        uint64 indexed endEpoch,
        uint256 rewardPerEpoch,
        uint256 firstEpochBonus,
        uint256 timestamp
    );

    event RewardsAdded(
        address indexed rewardManager,
        uint256 totalAmount,
        uint256 treasuryAmount,
        uint256 stabilityReserveAmount,
        uint256 vaultRewardAmount,
        uint64 epochCount,
        uint64 startEpoch,
        uint64 endEpoch,
        uint256 rolledLeftover,
        uint256 timestamp
    );

    event PrincipalUpdated(
        address indexed account,
        uint256 oldPrincipal,
        uint256 newPrincipal,
        uint256 timestamp
    );

    event WithdrawalPenaltyPaid(
        address indexed account,
        address indexed receiver,
        uint256 grossAssets,
        uint256 penaltyAmount,
        uint256 netAssets,
        uint256 timestamp
    );

    event FullPositionTransferred(
        address indexed from,
        address indexed to,
        uint256 shares,
        uint256 principalDeposited,
        uint64 weightedDepositTimestamp,
        uint256 timestamp
    );

    event ContractPaused(address indexed caller, uint256 timestamp);
    event ContractUnpaused(address indexed caller, uint256 timestamp);

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert IS21InstitutionalRewardVault__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier nonZeroAddress(address account) {
        if (account == address(0)) {
            revert IS21InstitutionalRewardVault__ZeroAddressNotAllowed();
        }
        _;
    }

    modifier onlyFundManager() {
        if (!sFundManagers.contains(msg.sender)) {
            revert IS21InstitutionalRewardVault__OnlyFundManagerCanExecute();
        }
        _;
    }

    modifier onlyRewardManager() {
        if (!sRewardManagers.contains(msg.sender)) {
            revert IS21InstitutionalRewardVault__OnlyRewardManagerCanExecute();
        }
        _;
    }

    modifier onlyWhitelistedInstitution(address account) {
        if (!sWhitelistedInstitutions.contains(account)) {
            revert IS21InstitutionalRewardVault__InstitutionNotWhitelisted();
        }
        _;
    }

    modifier cannotSendToContract(address to) {
        if (to == address(this)) {
            revert IS21InstitutionalRewardVault__CannotSendToContract();
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
        ERC20("Institutional Staked InterShare21", "isIS21")
        ERC20Permit("Institutional Staked InterShare21")
        Ownable(ownerAddress)
    {
        if (
            is21Token == address(0) ||
            ownerAddress == address(0) ||
            treasuryAddress == address(0) ||
            stabilityReserveAddress == address(0)
        ) {
            revert IS21InstitutionalRewardVault__ZeroAddressNotAllowed();
        }

        treasuryWallet = treasuryAddress;
        stabilityWallet = stabilityReserveAddress;
        sMinimumPositionAssets = DEFAULT_MINIMUM_POSITION;
        sWithdrawalPenaltyPeriod = DEFAULT_WITHDRAWAL_PENALTY_PERIOD;
        sWithdrawalPenaltyBps = 0;
        EPOCH_ZERO_TIMESTAMP = uint64(block.timestamp);
    }

    ////////////////////////////////////
    // External/Public View Functions //
    ////////////////////////////////////
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function getVersion() external pure returns (string memory) {
        return IS21_INSTITUTIONAL_VAULT_VERSION;
    }

    /**
     * @notice ERC4626 assets that are currently vested and owned by shareholders.
     * @dev Unvested scheduled rewards are physically in the vault but excluded until streamed.
     */
    function totalAssets() public view override returns (uint256) {
        uint256 currentBalance = IERC20(asset()).balanceOf(address(this));
        uint256 unvestedRewards = getRemainingScheduledRewards();

        if (unvestedRewards >= currentBalance) {
            return 0;
        }

        return currentBalance - unvestedRewards;
    }

    function getTreasuryAddress() external view returns (address) {
        return treasuryWallet;
    }

    function getStabilityReserveAddress() external view returns (address) {
        return stabilityWallet;
    }

    function getMinimumPositionAssets() external view returns (uint256) {
        return sMinimumPositionAssets;
    }

    function getWithdrawalPenaltyPeriod() external view returns (uint256) {
        return sWithdrawalPenaltyPeriod;
    }

    function getWithdrawalPenaltyBps() external view returns (uint256) {
        return sWithdrawalPenaltyBps;
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

    function getRewardStream() external view returns (RewardStream memory) {
        return sRewardStream;
    }

    function getRemainingScheduledRewards() public view returns (uint256) {
        return _remainingScheduledRewards(_currentEpoch());
    }

    function getVestedVaultRewards() external view returns (uint256) {
        uint256 currentBalance = IERC20(asset()).balanceOf(address(this));
        uint256 unvestedRewards = getRemainingScheduledRewards();

        if (unvestedRewards >= currentBalance) {
            return 0;
        }

        uint256 shareholderAssets = currentBalance - unvestedRewards;
        uint256 totalPrincipal = _totalPrincipalDepositedBestEffort();

        if (shareholderAssets <= totalPrincipal) {
            return 0;
        }

        return shareholderAssets - totalPrincipal;
    }

    function getFundManagers() external view returns (address[] memory) {
        return sFundManagers.values();
    }

    function isFundManager(address account) external view returns (bool) {
        return sFundManagers.contains(account);
    }

    function getRewardManagers() external view returns (address[] memory) {
        return sRewardManagers.values();
    }

    function isRewardManager(address account) external view returns (bool) {
        return sRewardManagers.contains(account);
    }

    function getWhitelistedInstitutions()
        external
        view
        returns (address[] memory)
    {
        return sWhitelistedInstitutions.values();
    }

    function isInstitutionWhitelisted(
        address account
    ) external view returns (bool) {
        return sWhitelistedInstitutions.contains(account);
    }

    function getPrincipalDeposited(
        address account
    ) external view returns (uint256) {
        return sPrincipalDeposited[account];
    }

    function getCurrentPositionAssets(
        address account
    ) public view returns (uint256) {
        return convertToAssets(balanceOf(account));
    }

    function getUnrealizedProfitLoss(
        address account
    ) public view returns (int256) {
        uint256 currentAssets = getCurrentPositionAssets(account);
        uint256 principal = sPrincipalDeposited[account];

        if (currentAssets >= principal) {
            return int256(currentAssets - principal);
        }

        return -int256(principal - currentAssets);
    }

    function getWeightedDepositTimestamp(
        address account
    ) external view returns (uint64) {
        return sWeightedDepositTimestamp[account];
    }

    function getLastDepositBlock(
        address account
    ) external view returns (uint64) {
        return sLastDepositBlock[account];
    }

    function getInstitutionPosition(
        address account
    ) external view returns (InstitutionPosition memory) {
        return
            InstitutionPosition({
                principalDeposited: sPrincipalDeposited[account],
                currentAssets: getCurrentPositionAssets(account),
                unrealizedProfitLoss: getUnrealizedProfitLoss(account),
                shareBalance: balanceOf(account),
                weightedDepositTimestamp: sWeightedDepositTimestamp[account],
                lastDepositBlock: sLastDepositBlock[account],
                whitelisted: sWhitelistedInstitutions.contains(account),
                withinPenaltyPeriod: isWithinPenaltyPeriod(account)
            });
    }

    function isWithinPenaltyPeriod(address account) public view returns (bool) {
        uint64 weightedTimestamp = sWeightedDepositTimestamp[account];
        if (weightedTimestamp == 0) return false;
        return
            block.timestamp <
            uint256(weightedTimestamp) + sWithdrawalPenaltyPeriod;
    }

    function previewWithdrawalPenalty(
        address account,
        uint256 grossAssets
    ) public view returns (uint256) {
        if (!isWithinPenaltyPeriod(account)) return 0;
        return (grossAssets * sWithdrawalPenaltyBps) / BPS;
    }

    function previewNetWithdrawAssets(
        address account,
        uint256 grossAssets
    ) external view returns (uint256) {
        return grossAssets - previewWithdrawalPenalty(account, grossAssets);
    }

    function maxDeposit(
        address receiver
    ) public view override returns (uint256) {
        if (paused()) return 0;
        if (!sWhitelistedInstitutions.contains(receiver)) return 0;
        return type(uint256).max;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        if (!sWhitelistedInstitutions.contains(receiver)) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(
        address owner_
    ) public view override returns (uint256) {
        if (paused()) return 0;
        if (sLastDepositBlock[owner_] == uint64(block.number)) return 0;
        return convertToAssets(balanceOf(owner_));
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (sLastDepositBlock[owner_] == uint64(block.number)) return 0;
        return balanceOf(owner_);
    }

    /////////////////////////////////////
    // External/Public Write Functions //
    /////////////////////////////////////
    function approveFundManager(
        address fundManager
    ) external onlyOwner nonZeroAddress(fundManager) nonReentrant {
        if (sFundManagers.add(fundManager)) {
            emit FundManagerApproved(fundManager, block.timestamp);
        }
    }

    function revokeFundManager(
        address fundManager
    ) external onlyOwner nonZeroAddress(fundManager) nonReentrant {
        if (sFundManagers.remove(fundManager)) {
            emit FundManagerRevoked(fundManager, block.timestamp);
        }
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

    function whitelistInstitution(
        address institution
    ) external onlyFundManager nonZeroAddress(institution) nonReentrant {
        if (sWhitelistedInstitutions.add(institution)) {
            emit InstitutionWhitelisted(institution, block.timestamp);
        }
    }

    function whitelistInstitutions(
        address[] calldata institutions
    ) external onlyFundManager nonReentrant {
        for (uint256 i = 0; i < institutions.length; ) {
            address institution = institutions[i];
            if (institution == address(0)) {
                revert IS21InstitutionalRewardVault__ZeroAddressNotAllowed();
            }

            if (sWhitelistedInstitutions.add(institution)) {
                emit InstitutionWhitelisted(institution, block.timestamp);
            }

            unchecked {
                ++i;
            }
        }
    }

    function removeInstitution(
        address institution
    ) external onlyFundManager nonZeroAddress(institution) nonReentrant {
        if (sWhitelistedInstitutions.remove(institution)) {
            emit InstitutionRemoved(institution, block.timestamp);
        }
    }

    function removeInstitutions(
        address[] calldata institutions
    ) external onlyFundManager nonReentrant {
        for (uint256 i = 0; i < institutions.length; ) {
            address institution = institutions[i];
            if (institution == address(0)) {
                revert IS21InstitutionalRewardVault__ZeroAddressNotAllowed();
            }

            if (sWhitelistedInstitutions.remove(institution)) {
                emit InstitutionRemoved(institution, block.timestamp);
            }

            unchecked {
                ++i;
            }
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

    function setMinimumPositionAssets(
        uint256 newMinimumPositionAssets
    )
        external
        onlyFundManager
        moreThanZero(newMinimumPositionAssets)
        nonReentrant
    {
        uint256 oldMinimumPosition = sMinimumPositionAssets;
        sMinimumPositionAssets = newMinimumPositionAssets;
        emit MinimumPositionUpdated(
            oldMinimumPosition,
            newMinimumPositionAssets,
            block.timestamp
        );
    }

    function setWithdrawalPenaltyPeriod(
        uint256 newPenaltyPeriod
    ) external onlyFundManager nonReentrant {
        uint256 oldPenaltyPeriod = sWithdrawalPenaltyPeriod;
        sWithdrawalPenaltyPeriod = newPenaltyPeriod;
        emit WithdrawalPenaltyPeriodUpdated(
            oldPenaltyPeriod,
            newPenaltyPeriod,
            block.timestamp
        );
    }

    function setWithdrawalPenaltyBps(
        uint256 newPenaltyBps
    ) external onlyFundManager nonReentrant {
        if (newPenaltyBps > BPS) {
            revert IS21InstitutionalRewardVault__InvalidBps();
        }

        uint256 oldPenaltyBps = sWithdrawalPenaltyBps;
        sWithdrawalPenaltyBps = newPenaltyBps;
        emit WithdrawalPenaltyBpsUpdated(
            oldPenaltyBps,
            newPenaltyBps,
            block.timestamp
        );
    }

    /**
     * @notice Adds IS21 rewards to the institutional vault and streams the vault portion over epochs.
     * @param totalAmount Total IS21 supplied by the reward manager.
     * @param epochCount Number of 1-hour epochs over which the 88% vault reward amount is streamed.
     *
     * @dev Existing unvested scheduled rewards are rolled into the new stream.
     * @dev Reverts when there are no shares outstanding to avoid ambiguous reward ownership.
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
            revert IS21InstitutionalRewardVault__InvalidEpochCount();
        }

        if (treasuryWallet == address(0) || stabilityWallet == address(0)) {
            revert IS21InstitutionalRewardVault__RewardAddressesNotConfigured();
        }

        if (totalSupply() == 0) {
            revert IS21InstitutionalRewardVault__NoActiveInstitutionShares();
        }

        IERC20 assetToken = IERC20(asset());
        assetToken.safeTransferFrom(msg.sender, address(this), totalAmount);

        uint256 treasuryAmount = (totalAmount * TREASURY_BPS) / BPS;
        uint256 reserveAmount = (totalAmount * STABILITY_RESERVE_BPS) / BPS;
        uint256 vaultRewardAmount = totalAmount -
            treasuryAmount -
            reserveAmount;

        if (treasuryAmount > 0) {
            assetToken.safeTransfer(treasuryWallet, treasuryAmount);
        }

        if (reserveAmount > 0) {
            assetToken.safeTransfer(stabilityWallet, reserveAmount);
        }

        uint64 currentEpoch = _currentEpoch();
        uint256 leftover = _remainingScheduledRewards(currentEpoch);
        uint256 totalForNewStream = leftover + vaultRewardAmount;

        if (totalForNewStream == 0) {
            revert IS21InstitutionalRewardVault__AmountMustBeMoreThanZero();
        }

        uint256 rewardPerEpoch = totalForNewStream / epochCount;
        uint256 firstEpochBonus = totalForNewStream % epochCount;

        sRewardStream = RewardStream({
            startEpoch: currentEpoch,
            endEpoch: currentEpoch + epochCount,
            rewardPerEpoch: rewardPerEpoch,
            firstEpochBonus: firstEpochBonus
        });

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
            vaultRewardAmount,
            epochCount,
            currentEpoch,
            currentEpoch + epochCount,
            leftover,
            block.timestamp
        );
    }

    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override
        nonReentrant
        whenNotPaused
        onlyWhitelistedInstitution(receiver)
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    )
        public
        override
        nonReentrant
        whenNotPaused
        onlyWhitelistedInstitution(receiver)
        returns (uint256)
    {
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
     * @notice Rescue tokens accidentally sent to the contract, but never underlying IS21 assets backing shares or unvested rewards.
     */
    function rescueErc20(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner nonZeroAddress(token) nonZeroAddress(to) nonReentrant {
        if (token == asset()) {
            uint256 requiredBalance = totalAssets() +
                getRemainingScheduledRewards();
            uint256 currentBalance = IERC20(token).balanceOf(address(this));
            uint256 freeBalance = currentBalance > requiredBalance
                ? currentBalance - requiredBalance
                : 0;

            if (amount > freeBalance) {
                revert IS21InstitutionalRewardVault__InsufficientFreeBalanceForRescue();
            }
        }

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Transfer a full institutional staking position to another whitelisted empty wallet.
     * @dev Useful if an institution changes custody wallet.
     */
    function transferFullPosition(
        address to
    )
        external
        nonReentrant
        whenNotPaused
        nonZeroAddress(to)
        cannotSendToContract(to)
        onlyWhitelistedInstitution(to)
    {
        if (to == msg.sender) {
            revert IS21InstitutionalRewardVault__CannotTransferToSelf();
        }

        if (!_isEmptyPosition(to)) {
            revert IS21InstitutionalRewardVault__ReceiverMustBeEmpty();
        }

        uint256 sharesToMove = balanceOf(msg.sender);
        if (sharesToMove == 0) {
            revert IS21InstitutionalRewardVault__AmountMustBeMoreThanZero();
        }

        uint256 principalToMove = sPrincipalDeposited[msg.sender];
        uint64 weightedTimestampToMove = sWeightedDepositTimestamp[msg.sender];

        sPositionTransferInProgress = true;
        _transfer(msg.sender, to, sharesToMove);
        sPositionTransferInProgress = false;

        sPrincipalDeposited[to] = principalToMove;
        sWeightedDepositTimestamp[to] = weightedTimestampToMove;
        sLastDepositBlock[to] = uint64(block.number);

        delete sPrincipalDeposited[msg.sender];
        delete sWeightedDepositTimestamp[msg.sender];
        delete sLastDepositBlock[msg.sender];

        emit FullPositionTransferred(
            msg.sender,
            to,
            sharesToMove,
            principalToMove,
            weightedTimestampToMove,
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
        revert IS21InstitutionalRewardVault__ETHNotAccepted();
    }

    fallback() external payable {
        revert IS21InstitutionalRewardVault__ETHNotAccepted();
    }

    ////////////////////////////////////
    // ERC4626 Overrides / Internals  //
    ////////////////////////////////////
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        if (assets < sMinimumPositionAssets && balanceOf(receiver) == 0) {
            revert IS21InstitutionalRewardVault__MinimumDepositNotMet();
        }

        uint256 oldAssets = convertToAssets(balanceOf(receiver));
        uint256 newAssets = oldAssets + assets;

        if (newAssets < sMinimumPositionAssets) {
            revert IS21InstitutionalRewardVault__MinimumDepositNotMet();
        }

        uint64 oldWeightedTimestamp = sWeightedDepositTimestamp[receiver];

        if (oldAssets == 0 || oldWeightedTimestamp == 0) {
            sWeightedDepositTimestamp[receiver] = uint64(block.timestamp);
        } else {
            uint256 newWeightedTimestamp = ((oldAssets *
                uint256(oldWeightedTimestamp)) + (assets * block.timestamp)) /
                newAssets;
            sWeightedDepositTimestamp[receiver] = uint64(newWeightedTimestamp);
        }

        uint256 oldPrincipal = sPrincipalDeposited[receiver];
        uint256 newPrincipal = oldPrincipal + assets;
        sPrincipalDeposited[receiver] = newPrincipal;

        sLastDepositBlock[receiver] = uint64(block.number);

        emit PrincipalUpdated(
            receiver,
            oldPrincipal,
            newPrincipal,
            block.timestamp
        );

        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        if (sLastDepositBlock[owner_] == uint64(block.number)) {
            revert IS21InstitutionalRewardVault__SameBlockWithdrawNotAllowed();
        }

        uint256 ownerSharesBefore = balanceOf(owner_);
        uint256 ownerAssetsBefore = convertToAssets(ownerSharesBefore);
        uint256 principalBefore = sPrincipalDeposited[owner_];

        if (shares < ownerSharesBefore) {
            uint256 ownerAssetsAfter = ownerAssetsBefore - assets;
            if (ownerAssetsAfter < sMinimumPositionAssets) {
                revert IS21InstitutionalRewardVault__RemainingBalanceBelowMinimum();
            }
        }

        uint256 principalReduction = 0;
        if (principalBefore > 0 && ownerSharesBefore > 0) {
            principalReduction = (principalBefore * shares) / ownerSharesBefore;
            if (principalReduction > principalBefore) {
                principalReduction = principalBefore;
            }
        }

        uint256 penaltyAmount = previewWithdrawalPenalty(owner_, assets);
        uint256 netAssets = assets - penaltyAmount;

        if (penaltyAmount == 0) {
            super._withdraw(caller, receiver, owner_, assets, shares);
        } else {
            if (caller != owner_) {
                _spendAllowance(owner_, caller, shares);
            }

            _burn(owner_, shares);

            IERC20 assetToken = IERC20(asset());
            assetToken.safeTransfer(stabilityWallet, penaltyAmount);
            assetToken.safeTransfer(receiver, netAssets);

            emit Withdraw(caller, receiver, owner_, assets, shares);
            emit WithdrawalPenaltyPaid(
                owner_,
                receiver,
                assets,
                penaltyAmount,
                netAssets,
                block.timestamp
            );
        }

        uint256 newPrincipal = principalBefore - principalReduction;

        if (balanceOf(owner_) == 0) {
            newPrincipal = 0;
            delete sWeightedDepositTimestamp[owner_];
            delete sLastDepositBlock[owner_];
        }

        sPrincipalDeposited[owner_] = newPrincipal;

        emit PrincipalUpdated(
            owner_,
            principalBefore,
            newPrincipal,
            block.timestamp
        );
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
            revert IS21InstitutionalRewardVault__ShareTransfersDisabled();
        }

        super._update(from, to, value);
    }

    ////////////////////////////////////
    // Reward Streaming Internals     //
    ////////////////////////////////////
    function _currentEpoch() internal view returns (uint64) {
        return
            uint64((block.timestamp - EPOCH_ZERO_TIMESTAMP) / EPOCH_DURATION);
    }

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

        if (overlapStart == stream.startEpoch) {
            amount += stream.firstEpochBonus;
        }
    }

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

    function _isEmptyPosition(address account) internal view returns (bool) {
        return
            balanceOf(account) == 0 &&
            sPrincipalDeposited[account] == 0 &&
            sWeightedDepositTimestamp[account] == 0 &&
            sLastDepositBlock[account] == 0;
    }

    /**
     * @dev Best-effort aggregate for reporting only. Avoid using this in state-changing logic
     *      because looping over many institutions can become expensive.
     */
    function _totalPrincipalDepositedBestEffort()
        internal
        view
        returns (uint256 totalPrincipal)
    {
        uint256 length = sWhitelistedInstitutions.length();
        for (uint256 i = 0; i < length; ) {
            totalPrincipal += sPrincipalDeposited[
                sWhitelistedInstitutions.at(i)
            ];

            unchecked {
                ++i;
            }
        }
    }
}
