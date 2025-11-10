// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {TokenConfig} from "./types/ISLoanTypes.sol";

/**
 * @title ISLoanConfig
 * @author BlueAsset Technology Team
 *
 * @notice Configuration and risk management module for the InterShare Lending Protocol.
 * Handles:
 * - Fund manager role assignment and revocation.
 * - Supported token registration and removal.
 * - Collateral factor and interest rate parameter updates.
 *
 * @dev
 * Designed for modular integration into ISLoanEngine or other governance systems.
 * It holds no state-changing logic related to lending, borrowing, or accounting —
 * only configuration and governance controls.
 */
contract ISLoanConfig is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /////////////////////
    // Errors          //
    /////////////////////
    error ISLoanConfig__AmountMustBeMoreThanZero();
    error ISLoanConfig__AmountMustNotBeMoreThanOneHundredPercent();
    error ISLoanConfig__InvalidInterestRate();
    error ISLoanConfig__NotZeroAddress();
    error ISLoanConfig__TokenAlreadySupported();
    error ISLoanConfig__TokenNotSupported();
    error ISLoanConfig__OnlyFundManagerCanExecute();

    /////////////////////
    // Constants       //
    /////////////////////
    string public constant IS_VERSION = "1.0.0";
    uint256 private constant MAX_BPS = 1e4;
    uint256 private constant MAX_RATE = 1e18;

    /////////////////////
    // State Variables //
    /////////////////////
    EnumerableSet.AddressSet internal sFundManagers;
    mapping(address => TokenConfig) internal tokenConfigs;
    EnumerableSet.AddressSet internal supportedTokens;

    /////////////////////
    // Events          //
    /////////////////////
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

    /////////////////////
    // Modifiers       //
    /////////////////////
    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ISLoanConfig__NotZeroAddress();
        _;
    }

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert ISLoanConfig__AmountMustBeMoreThanZero();
        _;
    }

    modifier onlyFundManager() {
        if (!sFundManagers.contains(msg.sender)) {
            revert ISLoanConfig__OnlyFundManagerCanExecute();
        }
        _;
    }

    modifier onlySupportedToken(address token) {
        if (!tokenConfigs[token].isSupported)
            revert ISLoanConfig__TokenNotSupported();
        _;
    }

    /////////////////////
    // Constructor     //
    /////////////////////
    constructor(address ownerAddress) Ownable(ownerAddress) {
        if (ownerAddress == address(0)) revert ISLoanConfig__NotZeroAddress();
    }

    /////////////////////////////
    // Fund Manager Management //
    /////////////////////////////

    function approveFundManager(
        address fundManager
    ) external onlyOwner nonZeroAddress(fundManager) {
        if (sFundManagers.add(fundManager)) {
            emit FundManagerApproved(fundManager, block.timestamp);
        }
    }

    function revokeFundManager(
        address fundManager
    ) external onlyOwner nonZeroAddress(fundManager) {
        if (sFundManagers.remove(fundManager)) {
            emit FundManagerRevoked(fundManager, block.timestamp);
        }
    }

    function getFundManagers() external view returns (address[] memory) {
        return sFundManagers.values();
    }

    function isFundManager(address account) external view returns (bool) {
        return sFundManagers.contains(account);
    }

    /////////////////////////////
    // Token Configuration     //
    /////////////////////////////

    function addToken(
        address token,
        uint256 factor,
        address chainlinkFeed,
        address pythAddress,
        bytes32 pythPriceId,
        uint256 supplyInterestRate,
        uint256 borrowInterestRate
    )
        external
        onlyFundManager
        nonZeroAddress(token)
        nonZeroAddress(chainlinkFeed)
        nonZeroAddress(pythAddress)
        moreThanZero(factor)
    {
        if (factor >= MAX_BPS)
            revert ISLoanConfig__AmountMustNotBeMoreThanOneHundredPercent();
        if (supplyInterestRate > MAX_RATE || borrowInterestRate > MAX_RATE)
            revert ISLoanConfig__InvalidInterestRate();
        if (tokenConfigs[token].isSupported)
            revert ISLoanConfig__TokenAlreadySupported();

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
        cfg.supplyInterestRate = supplyInterestRate;
        cfg.borrowInterestRate = borrowInterestRate;
        cfg.liquidationBonus = 10500; // default 5% bonus

        supportedTokens.add(token);
        emit TokenAdded(token, factor, block.timestamp);
    }

    function removeToken(
        address token
    ) external onlyFundManager nonZeroAddress(token) {
        if (!tokenConfigs[token].isSupported)
            revert ISLoanConfig__TokenNotSupported();
        delete tokenConfigs[token];
        supportedTokens.remove(token);
        emit TokenRemoved(token, block.timestamp);
    }

    function setCollateralFactor(
        address token,
        uint256 newFactor
    ) external onlyFundManager moreThanZero(newFactor) nonZeroAddress(token) {
        if (!tokenConfigs[token].isSupported)
            revert ISLoanConfig__TokenNotSupported();
        if (newFactor >= MAX_BPS)
            revert ISLoanConfig__AmountMustNotBeMoreThanOneHundredPercent();

        uint256 old = tokenConfigs[token].collateralFactor;
        tokenConfigs[token].collateralFactor = newFactor;
        emit CollateralFactorUpdated(token, old, newFactor);
    }

    function setInterestRate(
        address token,
        uint256 newSupplyRate,
        uint256 newBorrowRate,
        uint256 liquidationBonus
    ) external onlyFundManager nonZeroAddress(token) {
        if (!tokenConfigs[token].isSupported)
            revert ISLoanConfig__TokenNotSupported();
        if (newSupplyRate > MAX_RATE || newBorrowRate > MAX_RATE)
            revert ISLoanConfig__InvalidInterestRate();

        TokenConfig storage cfg = tokenConfigs[token];
        cfg.supplyInterestRate = newSupplyRate;
        cfg.borrowInterestRate = newBorrowRate;
        cfg.liquidationBonus = liquidationBonus;

        emit InterestRatesUpdated(
            token,
            newSupplyRate,
            newBorrowRate,
            liquidationBonus
        );
    }

    /////////////////////////////
    // View Functions          //
    /////////////////////////////

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens.values();
    }

    function getTokenConfig(
        address token
    ) external view returns (TokenConfig memory) {
        return tokenConfigs[token];
    }
}
