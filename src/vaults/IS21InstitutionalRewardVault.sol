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
 * - This is a pure shares-based vault: rewards increase ERC4626 share price.
 * - No loyalty multipliers.
 * - No manual claim function.
 * - No manual compound function.
 * - Reward managers add IS21 rewards directly into the vault.
 * - Reward split:
 *   - 10% treasury
 *   - 2% stability reserve
 *   - 88% institutional vault rewards
 * - Institutional rewards remain in the vault and increase assets per share.
 * - Minimum position threshold is configurable, default 150,000 IS21.
 * - Withdrawal penalty period is configurable, default 30 days.
 * - If a partial withdrawal would leave the institution below the minimum position,
 *   the transaction reverts and the institution must fully exit instead.
 * - Shares are non-transferable except for controlled full-position transfers.
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
    error IS21InstitutionalRewardVault__RewardAddressesNotConfigured();
    error IS21InstitutionalRewardVault__InsufficientFreeBalanceForRescue();
    error IS21InstitutionalRewardVault__ShareTransfersDisabled();
    error IS21InstitutionalRewardVault__ReceiverMustBeEmpty();
    error IS21InstitutionalRewardVault__CannotTransferToSelf();

    /////////////////////
    // State Variables //
    /////////////////////
    string public constant IS21_INSTITUTIONAL_VAULT_VERSION = "1.0.0";

    uint256 private constant BPS = 10_000;
    uint256 private constant TREASURY_BPS = 1_000; // 10%
    uint256 private constant STABILITY_RESERVE_BPS = 200; // 2%
    uint256 private constant DEFAULT_MINIMUM_POSITION = 150_000 ether;
    uint256 private constant DEFAULT_WITHDRAWAL_PENALTY_PERIOD = 30 days;

    EnumerableSet.AddressSet private sFundManagers;
    EnumerableSet.AddressSet private sRewardManagers;
    EnumerableSet.AddressSet private sWhitelistedInstitutions;

    mapping(address => uint64) private sWeightedDepositTimestamp;
    mapping(address => uint64) private sLastDepositBlock;

    bool private sPositionTransferInProgress;

    address private treasuryWallet;
    address private stabilityWallet;

    uint256 private sMinimumPositionAssets;
    uint256 private sWithdrawalPenaltyPeriod;
    uint256 private sWithdrawalPenaltyBps;

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

    event RewardsAdded(
        address indexed rewardManager,
        uint256 totalAmount,
        uint256 treasuryAmount,
        uint256 stabilityReserveAmount,
        uint256 vaultRewardAmount,
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
        return convertToAssets(balanceOf(owner_));
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
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
     * @notice Adds IS21 rewards to the institutional vault.
     * @dev The 88% vault reward amount stays inside the vault and increases share price.
     */
    function addRewards(
        uint256 totalAmount
    )
        external
        onlyRewardManager
        moreThanZero(totalAmount)
        nonReentrant
        whenNotPaused
    {
        if (treasuryWallet == address(0) || stabilityWallet == address(0)) {
            revert IS21InstitutionalRewardVault__RewardAddressesNotConfigured();
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

        emit RewardsAdded(
            msg.sender,
            totalAmount,
            treasuryAmount,
            reserveAmount,
            vaultRewardAmount,
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
     * @notice Rescue tokens accidentally sent to the contract, but never underlying IS21 assets backing shares.
     */
    function rescueErc20(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner nonZeroAddress(token) nonZeroAddress(to) nonReentrant {
        if (token == asset()) {
            uint256 requiredBalance = totalAssets();
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

        uint64 weightedTimestampToMove = sWeightedDepositTimestamp[msg.sender];

        sPositionTransferInProgress = true;
        _transfer(msg.sender, to, sharesToMove);
        sPositionTransferInProgress = false;

        sWeightedDepositTimestamp[to] = weightedTimestampToMove;
        sLastDepositBlock[to] = uint64(block.number);

        delete sWeightedDepositTimestamp[msg.sender];
        delete sLastDepositBlock[msg.sender];

        emit FullPositionTransferred(
            msg.sender,
            to,
            sharesToMove,
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

        sLastDepositBlock[receiver] = uint64(block.number);

        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        uint256 ownerSharesBefore = balanceOf(owner_);
        uint256 ownerAssetsBefore = convertToAssets(ownerSharesBefore);

        if (shares < ownerSharesBefore) {
            uint256 ownerAssetsAfter = ownerAssetsBefore - assets;
            if (ownerAssetsAfter < sMinimumPositionAssets) {
                revert IS21InstitutionalRewardVault__RemainingBalanceBelowMinimum();
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

            SafeERC20.safeTransfer(
                IERC20(asset()),
                stabilityWallet,
                penaltyAmount
            );
            SafeERC20.safeTransfer(IERC20(asset()), receiver, netAssets);

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

        if (balanceOf(owner_) == 0) {
            delete sWeightedDepositTimestamp[owner_];
            delete sLastDepositBlock[owner_];
        }
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

    function _isEmptyPosition(address account) internal view returns (bool) {
        return
            balanceOf(account) == 0 &&
            sWeightedDepositTimestamp[account] == 0 &&
            sLastDepositBlock[account] == 0;
    }
}
