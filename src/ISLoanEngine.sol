// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

/// @notice Configuration for each supported token
struct TokenConfig {
    bool isSupported;
    uint256 collateralFactor; // scaled by 1e4 (e.g. 7500 = 75%) - LTV
    OracleLib.OracleConfig oracle; // includes both Chainlink + Pyth config
    uint8 decimals; // for normalizing (e.g. USDT = 6, WBTC = 8, IS21 = 18)
    uint256 supplyIndex; // scaled by 1e18 - index to track interest for suppliers
    uint256 borrowIndex; // scaled by 1e18 - index to track interest for borrowers
    uint40 lastUpdate; // timestamp of last index update - happens when anyone interacts with the contract like deposit/withdraw/borrow/repay
    uint256 supplyInterestRate; // scaled by 1e18 (5% = 0.05e18)
    uint256 borrowInterestRate; // scaled by 1e18 (13% = 0.13e18)
    uint256 liquidationBonus; // scaled by 1e4 (e.g. 10500 = 105%)
}

/// @notice Snapshot of a user's account data
struct AccountData {
    uint256 totalCollateralUsd;
    uint256 totalDebtUsd;
    uint256 availableBorrowsUsd;
    uint256 healthFactor;
}

/**
 * @title ISLoanEngine
 * @author BlueAsset Technology Team
 *
 * @notice The ISLoanEngine contract powers the lending and borrowing system within the InterShare ecosystem.
 * It enables users to deposit supported tokens as collateral, borrow against their positions, repay loans,
 * and participate in liquidations if accounts become undercollateralized.
 *
 * @dev Key Principles:
 * - Collateralized Lending: Users supply supported tokens as collateral to access borrowing power.
 * - Health Factor Enforcement: Borrowing capacity is continuously monitored; accounts below 1.0 can be liquidated.
 * - Interest Accrual: Supply and borrow balances are updated over time using per-second compounding interest indices.
 * - Risk Management: Each token has configurable collateral factors, interest rates, and liquidation bonuses.
 * - Oracle Integration: Token valuations are secured via Chainlink price feeds.
 *
 * @dev Contract Capabilities:
 * - Deposits and withdrawals of supported collateral tokens.
 * - Borrowing and repayment of supported tokens.
 * - Liquidation of unhealthy accounts by third-party liquidators with a bonus incentive.
 * - Fund manager governance to configure collateral factors, interest rates, and supported tokens.
 * - Interest accrual across all supported tokens using efficient exponentiation.
 * - Pausable contract functionality for added protocol security.
 *
 * @notice ISLoanEngine is designed as a decentralized lending protocol to complement IS21,
 * providing collateralized borrowing markets, risk-managed lending, and secure liquidation mechanisms.
 */

contract ISLoanEngine is ReentrancyGuard, Ownable, Pausable {
    ///////////////
    // Types     //
    ///////////////
    using SafeERC20 for IERC20;
    using OracleLib for OracleLib.OracleConfig;
    using EnumerableSet for EnumerableSet.AddressSet;

    /////////////////////
    // Constants       //
    /////////////////////
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant SAFE_HF_MARGIN = 1001e15; // 1.001 * 1e18

    ///////////////
    // Errors    //
    ///////////////
    error ISLoanEngine__AmountMustBeMoreThanZero();
    error ISLoanEngine__AmountExceedsBalance();
    error ISLoanEngine__NotZeroAddress();
    error ISLoanEngine__TokenNotSupported();
    error ISLoanEngine__NoDebtToRepay();
    error ISLoanEngine__NotEnoughLiquidity();
    error ISLoanEngine__NotEnoughCollateral();
    error ISLoanEngine__AmountMustNotBeMoreThanOneHundredPercent();
    error ISLoanEngine__OnlyFundManagerCanExecute();
    error ISLoanEngine__UserNotLiquidatable();
    error ISLoanEngine__InvalidInterestRate();

    /////////////////////
    // State Variables //
    /////////////////////
    EnumerableSet.AddressSet private sFundManagers; // addresses approved as fund managers
    mapping(address => TokenConfig) public tokenConfigs; // config for all supported tokens
    EnumerableSet.AddressSet private supportedTokens; // set of all supported tokens

    mapping(address => mapping(address => uint256)) public deposits; // user => token => scaledDeposit
    mapping(address => mapping(address => uint256)) public debts; // user => token => scaledDebt
    mapping(address => OracleLib.OracleConfig) public oracleConfigs; // token => oracle config
    mapping(address => uint256) public totalDeposits; // in raw token units
    mapping(address => uint256) public totalBorrows; // in raw token units

    ////////////
    // Events //
    ////////////
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
    event FundManagerApproved(address indexed fundManager, uint256 timestamp);
    event FundManagerRevoked(address indexed fundManager, uint256 timestamp);
    event TokenAdded(address indexed token, uint256 factor, uint256 timestamp);
    event TokenRemoved(address indexed token, uint256 timestamp);
    event CollateralFactorUpdated(
        address token,
        uint256 oldFactor,
        uint256 newFactor
    );
    event InterestRatesUpdated(
        address token,
        uint256 supplyRate,
        uint256 borrowRate,
        uint256 liquidationBonus
    );
    event HealthFactorUpdated(address indexed user, uint256 healthFactor);
    event ContractPaused(address indexed caller, uint256 timestamp);
    event ContractUnpaused(address indexed caller, uint256 timestamp);
    event InterestAccrued(
        address indexed token,
        uint256 newSupplyIndex,
        uint256 newBorrowIndex,
        uint40 timestamp
    );
    event AllInterestRefreshed(uint256 timestamp);

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert ISLoanEngine__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier nonZeroAddress(address to) {
        if (to == address(0)) {
            revert ISLoanEngine__NotZeroAddress();
        }
        _;
    }

    modifier onlySupportedToken(address token) {
        if (!tokenConfigs[token].isSupported) {
            revert ISLoanEngine__TokenNotSupported();
        }
        _;
    }

    modifier onlyFundManager() {
        if (!sFundManagers.contains(msg.sender)) {
            revert ISLoanEngine__OnlyFundManagerCanExecute();
        }
        _;
    }

    /////////////////
    // Constructor //
    /////////////////

    /**
     * @notice Initializes the loan engine with the contract owner.
     * @param ownerAddress The address of the contract owner. Must not be the zero address.
     */
    constructor(address ownerAddress) Ownable(ownerAddress) {
        if (ownerAddress == address(0)) {
            revert ISLoanEngine__NotZeroAddress();
        }
    }

    ///////////////////////////////////
    //  External/Public Functions    //
    ///////////////////////////////////

    /** @notice This function allows users to deposit supported tokens into the lending pool.
     * It updates the user's deposit balance and the total deposits for the token.
     * Interest is accrued before updating balances to ensure accurate accounting.
     * @param token The address of the token to be deposited.
     * @param amount The amount of the token to be deposited, in its raw units.
     */
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
        _accrueAllInterest();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        TokenConfig storage cfg = tokenConfigs[token];
        uint256 scaledAmount = (amount * 1e18) / cfg.supplyIndex;

        deposits[msg.sender][token] += scaledAmount;
        totalDeposits[token] += amount;

        emit Deposit(msg.sender, token, amount);
    }

    /** @notice This function allows users to withdraw their deposited tokens from the lending pool.
     * It checks for sufficient balance and liquidity, updates the user's deposit balance,
     * and ensures that the user's health factor remains above 1 after the withdrawal.
     * Interest is accrued before updating balances to ensure accurate accounting.
     * @param token The address of the token to be withdrawn.
     * @param amount The amount of the token to be withdrawn, in its raw units.
     */
    function withdraw(
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
        _accrueAllInterest();

        TokenConfig storage cfg = tokenConfigs[token];
        uint256 scaledAmount = (amount * 1e18) / cfg.supplyIndex;

        if (scaledAmount > deposits[msg.sender][token]) {
            revert ISLoanEngine__AmountExceedsBalance();
        }

        uint256 contractBalance = availableLiquidity(token);
        if (amount > contractBalance) {
            revert ISLoanEngine__NotEnoughLiquidity();
        }

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

    /** @notice This function allows users to borrow supported tokens against their deposited collateral.
     * It checks for sufficient liquidity in the pool and ensures that the user's health factor
     * remains above 1 after borrowing. If the borrow would leave the user undercollateralized,
     * the transaction reverts. Interest is accrued before updating balances to ensure accurate accounting.
     * @param token The address of the token to be borrowed.
     * @param amount The amount of the token to be borrowed, in its raw units.
     */
    function borrow(
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
        _accrueAllInterest();

        uint256 contractLiquidity = availableLiquidity(token);
        if (amount > contractLiquidity) {
            revert ISLoanEngine__NotEnoughLiquidity();
        }

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

    /** @notice This function allows users to repay their borrowed tokens.
     * It updates the user's debt balance and the total borrows for the token.
     * Interest is accrued before updating balances to ensure accurate accounting.
     * @param token The address of the token to be repaid.
     * @param amount The amount of the token to be repaid, in its raw units.
     */
    function repay(
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
        _accrueAllInterest();

        TokenConfig storage cfg = tokenConfigs[token];
        uint256 scaledDebt = debts[msg.sender][token];
        if (scaledDebt == 0) {
            revert ISLoanEngine__NoDebtToRepay();
        }

        uint256 currentDebt = (scaledDebt * cfg.borrowIndex) / 1e18;
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), repayAmount);

        uint256 scaledRepay = (repayAmount * 1e18) / cfg.borrowIndex;
        debts[msg.sender][token] -= scaledRepay;
        totalBorrows[token] -= repayAmount;

        emit Repay(msg.sender, token, repayAmount);
        emit HealthFactorUpdated(msg.sender, getHealthFactor(msg.sender));
    }

    /** @notice This function allows liquidators to liquidate undercollateralized positions.
     * It repays a portion of the user's debt and seizes an equivalent amount of their collateral,
     * applying a liquidation bonus. Interest is accrued before updating balances to ensure
     * accurate accounting. The user's health factor must be below 1 to be eligible for liquidation.
     * @param user The address of the user to be liquidated.
     * @param repayToken The address of the token being repaid.
     * @param collateralToken The address of the collateral token to be seized.
     * @param repayAmount The amount of the repay token to be repaid, in its raw units.
     */
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
        _accrueInterest(repayToken);
        _accrueInterest(collateralToken);

        if (getHealthFactor(user) >= MIN_HEALTH_FACTOR) {
            revert ISLoanEngine__UserNotLiquidatable();
        }

        TokenConfig storage repayCfg = tokenConfigs[repayToken];
        TokenConfig storage collCfg = tokenConfigs[collateralToken];

        uint256 scaledDebt = debts[user][repayToken];
        uint256 currentDebt = (scaledDebt * repayCfg.borrowIndex) / 1e18;
        uint256 repayAmountCapped = repayAmount > currentDebt
            ? currentDebt
            : repayAmount;

        // --- Liquidator repays debt ---
        IERC20(repayToken).safeTransferFrom(
            msg.sender,
            address(this),
            repayAmountCapped
        );

        uint256 scaledRepay = (repayAmountCapped * 1e18) / repayCfg.borrowIndex;
        debts[user][repayToken] -= scaledRepay;
        totalBorrows[repayToken] -= repayAmountCapped;

        // --- Determine collateral to seize ---
        uint256 normalizedRepay = _normalizeTo18(
            repayAmountCapped,
            repayCfg.decimals
        );
        uint256 repayUsd = (normalizedRepay * repayCfg.oracle.getPrice()) /
            1e18;

        uint256 seizeUsd = (repayUsd * collCfg.liquidationBonus) / 1e4;

        uint256 collPrice = collCfg.oracle.getPrice();
        uint256 seizeAmountNormalized = (seizeUsd * 1e18) / collPrice;
        uint256 seizeAmount = _denormalizeFrom18(
            seizeAmountNormalized,
            collCfg.decimals
        );

        uint256 userScaledDeposit = deposits[user][collateralToken];
        uint256 userDeposit = (userScaledDeposit * collCfg.supplyIndex) / 1e18;
        if (seizeAmount > userDeposit) {
            seizeAmount = userDeposit;
        }

        uint256 scaledSeize = (seizeAmount * 1e18) / collCfg.supplyIndex;
        deposits[user][collateralToken] -= scaledSeize;
        totalDeposits[collateralToken] -= seizeAmount;

        IERC20(collateralToken).safeTransfer(msg.sender, seizeAmount);

        emit Liquidate(msg.sender, user, repayToken, repayAmountCapped);
    }

    /**
     * @notice Returns a snapshot of a user's overall lending position, including
     * total collateral value, total debt value, available borrowing power, and health factor.
     * @param user The address of the user to query.
     * @return data A struct containing the user's account data:
     * - totalCollateralUsd: Total value of collateral in USD (scaled by 1e18)
     * - totalDebtUsd: Total value of debt in USD (scaled by 1e18)
     * - availableBorrowsUsd: Available borrowing power in USD (scaled by 1e18)
     * - healthFactor: Health factor (scaled by 1e18), where values below 1 indicate liquidation risk
     */
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

    /**
     * @notice Returns a snapshot of my overall lending position, including
     * total collateral value, total debt value, available borrowing power, and health factor.
     * @dev This is a convenience function that calls getUserAccountData with msg.sender.
     */
    function getMyAccountData() external view returns (AccountData memory) {
        return getUserAccountData(msg.sender);
    }

    /**
     * @notice This function calculates the total value of a user's collateral in USD.
     * It iterates through all supported tokens, retrieves the user's deposit balance,
     * normalizes it to 18 decimals, fetches the current price from the price feed,
     * and applies the collateral factor to determine the adjusted USD value.
     * The final value represents the total collateral value that can be used for borrowing.
     * @param user The address of the user for whom to calculate the collateral value.
     * @return valueUsd The total collateral value in USD, adjusted by collateral factors.
     */
    function getCollateralValue(
        address user
    ) public view returns (uint256 valueUsd) {
        address[] memory tokens = supportedTokens.values();
        for (uint256 i = 0; i < tokens.length; i++) {
            TokenConfig memory cfg = tokenConfigs[tokens[i]];
            uint256 scaledBalance = deposits[user][tokens[i]];
            if (scaledBalance == 0) continue;

            uint256 balance = (scaledBalance * cfg.supplyIndex) / 1e18;
            uint256 normalized = _normalizeTo18(balance, cfg.decimals);
            uint256 price = cfg.oracle.getPrice();
            uint256 usdValue = (normalized * price) / 1e18;
            uint256 adjusted = (usdValue * cfg.collateralFactor) / 1e4;
            valueUsd += adjusted;
        }
    }

    /**
     * @notice This function calculates the total debt value of a user in USD.
     * It iterates through all supported tokens, retrieves the user's debt balance,
     * normalizes it to 18 decimals, and fetches the current price from the price feed.
     * The final value represents the total debt owed by the user across all tokens.
     * @param user The address of the user for whom to calculate the debt value.
     * @return debtUsd The total debt value in USD for the specified user.
     */
    function getDebtValue(address user) public view returns (uint256 debtUsd) {
        address[] memory tokens = supportedTokens.values();
        for (uint256 i = 0; i < tokens.length; i++) {
            TokenConfig memory cfg = tokenConfigs[tokens[i]];
            uint256 scaledDebt = debts[user][tokens[i]];
            if (scaledDebt == 0) continue;

            uint256 debt = (scaledDebt * cfg.borrowIndex) / 1e18;
            uint256 normalized = _normalizeTo18(debt, cfg.decimals);
            uint256 price = cfg.oracle.getPrice();

            debtUsd += (normalized * price) / 1e18;
        }
    }

    ////////////////////////////////////
    //   Fund Manager Functions       //
    ////////////////////////////////////

    /**
     * @notice Approves a new fund manager.
     * @param fundManager The address of the fund manager to be approved.
     * @dev Only callable by the contract owner. The address must be non-zero.
     */
    function approveFundManager(
        address fundManager
    ) external onlyOwner nonZeroAddress(fundManager) nonReentrant {
        if (sFundManagers.add(fundManager)) {
            emit FundManagerApproved(fundManager, block.timestamp);
        }
    }

    /**
     * @notice Revokes the approval of a fund manager.
     * @param fundManager The address of the fund manager to be revoked.
     * @dev Only callable by the contract owner. The address must be non-zero.
     */
    function revokeFundManager(
        address fundManager
    ) external onlyOwner nonZeroAddress(fundManager) nonReentrant {
        if (sFundManagers.remove(fundManager)) {
            emit FundManagerRevoked(fundManager, block.timestamp);
        }
    }

    /**
     * @notice Returns the list of all approved fund managers.
     * @return An array of addresses representing the approved fund managers.
     */
    function getFundManagers() external view returns (address[] memory) {
        return sFundManagers.values();
    }

    /**
     * @notice Checks if an address is an approved fund manager.
     * @param account The address to check.
     * @return True if the address is an approved fund manager, false otherwise.
     */
    function isFundManager(address account) external view returns (bool) {
        return sFundManagers.contains(account);
    }

    /**
     * @notice Sets the collateral factor for a specific token.
     * @dev Only callable by an approved fund manager. The token must be supported.
     * @param token The address of the token to update.
     * @param factor The new collateral factor, scaled by 1e4 (e.g., 7500 for 75%).
     */
    function setCollateralFactor(
        address token,
        uint256 factor
    )
        external
        nonReentrant
        onlyFundManager
        nonZeroAddress(token)
        moreThanZero(factor)
    {
        if (!tokenConfigs[token].isSupported) {
            revert ISLoanEngine__TokenNotSupported();
        }
        if (factor >= 1e4) {
            revert ISLoanEngine__AmountMustNotBeMoreThanOneHundredPercent();
        }

        uint256 oldFactor = tokenConfigs[token].collateralFactor;
        tokenConfigs[token].collateralFactor = factor;
        emit CollateralFactorUpdated(token, oldFactor, factor);
    }

    /**
     * @notice Sets the interest rates and liquidation bonus for a specific token.
     * @dev Only callable by an approved fund manager. The token must be supported.
     * @param token The address of the token to update.
     * @param supplyRate The new supply interest rate, scaled by 1e18 (e.g., 0.05e18 for 5% APR).
     * @param borrowRate The new borrow interest rate, scaled by 1e18 (e.g., 0.13e18 for 13% APR).
     * @param liquidationBonus The new liquidation bonus, scaled by 1e4 (e.g., 10500 for 5% bonus).
     */
    function setInterestRate(
        address token,
        uint256 supplyRate,
        uint256 borrowRate,
        uint256 liquidationBonus
    ) external onlyFundManager nonZeroAddress(token) {
        if (!tokenConfigs[token].isSupported) {
            revert ISLoanEngine__TokenNotSupported();
        }
        if (supplyRate > 1e18 || borrowRate > 1e18) {
            revert ISLoanEngine__InvalidInterestRate();
        }

        _accrueInterest(token);

        TokenConfig storage cfg = tokenConfigs[token];
        cfg.supplyInterestRate = supplyRate;
        cfg.borrowInterestRate = borrowRate;
        cfg.liquidationBonus = liquidationBonus;

        emit InterestRatesUpdated(
            token,
            supplyRate,
            borrowRate,
            liquidationBonus
        );
    }

    /**
     * @notice Sets the interest rates and liquidation bonus for multiple tokens at once. This will set the same rates for all specified tokens.
     * @dev Only callable by an approved fund manager. Each token must be supported.
     * @param tokens A list of token addresses to update.
     * @param supplyInterestRate The new supply interest rate, scaled by 1e18 (e.g., 0.05e18 for 5% APR).
     * @param borrowInterestRate The new borrow interest rate, scaled by 1e18 (e.g., 0.13e18 for 13% APR).
     * @param liquidationBonus The new liquidation bonus, scaled by 1e4 (e.g., 10500 for 5% bonus).
     */
    function setInterestRates(
        address[] calldata tokens,
        uint256 supplyInterestRate,
        uint256 borrowInterestRate,
        uint256 liquidationBonus
    ) external onlyFundManager {
        if (supplyInterestRate > 1e18 || borrowInterestRate > 1e18) {
            revert ISLoanEngine__InvalidInterestRate();
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (!tokenConfigs[token].isSupported) {
                revert ISLoanEngine__TokenNotSupported();
            }
            _accrueInterest(token);

            TokenConfig storage cfg = tokenConfigs[token];
            cfg.supplyInterestRate = supplyInterestRate;
            cfg.borrowInterestRate = borrowInterestRate;
            cfg.liquidationBonus = liquidationBonus;

            emit InterestRatesUpdated(
                token,
                supplyInterestRate,
                borrowInterestRate,
                liquidationBonus
            );
        }
    }

    /**
     * @notice Adds a new token to the list of supported tokens for borrowing and lending.
     * @dev Only callable by an approved fund manager. The token must not already be supported
     * @param token The address of the token to be added.
     * @param factor The collateral factor for the token, scaled by 1e4 (e.g., 7500 = 75%).
     * @param chainlinkFeed The price feed address for the token (Chainlink).
     * @param pythAddress The Pyth oracle contract address.
     * @param pythPriceId The Pyth price ID for the token.
     */
    function addToken(
        address token,
        uint256 factor,
        address chainlinkFeed,
        address pythAddress,
        bytes32 pythPriceId
    )
        external
        onlyFundManager
        nonZeroAddress(token)
        nonZeroAddress(chainlinkFeed)
        nonZeroAddress(pythAddress)
        moreThanZero(factor)
    {
        if (factor >= 1e4)
            revert ISLoanEngine__AmountMustNotBeMoreThanOneHundredPercent();

        TokenConfig storage cfg = tokenConfigs[token];
        cfg.isSupported = true;
        cfg.collateralFactor = factor;
        cfg.oracle = OracleLib.OracleConfig({
            chainlinkFeed: AggregatorV3Interface(chainlinkFeed),
            pythFeed: IPyth(pythAddress),
            pythPriceId: pythPriceId
        });
        cfg.decimals = IERC20Metadata(token).decimals();

        cfg.supplyIndex = 1e18;
        cfg.borrowIndex = 1e18;
        cfg.lastUpdate = uint40(block.timestamp);
        cfg.supplyInterestRate = 0.05e18; // 5% APR
        cfg.borrowInterestRate = 0.13e18; // 13% APR
        cfg.liquidationBonus = 10500; // 5% bonus

        supportedTokens.add(token);
        emit TokenAdded(token, factor, block.timestamp);
    }

    /**
     * @notice Removes a token from the list of supported tokens.
     * @param token The address of the token to be removed.
     * @dev Only callable by an approved fund manager. The token must be currently supported.
     */
    function removeToken(address token) external onlyFundManager {
        if (!tokenConfigs[token].isSupported) {
            revert ISLoanEngine__TokenNotSupported();
        }
        delete tokenConfigs[token];
        supportedTokens.remove(token);
        emit TokenRemoved(token, block.timestamp);
    }

    ////////////////////////////////////
    //      Utility View Functions    //
    ////////////////////////////////////

    /**
     * @notice This function calculates the available liquidity for a given token
     * by subtracting the total borrowed amount from the total deposited amount.
     * It provides insight into how much of the token is currently available for
     * borrowing or withdrawal.
     * @param token The address of the token to check liquidity for.
     * @return The available liquidity of the specified token in its raw units.
     */
    function availableLiquidity(address token) public view returns (uint256) {
        return totalDeposits[token] - totalBorrows[token];
    }

    /**
     * @notice This function calculates the borrow limit for a user based on the
     * total value of their collateral. It sums up the USD value of all collateral
     * assets held by the user, adjusted by their respective collateral factors.
     * The resulting value represents the maximum amount the user can borrow
     * against their collateral.
     * @param user The address of the user for whom to calculate the borrow limit.
     * @return limitUsd The maximum borrow limit in USD for the specified user.
     */
    function getBorrowLimit(
        address user
    ) public view returns (uint256 limitUsd) {
        return getCollateralValue(user);
    }

    /**
     * @notice This function calculates the health factor for a user, which is a measure
     * of the user's collateralization status. It is computed as the ratio of the user's
     * total collateral value to their total debt value.
     *
     * @dev
     * - A health factor >= 1e18 (i.e., >= 1.0) means the user is considered safe and cannot
     *   be liquidated.
     * - A health factor < 1e18 (i.e., < 1.0) means the user is undercollateralized and
     *   is eligible for liquidation.
     *
     * @param user The address of the user for whom to calculate the health factor.
     * @return healthFactor The health factor of the specified user, scaled by 1e18.
     */
    function getHealthFactor(address user) public view returns (uint256) {
        uint256 debtUsd = getDebtValue(user);
        if (debtUsd == 0) return type(uint256).max;

        uint256 weightedCollateralUsd = 0;
        address[] memory tokens = supportedTokens.values();

        for (uint256 i = 0; i < tokens.length; i++) {
            TokenConfig memory cfg = tokenConfigs[tokens[i]];
            uint256 scaledBalance = deposits[user][tokens[i]];
            if (scaledBalance == 0 || !cfg.isSupported) continue;

            uint256 balance = (scaledBalance * cfg.supplyIndex) / 1e18;
            uint256 normalized = _normalizeTo18(balance, cfg.decimals);
            uint256 price = cfg.oracle.getPrice();
            uint256 usdValue = (normalized * price) / 1e18;
            uint256 adjusted = (usdValue * cfg.collateralFactor) / 1e4;

            weightedCollateralUsd += adjusted;
        }

        return (weightedCollateralUsd * 1e18) / debtUsd;
    }

    ////////////////////////////////////
    //       Pause Functions          //
    ////////////////////////////////////

    /**
     * @notice Pauses the contract, disabling all state-changing functions.
     * Can only be called by the contract owner.
     */
    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender, block.timestamp);
    }

    /**
     * @notice Unpauses the contract, enabling all state-changing functions.
     * Can only be called by the contract owner.
     */
    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender, block.timestamp);
    }

    ////////////////////////////////////
    //  Internal/Private Functions    //
    ////////////////////////////////////

    /**
     * @notice This function normalizes a given amount of a token to 18 decimals.
     * It takes into account the token's original decimals and adjusts the amount
     * accordingly. This is useful for standardizing calculations across tokens
     * with different decimal places.
     * @param amount amount in token's native decimals
     * @param decimals the decimals of the token
     * @return normalized amount scaled to 18 decimals
     */
    function _normalizeTo18(
        uint256 amount,
        uint8 decimals
    ) private pure returns (uint256 normalized) {
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount * (10 ** (18 - decimals));
        } else {
            return amount / (10 ** (decimals - 18));
        }
    }

    /**
     * @notice This function denormalizes a given amount from 18 decimals back to
     * the token's original decimal format. It adjusts the amount based on the
     * token's decimals, allowing for accurate representation in its native form.
     * @param amount amount scaled to 18 decimals
     * @param decimals the decimals of the token
     * @return denormalized amount in token's native decimals
     */
    function _denormalizeFrom18(
        uint256 amount,
        uint8 decimals
    ) private pure returns (uint256 denormalized) {
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount / (10 ** (18 - decimals));
        } else {
            return amount * (10 ** (decimals - 18));
        }
    }

    /**
     * @notice Accrues interest for a given token by updating its supply and borrow indices.
     * @dev
     * - This function compounds interest for both suppliers and borrowers based on the elapsed time
     *   since the last update.
     * - It calculates the per-second interest rates from the annualized rates, then applies
     *   compound interest using exponentiation-by-squaring (`_rpow`).
     * - The updated indices (`supplyIndex` and `borrowIndex`) are scaled by 1e18 to maintain precision.
     * - Updates the `lastUpdate` timestamp to the current block time.
     * @param token The address of the token for which interest is accrued.
     */
    function _accrueInterest(address token) private {
        TokenConfig storage cfg = tokenConfigs[token];
        if (!cfg.isSupported) return; // If token not supported, skip

        uint40 currentTime = uint40(block.timestamp);
        uint40 dt = currentTime - cfg.lastUpdate;
        if (dt == 0) return; // If no time has passed, skip

        uint256 supplyRatePerSecond = cfg.supplyInterestRate / SECONDS_PER_YEAR; // Interest rate per second
        uint256 borrowRatePerSecond = cfg.borrowInterestRate / SECONDS_PER_YEAR; // Interest rate per second

        uint256 supplyFactor = _rpow(1e18 + supplyRatePerSecond, dt, 1e18);
        uint256 borrowFactor = _rpow(1e18 + borrowRatePerSecond, dt, 1e18);

        cfg.supplyIndex = (cfg.supplyIndex * supplyFactor) / 1e18;
        cfg.borrowIndex = (cfg.borrowIndex * borrowFactor) / 1e18;

        cfg.lastUpdate = currentTime;

        emit InterestAccrued(
            token,
            cfg.supplyIndex,
            cfg.borrowIndex,
            currentTime
        );
    }

    /**
     * @notice Accrues interest for all supported tokens by iterating through the list
     * of supported tokens and calling the internal _accrueInterest function for each.
     * This ensures that interest is updated across all markets in a single operation.
     */
    function _accrueAllInterest() private {
        address[] memory tokens = supportedTokens.values();
        for (uint256 i = 0; i < tokens.length; i++) {
            _accrueInterest(tokens[i]);
        }
    }

    /**
     * @notice Computes exponentiation with a fixed-point base using exponentiation by squaring.
     * @dev
     * - This function efficiently calculates (x^n) / base^(log_base) where `base` defines
     *   the scaling factor (commonly 1e18 for fixed-point math).
     * - Used in interest accrual to compound rates per second over elapsed time.
     * - Implements the "exponentiation by squaring" algorithm for gas efficiency.
     *
     * Example:
     *  - If x = 1e18 + ratePerSecond, n = seconds elapsed, base = 1e18,
     *    then the output z = (x^n) / (1e18^(n-1)) gives the compounded factor.
     *
     * @param x The base multiplier, typically (1e18 + ratePerSecond).
     * @param n The exponent, typically the number of elapsed seconds.
     * @param base The scaling factor (e.g., 1e18 for 18-decimal fixed point).
     * @return z The result of (x^n) scaled by `base`.
     */
    function _rpow(
        uint256 x,
        uint256 n,
        uint256 base
    ) internal pure returns (uint256 z) {
        z = base;
        while (n > 0) {
            if (n % 2 != 0) {
                z = (z * x) / base;
            }
            x = (x * x) / base;
            n /= 2;
        }
    }

    ////////////////////////////////////
    //     Refresh Interest Function  //
    ////////////////////////////////////

    /**
     * @notice Refreshes interest for all supported tokens by calling the internal _accrueAllInterest function.
     * This function can only be called by an approved fund manager. It iterates through all
     * supported tokens and updates their interest indices to ensure that the interest calculations
     * are up-to-date.
     */
    function refreshAllTokens()
        external
        onlyFundManager
        nonReentrant
        whenNotPaused
    {
        _accrueAllInterest();
        emit AllInterestRefreshed(block.timestamp);
    }
}
