// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract IS21YieldVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    //////////////////////////
    // Errors
    //////////////////////////

    error IS21Vault__UnauthorizedCaller();
    error IS21Vault__InvalidAmount();
    error IS21Vault__SameBlockWithdraw();
    error IS21Vault__SameBlockSkim();
    error IS21Vault__NotZeroAddress();
    error IS21Vault__NoStakers();
    error IS21Vault__InvalidMultiplierConfig();
    error IS21Vault__TransferDisabled();
    error IS21Vault__InsufficientProfit();
    error IS21Vault__InvalidReceiver();

    //////////////////////////
    // Constants
    //////////////////////////

    uint256 private constant MULTIPLIER_BASE = 10_000;
    uint256 private constant MULTIPLIER_1X = 10_000;
    uint256 private constant MULTIPLIER_1_5X = 15_000;
    uint256 private constant MULTIPLIER_2X = 20_000;

    uint256 private constant LARGE_STAKE_THRESHOLD = 100_000 ether;
    uint256 private constant RESET_THRESHOLD = 10; // percent

    //////////////////////////
    // State
    //////////////////////////

    string public constant VAULT_VERSION = "1.0.0";

    address public treasuryWallet;
    address public stabilityReserveWallet;

    uint256 public days_1_5x = 30 days;
    uint256 public days_2x = 90 days;

    // Wallet-bound basis used for skimming + loyalty.
    // This is NOT the same thing as current position value.
    mapping(address => uint256) public principalBasis;

    // Loyalty age of maintained principal.
    mapping(address => uint256) public stakeTimestamp;

    // Flash-loan guard / same-block exit guard.
    mapping(address => uint256) public lastDepositBlock;

    EnumerableSet.AddressSet private sAuthorizedCallers;

    //////////////////////////
    // Events
    //////////////////////////

    event RewardAdded(
        uint256 grossAmount,
        uint256 treasuryShare,
        uint256 stabilityShare,
        uint256 stakerShare
    );
    event Skimmed(
        address indexed account,
        address indexed receiver,
        uint256 assets,
        uint256 sharesBurned
    );
    event PrincipalBasisUpdated(
        address indexed account,
        uint256 oldBasis,
        uint256 newBasis
    );
    event CallerAuthorized(address indexed caller, uint256 timestamp);
    event CallerRevoked(address indexed caller, uint256 timestamp);
    event TreasuryWalletUpdated(address indexed wallet);
    event StabilityReserveUpdated(address indexed wallet);
    event ContractPaused(address indexed caller, uint256 timestamp);
    event ContractUnpaused(address indexed caller, uint256 timestamp);

    //////////////////////////
    // Constructor
    //////////////////////////

    constructor(
        address asset_,
        address owner_,
        address treasury_,
        address stability_
    )
        ERC4626(IERC20(asset_))
        ERC20("Staked InterShare21", "sIS21")
        Ownable(owner_)
    {
        if (
            asset_ == address(0) ||
            owner_ == address(0) ||
            treasury_ == address(0) ||
            stability_ == address(0)
        ) {
            revert IS21Vault__NotZeroAddress();
        }

        treasuryWallet = treasury_;
        stabilityReserveWallet = stability_;
    }

    //////////////////////////
    // Modifiers
    //////////////////////////

    modifier onlyAuthorizedCaller() {
        if (!sAuthorizedCallers.contains(msg.sender)) {
            revert IS21Vault__UnauthorizedCaller();
        }
        _;
    }

    modifier nonZeroAddress(address account) {
        if (account == address(0)) {
            revert IS21Vault__NotZeroAddress();
        }
        _;
    }

    //////////////////////////
    // ERC4626 Core
    //////////////////////////

    /// @notice Proper ERC4626 total assets.
    /// Includes deposited principal plus all compounded yield held by the vault.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
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
        if (lastDepositBlock[owner_] == block.number) return 0;
        return convertToAssets(balanceOf(owner_));
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (lastDepositBlock[owner_] == block.number) return 0;
        return balanceOf(owner_);
    }

    //////////////////////////
    // Position / Loyalty Views
    //////////////////////////

    /// @notice Current total vault value of a user's shares.
    function positionValueOf(address account) public view returns (uint256) {
        uint256 shares = balanceOf(account);
        if (shares == 0) return 0;
        return convertToAssets(shares);
    }

    /// @notice Yield currently available to skim without touching principal basis.
    function profitOf(address account) public view returns (uint256) {
        uint256 value = positionValueOf(account);
        uint256 basis = principalBasis[account];
        return value > basis ? value - basis : 0;
    }

    function maxSkim(address account) public view returns (uint256) {
        if (paused()) return 0;
        if (lastDepositBlock[account] == block.number) return 0;
        return profitOf(account);
    }

    /// @notice Loyalty multiplier based on:
    /// 1) current vault value fast-track threshold
    /// 2) otherwise time-based loyalty age
    function multiplierOf(address account) public view returns (uint256) {
        uint256 value = positionValueOf(account);
        if (value == 0) {
            return MULTIPLIER_1X;
        }

        return _multiplierFromValue(value, stakeTimestamp[account]);
    }

    function _multiplierFromValue(
        uint256 value,
        uint256 timestamp
    ) internal view returns (uint256) {
        if (value >= LARGE_STAKE_THRESHOLD) {
            return MULTIPLIER_2X;
        }

        if (timestamp == 0) {
            return MULTIPLIER_1X;
        }

        uint256 duration = block.timestamp - timestamp;

        if (duration >= days_2x) return MULTIPLIER_2X;
        if (duration >= days_1_5x) return MULTIPLIER_1_5X;
        return MULTIPLIER_1X;
    }

    //////////////////////////
    // Deposit / Mint
    //////////////////////////

    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 sharesMinted)
    {
        if (assets == 0) {
            revert IS21Vault__InvalidAmount();
        }
        if (receiver == address(0)) {
            revert IS21Vault__InvalidReceiver();
        }

        sharesMinted = super.deposit(assets, receiver);

        _increasePrincipalBasis(receiver, assets);
        lastDepositBlock[receiver] = block.number;
    }

    function mint(
        uint256 shares,
        address receiver
    )
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assetsDeposited)
    {
        if (shares == 0) {
            revert IS21Vault__InvalidAmount();
        }
        if (receiver == address(0)) {
            revert IS21Vault__InvalidReceiver();
        }

        assetsDeposited = super.mint(shares, receiver);

        _increasePrincipalBasis(receiver, assetsDeposited);
        lastDepositBlock[receiver] = block.number;
    }

    //////////////////////////
    // Withdraw / Redeem
    //////////////////////////

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    )
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 sharesBurned)
    {
        if (lastDepositBlock[owner_] == block.number) {
            revert IS21Vault__SameBlockWithdraw();
        }

        uint256 preValue = positionValueOf(owner_);
        uint256 oldBasis = principalBasis[owner_];

        sharesBurned = super.withdraw(assets, receiver, owner_);

        _applyBasisAfterAssetOutflow(owner_, assets, preValue, oldBasis);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override nonReentrant whenNotPaused returns (uint256 assetsOut) {
        if (lastDepositBlock[owner_] == block.number) {
            revert IS21Vault__SameBlockWithdraw();
        }

        uint256 preValue = positionValueOf(owner_);
        uint256 oldBasis = principalBasis[owner_];

        assetsOut = super.redeem(shares, receiver, owner_);

        _applyBasisAfterAssetOutflow(owner_, assetsOut, preValue, oldBasis);
    }

    //////////////////////////
    // Skimming
    //////////////////////////

    /// @notice Withdraw only accrued yield, preserving principal basis and loyalty timestamp.
    function skim(
        uint256 assets,
        address receiver
    ) external nonReentrant whenNotPaused returns (uint256 sharesBurned) {
        if (assets == 0) {
            revert IS21Vault__InvalidAmount();
        }
        if (receiver == address(0)) {
            revert IS21Vault__InvalidReceiver();
        }
        if (lastDepositBlock[msg.sender] == block.number) {
            revert IS21Vault__SameBlockSkim();
        }

        uint256 availableProfit = profitOf(msg.sender);
        if (assets > availableProfit) {
            revert IS21Vault__InsufficientProfit();
        }

        sharesBurned = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, msg.sender, assets, sharesBurned);

        if (balanceOf(msg.sender) == 0) {
            uint256 oldBasis = principalBasis[msg.sender];
            principalBasis[msg.sender] = 0;
            stakeTimestamp[msg.sender] = 0;
            emit PrincipalBasisUpdated(msg.sender, oldBasis, 0);
        }

        emit Skimmed(msg.sender, receiver, assets, sharesBurned);
    }

    //////////////////////////
    // Reward Injection
    //////////////////////////
    function notifyReward(
        uint256 amount
    ) external nonReentrant onlyAuthorizedCaller {
        if (amount == 0) {
            revert IS21Vault__InvalidAmount();
        }

        if (totalSupply() == 0) {
            revert IS21Vault__NoStakers();
        }

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        uint256 treasuryShare = (amount * 10) / 100;
        uint256 stabilityShare = (amount * 2) / 100;
        uint256 stakerShare = amount - treasuryShare - stabilityShare;

        if (treasuryShare > 0) {
            IERC20(asset()).safeTransfer(treasuryWallet, treasuryShare);
        }

        if (stabilityShare > 0) {
            IERC20(asset()).safeTransfer(
                stabilityReserveWallet,
                stabilityShare
            );
        }

        emit RewardAdded(amount, treasuryShare, stabilityShare, stakerShare);
    }

    //////////////////////////
    // Internal Basis Logic
    //////////////////////////

    function _increasePrincipalBasis(
        address account,
        uint256 addedAssets
    ) internal {
        uint256 oldBasis = principalBasis[account];
        uint256 newBasis = oldBasis + addedAssets;
        uint256 oldTimestamp = stakeTimestamp[account];

        principalBasis[account] = newBasis;

        if (oldBasis == 0) {
            stakeTimestamp[account] = block.timestamp;
        } else {
            uint256 percentIncrease = (addedAssets * 100) / oldBasis;

            if (percentIncrease >= RESET_THRESHOLD) {
                stakeTimestamp[account] = block.timestamp;
            } else {
                uint256 weightedTimestamp = ((oldBasis * oldTimestamp) +
                    (addedAssets * block.timestamp)) / newBasis;

                stakeTimestamp[account] = weightedTimestamp;
            }
        }

        emit PrincipalBasisUpdated(account, oldBasis, newBasis);
    }

    function _applyBasisAfterAssetOutflow(
        address account,
        uint256 assetsOut,
        uint256 preValue,
        uint256 oldBasis
    ) internal {
        uint256 remainingShares = balanceOf(account);

        if (remainingShares == 0) {
            principalBasis[account] = 0;
            stakeTimestamp[account] = 0;
            emit PrincipalBasisUpdated(account, oldBasis, 0);
            return;
        }

        uint256 profit = preValue > oldBasis ? preValue - oldBasis : 0;
        uint256 principalReduction = assetsOut > profit
            ? assetsOut - profit
            : 0;

        if (principalReduction == 0) {
            // Pure profit withdrawal: keep basis and loyalty intact.
            return;
        }

        uint256 reduction = principalReduction > oldBasis
            ? oldBasis
            : principalReduction;

        uint256 newBasis = oldBasis - reduction;
        principalBasis[account] = newBasis;

        // Policy: any withdrawal that touches principal resets loyalty age.
        stakeTimestamp[account] = block.timestamp;

        emit PrincipalBasisUpdated(account, oldBasis, newBasis);
    }

    //////////////////////////
    // Disable Share Transfers
    //////////////////////////

    function transfer(
        address,
        uint256
    ) public pure override(ERC20, IERC20) returns (bool) {
        revert IS21Vault__TransferDisabled();
    }

    function transferFrom(
        address,
        address,
        uint256
    ) public pure override(ERC20, IERC20) returns (bool) {
        revert IS21Vault__TransferDisabled();
    }

    function approve(
        address,
        uint256
    ) public pure override(ERC20, IERC20) returns (bool) {
        revert IS21Vault__TransferDisabled();
    }

    //////////////////////////
    // Admin: Multiplier Config
    //////////////////////////

    function set_1_5xMultiplierDays(
        uint256 newDays
    ) external nonReentrant whenNotPaused onlyAuthorizedCaller {
        if (newDays >= days_2x) {
            revert IS21Vault__InvalidMultiplierConfig();
        }
        days_1_5x = newDays;
    }

    function set_2xMultiplierDays(
        uint256 newDays
    ) external nonReentrant whenNotPaused onlyAuthorizedCaller {
        if (newDays <= days_1_5x) {
            revert IS21Vault__InvalidMultiplierConfig();
        }
        days_2x = newDays;
    }

    //////////////////////////
    // Authorized Callers
    //////////////////////////

    function authorizeCaller(
        address caller
    ) external onlyOwner nonZeroAddress(caller) nonReentrant {
        if (sAuthorizedCallers.add(caller)) {
            emit CallerAuthorized(caller, block.timestamp);
        }
    }

    function revokeCaller(
        address caller
    ) external onlyOwner nonZeroAddress(caller) nonReentrant {
        if (sAuthorizedCallers.remove(caller)) {
            emit CallerRevoked(caller, block.timestamp);
        }
    }

    function getAuthorizedCallers() external view returns (address[] memory) {
        return sAuthorizedCallers.values();
    }

    //////////////////////////
    // Admin
    //////////////////////////

    function setTreasuryWallet(
        address wallet
    ) external onlyOwner nonZeroAddress(wallet) {
        treasuryWallet = wallet;
        emit TreasuryWalletUpdated(wallet);
    }

    function setStabilityReserveWallet(
        address wallet
    ) external onlyOwner nonZeroAddress(wallet) {
        stabilityReserveWallet = wallet;
        emit StabilityReserveUpdated(wallet);
    }

    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender, block.timestamp);
    }

    //////////////////////////
    // Views
    //////////////////////////

    function getVersion() external pure returns (string memory) {
        return VAULT_VERSION;
    }
}
