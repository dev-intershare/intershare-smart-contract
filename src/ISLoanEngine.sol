// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ISLoanConfig} from "./ISLoanConfig.sol";
import {ISLoanEngineCore} from "./libraries/ISLoanEngineCore.sol";
import {TokenConfig, AccountData} from "./types/ISLoanTypes.sol";

/**
 * @title ISLoanEngine
 * @author BlueAsset Technology Team
 *
 * @notice Core lending and borrowing engine for the InterShare ecosystem.
 * @dev Implements collateralized lending, interest accrual, liquidation, and oracle valuation.
 */
contract ISLoanEngine is ISLoanConfig, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using OracleLib for OracleLib.OracleConfig;
    using EnumerableSet for EnumerableSet.AddressSet;
    using ISLoanEngineCore for TokenConfig;

    // ========================
    // Constants
    // ========================
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant SAFE_HF_MARGIN = 1001e15; // 1.001 * 1e18

    // ========================
    // Errors
    // ========================
    error ISLoanEngine__AmountExceedsBalance();
    error ISLoanEngine__NotZeroAddress();
    error ISLoanEngine__TokenNotSupported();
    error ISLoanEngine__NoDebtToRepay();
    error ISLoanEngine__NotEnoughLiquidity();
    error ISLoanEngine__NotEnoughCollateral();
    error ISLoanEngine__UserNotLiquidatable();

    // ========================
    // State Variables
    // ========================
    mapping(address => mapping(address => uint256)) public deposits; // user => token => scaledDeposit
    mapping(address => mapping(address => uint256)) public debts; // user => token => scaledDebt
    mapping(address => uint256) public totalDeposits; // token => total deposited
    mapping(address => uint256) public totalBorrows; // token => total borrowed

    // ========================
    // Events
    // ========================
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event Liquidate(
        address indexed liquidator,
        address indexed user,
        address indexed token,
        uint256 repaid
    );
    event HealthFactorUpdated(address indexed user, uint256 healthFactor);
    event AllInterestRefreshed(uint256 timestamp);
    event ContractPaused(address indexed caller, uint256 timestamp);
    event ContractUnpaused(address indexed caller, uint256 timestamp);

    // ========================
    // Constructor
    // ========================
    constructor(address ownerAddress) ISLoanConfig(ownerAddress) {
        if (ownerAddress == address(0)) revert ISLoanEngine__NotZeroAddress();
    }

    // ========================
    // Core Functions
    // ========================

    function deposit(
        address token,
        uint256 amount
    )
        external
        nonReentrant
        moreThanZero(amount)
        nonZeroAddress(token)
        onlySupportedToken(token)
        whenNotPaused
    {
        ISLoanEngineCore.accrueAllInterest(
            supportedTokens.values(),
            tokenConfigs
        );
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        TokenConfig storage cfg = tokenConfigs[token];
        uint256 scaledAmount = (amount * 1e18) / cfg.supplyIndex;

        deposits[msg.sender][token] += scaledAmount;
        totalDeposits[token] += amount;

        emit Deposit(msg.sender, token, amount);
    }

    function withdraw(
        address token,
        uint256 amount
    )
        external
        nonReentrant
        moreThanZero(amount)
        onlySupportedToken(token)
        whenNotPaused
    {
        ISLoanEngineCore.accrueAllInterest(
            supportedTokens.values(),
            tokenConfigs
        );

        TokenConfig storage cfg = tokenConfigs[token];
        uint256 scaledAmount = (amount * 1e18) / cfg.supplyIndex;

        if (scaledAmount > deposits[msg.sender][token])
            revert ISLoanEngine__AmountExceedsBalance();

        uint256 contractBalance = getAvailableLiquidity(token);
        if (amount > contractBalance) revert ISLoanEngine__NotEnoughLiquidity();

        deposits[msg.sender][token] -= scaledAmount;
        totalDeposits[token] -= amount;

        if (getHealthFactor(msg.sender) < SAFE_HF_MARGIN) {
            deposits[msg.sender][token] += scaledAmount;
            totalDeposits[token] += amount;
            revert ISLoanEngine__NotEnoughCollateral();
        }

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, token, amount);
        emit HealthFactorUpdated(msg.sender, getHealthFactor(msg.sender));
    }

    function borrow(
        address token,
        uint256 amount
    )
        external
        nonReentrant
        moreThanZero(amount)
        onlySupportedToken(token)
        whenNotPaused
    {
        ISLoanEngineCore.accrueAllInterest(
            supportedTokens.values(),
            tokenConfigs
        );

        uint256 liquidity = getAvailableLiquidity(token);
        if (amount > liquidity) revert ISLoanEngine__NotEnoughLiquidity();

        TokenConfig storage cfg = tokenConfigs[token];
        uint256 scaledAmount = (amount * 1e18) / cfg.borrowIndex;

        debts[msg.sender][token] += scaledAmount;
        totalBorrows[token] += amount;

        if (getHealthFactor(msg.sender) < SAFE_HF_MARGIN) {
            debts[msg.sender][token] -= scaledAmount;
            totalBorrows[token] -= amount;
            revert ISLoanEngine__NotEnoughCollateral();
        }

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, token, amount);
        emit HealthFactorUpdated(msg.sender, getHealthFactor(msg.sender));
    }

    function repay(
        address token,
        uint256 amount
    )
        external
        nonReentrant
        moreThanZero(amount)
        onlySupportedToken(token)
        whenNotPaused
    {
        ISLoanEngineCore.accrueAllInterest(
            supportedTokens.values(),
            tokenConfigs
        );

        TokenConfig storage cfg = tokenConfigs[token];
        uint256 scaledDebt = debts[msg.sender][token];
        if (scaledDebt == 0) revert ISLoanEngine__NoDebtToRepay();

        uint256 currentDebt = (scaledDebt * cfg.borrowIndex) / 1e18;
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), repayAmount);

        uint256 scaledRepay = (repayAmount * 1e18) / cfg.borrowIndex;
        debts[msg.sender][token] -= scaledRepay;
        totalBorrows[token] -= repayAmount;

        emit Repay(msg.sender, token, repayAmount);
        emit HealthFactorUpdated(msg.sender, getHealthFactor(msg.sender));
    }

    function liquidate(
        address user,
        address repayToken,
        address collateralToken,
        uint256 repayAmount
    )
        external
        nonReentrant
        nonZeroAddress(repayToken)
        nonZeroAddress(collateralToken)
        onlySupportedToken(repayToken)
        onlySupportedToken(collateralToken)
        whenNotPaused
    {
        ISLoanEngineCore.accrueInterest(repayToken, tokenConfigs[repayToken]);
        ISLoanEngineCore.accrueInterest(
            collateralToken,
            tokenConfigs[collateralToken]
        );

        if (getHealthFactor(user) >= MIN_HEALTH_FACTOR)
            revert ISLoanEngine__UserNotLiquidatable();

        TokenConfig storage repayCfg = tokenConfigs[repayToken];
        TokenConfig storage collCfg = tokenConfigs[collateralToken];

        uint256 scaledDebt = debts[user][repayToken];
        uint256 currentDebt = (scaledDebt * repayCfg.borrowIndex) / 1e18;
        uint256 repayAmountCapped = repayAmount > currentDebt
            ? currentDebt
            : repayAmount;

        IERC20(repayToken).safeTransferFrom(
            msg.sender,
            address(this),
            repayAmountCapped
        );

        uint256 scaledRepay = (repayAmountCapped * 1e18) / repayCfg.borrowIndex;
        debts[user][repayToken] -= scaledRepay;
        totalBorrows[repayToken] -= repayAmountCapped;

        uint256 normalizedRepay = ISLoanEngineCore.normalizeTo18(
            repayAmountCapped,
            repayCfg.decimals
        );
        uint256 repayUsd = (normalizedRepay * repayCfg.oracle.getPrice()) /
            1e18;

        uint256 seizeUsd = (repayUsd * collCfg.liquidationBonus) / 1e4;
        uint256 collPrice = collCfg.oracle.getPrice();
        uint256 seizeAmountNormalized = (seizeUsd * 1e18) / collPrice;
        uint256 seizeAmount = ISLoanEngineCore.normalizeTo18(
            seizeAmountNormalized,
            collCfg.decimals
        );

        uint256 userScaledDeposit = deposits[user][collateralToken];
        uint256 userDeposit = (userScaledDeposit * collCfg.supplyIndex) / 1e18;
        if (seizeAmount > userDeposit) seizeAmount = userDeposit;

        uint256 scaledSeize = (seizeAmount * 1e18) / collCfg.supplyIndex;
        deposits[user][collateralToken] -= scaledSeize;
        totalDeposits[collateralToken] -= seizeAmount;

        IERC20(collateralToken).safeTransfer(msg.sender, seizeAmount);

        emit Liquidate(msg.sender, user, repayToken, repayAmountCapped);
    }

    // ========================
    // View Functions
    // ========================

    function getUserAccountData(
        address user
    ) public view returns (AccountData memory data) {
        data.totalCollateralUsd = getCollateralValue(user);
        data.totalDebtUsd = getDebtValue(user);
        if (data.totalDebtUsd == 0) {
            data.healthFactor = type(uint256).max;
            data.availableBorrowsUsd = data.totalCollateralUsd;
        } else {
            data.availableBorrowsUsd = data.totalCollateralUsd >
                data.totalDebtUsd
                ? data.totalCollateralUsd - data.totalDebtUsd
                : 0;
            data.healthFactor =
                (data.totalCollateralUsd * 1e18) /
                data.totalDebtUsd;
        }
    }

    function getMyAccountData() external view returns (AccountData memory) {
        return getUserAccountData(msg.sender);
    }

    function getCollateralValue(
        address user
    ) public view returns (uint256 valueUsd) {
        address[] memory tokens = supportedTokens.values();
        for (uint256 i = 0; i < tokens.length; i++) {
            TokenConfig memory cfg = tokenConfigs[tokens[i]];
            uint256 scaledBalance = deposits[user][tokens[i]];
            if (scaledBalance == 0) continue;

            uint256 balance = (scaledBalance * cfg.supplyIndex) / 1e18;
            uint256 normalized = ISLoanEngineCore.normalizeTo18(
                balance,
                cfg.decimals
            );
            uint256 usdValue = (normalized * cfg.oracle.getPrice()) / 1e18;
            valueUsd += (usdValue * cfg.collateralFactor) / 1e4;
        }
    }

    function getDebtValue(address user) public view returns (uint256 debtUsd) {
        address[] memory tokens = supportedTokens.values();
        for (uint256 i = 0; i < tokens.length; i++) {
            TokenConfig memory cfg = tokenConfigs[tokens[i]];
            uint256 scaledDebt = debts[user][tokens[i]];
            if (scaledDebt == 0) continue;

            uint256 debt = (scaledDebt * cfg.borrowIndex) / 1e18;
            uint256 normalized = ISLoanEngineCore.normalizeTo18(
                debt,
                cfg.decimals
            );
            debtUsd += (normalized * cfg.oracle.getPrice()) / 1e18;
        }
    }

    function getBorrowLimit(
        address user
    ) public view returns (uint256 limitUsd) {
        return getCollateralValue(user);
    }

    function getHealthFactor(address user) public view returns (uint256) {
        uint256 debtUsd = getDebtValue(user);
        if (debtUsd == 0) return type(uint256).max;

        uint256 weightedCollateralUsd;
        address[] memory tokens = supportedTokens.values();

        for (uint256 i = 0; i < tokens.length; i++) {
            TokenConfig memory cfg = tokenConfigs[tokens[i]];
            uint256 scaledBalance = deposits[user][tokens[i]];
            if (scaledBalance == 0 || !cfg.isSupported) continue;

            uint256 balance = (scaledBalance * cfg.supplyIndex) / 1e18;
            uint256 normalized = ISLoanEngineCore.normalizeTo18(
                balance,
                cfg.decimals
            );
            uint256 usdValue = (normalized * cfg.oracle.getPrice()) / 1e18;
            weightedCollateralUsd += (usdValue * cfg.collateralFactor) / 1e4;
        }

        return (weightedCollateralUsd * 1e18) / debtUsd;
    }

    function getAvailableLiquidity(
        address token
    ) public view returns (uint256) {
        return totalDeposits[token] - totalBorrows[token];
    }

    // ========================
    // Admin Functions
    // ========================
    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender, block.timestamp);
    }

    function refreshAllTokens()
        external
        onlyFundManager
        nonReentrant
        whenNotPaused
    {
        ISLoanEngineCore.accrueAllInterest(
            supportedTokens.values(),
            tokenConfigs
        );
        emit AllInterestRefreshed(block.timestamp);
    }
}
