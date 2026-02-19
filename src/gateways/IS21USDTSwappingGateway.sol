// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title IS21USDTSwappingGateway
 * @author InterShare Team
 *
 * @notice
 * Handles user-facing USDT <-> IS21 swaps using signed quotes.
 * USDT custody is INTERNAL and separated into:
 *  - pendingMintUSDT  (user deposits, fund managers withdraw)
 *  - availableBurnUSDT (fund managers deposit, users withdraw)
 */

struct FiatReserves {
    bytes32 currency;
    uint256 amount;
}

interface IIS21FundManagerGateway {
    function mintWithReservesIncrease(
        address to,
        FiatReserves[] calldata reserveIncreases,
        uint256 mintAmount
    ) external;

    function burnWithReservesDecrease(
        address from,
        FiatReserves[] calldata reserveDecreases,
        uint256 burnAmount
    ) external;
}

contract IS21USDTSwappingGateway is EIP712, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    ///////////////
    // Errors    //
    ///////////////
    error IS21SG__InvalidSignature();
    error IS21SG__ExpiredQuote();
    error IS21SG__NotZeroAddress();
    error IS21SG__InvalidAmount();
    error IS21SG__NonceUsed();
    error IS21SG__InsufficientBurnLiquidity();
    error IS21SG__ZeroAddress();
    error IS21SG__InvalidWallet();
    error IS21SG__OnlyFundManagerCanExecute();

    //////////////////
    // Structs      //
    //////////////////
    struct MintQuote {
        address wallet;
        uint256 usdtAmount; // USDT
        uint256 is21Amount; // IS21
        uint256 nonce;
        uint256 expiry;
    }

    struct BurnQuote {
        address wallet;
        uint256 is21Amount; // IS21
        uint256 usdtAmount; // USDT
        uint256 nonce;
        uint256 expiry;
    }

    /////////////////////
    // Constants       //
    /////////////////////
    bytes32 private constant CURRENCY_USDT = bytes32("USDT");
    bytes32 private constant ACTION_MINT = keccak256("MINT");
    bytes32 private constant ACTION_BURN = keccak256("BURN");
    bytes32 private constant MINT_TYPEHASH =
        keccak256(
            "MintQuote(address wallet,uint256 usdtAmount,uint256 is21Amount,uint256 nonce,uint256 expiry)"
        );
    bytes32 private constant BURN_TYPEHASH =
        keccak256(
            "BurnQuote(address wallet,uint256 is21Amount,uint256 usdtAmount,uint256 nonce,uint256 expiry)"
        );

    /////////////////////
    // State Variables //
    /////////////////////
    string public constant IS21_SWAP_VERSION = "1.0.0";

    IERC20 public immutable usdt;
    IIS21FundManagerGateway public immutable fundManagerGateway;
    address public immutable trustedSigner;
    EnumerableSet.AddressSet private sFundManagers;

    // --- Liquidity accounting ---
    uint256 public pendingMintUSDT;
    uint256 public availableBurnUSDT;

    // Replay protection
    mapping(address => mapping(uint256 => bool)) private sUsedNonces;

    ////////////
    // Events //
    ////////////
    event MintExecuted(
        address indexed user,
        uint256 usdtIn,
        uint256 is21Out,
        uint256 timestamp
    );

    event BurnExecuted(
        address indexed user,
        uint256 is21In,
        uint256 usdtOut,
        uint256 timestamp
    );

    event BurnUSDTDeposited(uint256 amount, uint256 timestamp);
    event MintUSDTWithdrawn(uint256 amount, uint256 timestamp);
    event GatewayPaused(address indexed caller, uint256 timestamp);
    event GatewayUnpaused(address indexed caller, uint256 timestamp);
    event FundManagerApproved(address indexed caller, uint256 timestamp);
    event FundManagerRevoked(address indexed caller, uint256 timestamp);
    event NonceUsed(
        address indexed user,
        uint256 indexed nonce,
        bytes32 action
    );

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert IS21SG__InvalidAmount();
        }
        _;
    }

    modifier nonZeroAddress(address to) {
        if (to == address(0)) {
            revert IS21SG__NotZeroAddress();
        }
        _;
    }

    modifier onlyFundManager() {
        if (!sFundManagers.contains(msg.sender)) {
            revert IS21SG__OnlyFundManagerCanExecute();
        }
        _;
    }

    /////////////////
    // Constructor //
    /////////////////
    constructor(
        address ownerAddress,
        address _trustedSigner,
        address _usdt,
        address _fundManagerGateway
    ) EIP712("IS21USDTSwappingGateway", "1") Ownable(ownerAddress) {
        if (
            ownerAddress == address(0) ||
            _trustedSigner == address(0) ||
            _usdt == address(0) ||
            _fundManagerGateway == address(0)
        ) {
            revert IS21SG__ZeroAddress();
        }

        trustedSigner = _trustedSigner;
        usdt = IERC20(_usdt);
        fundManagerGateway = IIS21FundManagerGateway(_fundManagerGateway);
    }

    ///////////////////////////////////
    // Mint: USDT -> IS21             //
    ///////////////////////////////////
    function mintWithQuote(
        MintQuote calldata quote,
        bytes calldata signature
    )
        external
        nonReentrant
        whenNotPaused
        nonZeroAddress(quote.wallet)
        moreThanZero(quote.usdtAmount)
        moreThanZero(quote.is21Amount)
    {
        if (quote.wallet != msg.sender) {
            revert IS21SG__InvalidWallet();
        }
        if (block.timestamp > quote.expiry) {
            revert IS21SG__ExpiredQuote();
        }
        if (sUsedNonces[msg.sender][quote.nonce]) {
            revert IS21SG__NonceUsed();
        }

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    MINT_TYPEHASH,
                    quote.wallet,
                    quote.usdtAmount,
                    quote.is21Amount,
                    quote.nonce,
                    quote.expiry
                )
            )
        );

        if (ECDSA.recover(digest, signature) != trustedSigner) {
            revert IS21SG__InvalidSignature();
        }

        sUsedNonces[msg.sender][quote.nonce] = true;
        emit NonceUsed(msg.sender, quote.nonce, ACTION_MINT);

        // --- Custody USDT ---
        usdt.safeTransferFrom(msg.sender, address(this), quote.usdtAmount);
        pendingMintUSDT += quote.usdtAmount;

        // --- Mint through Fund Manager Gateway ---
        FiatReserves[] memory reserves = new FiatReserves[](1);

        reserves[0] = FiatReserves({
            currency: CURRENCY_USDT,
            amount: quote.usdtAmount
        });

        fundManagerGateway.mintWithReservesIncrease(
            msg.sender,
            reserves,
            quote.is21Amount
        );

        emit MintExecuted(
            msg.sender,
            quote.usdtAmount,
            quote.is21Amount,
            block.timestamp
        );
    }

    ///////////////////////////////////
    // Burn: IS21 -> USDT             //
    ///////////////////////////////////
    function burnWithQuote(
        BurnQuote calldata quote,
        bytes calldata signature
    )
        external
        nonReentrant
        whenNotPaused
        nonZeroAddress(quote.wallet)
        moreThanZero(quote.usdtAmount)
        moreThanZero(quote.is21Amount)
    {
        if (quote.wallet != msg.sender) {
            revert IS21SG__InvalidWallet();
        }
        if (block.timestamp > quote.expiry) {
            revert IS21SG__ExpiredQuote();
        }
        if (sUsedNonces[msg.sender][quote.nonce]) {
            revert IS21SG__NonceUsed();
        }
        if (quote.usdtAmount > availableBurnUSDT) {
            revert IS21SG__InsufficientBurnLiquidity();
        }

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    BURN_TYPEHASH,
                    quote.wallet,
                    quote.is21Amount,
                    quote.usdtAmount,
                    quote.nonce,
                    quote.expiry
                )
            )
        );

        if (ECDSA.recover(digest, signature) != trustedSigner) {
            revert IS21SG__InvalidSignature();
        }

        // Lock nonce - used
        sUsedNonces[msg.sender][quote.nonce] = true;
        emit NonceUsed(msg.sender, quote.nonce, ACTION_BURN);

        availableBurnUSDT -= quote.usdtAmount;

        // --- Burn through Fund Manager Gateway ---
        FiatReserves[] memory reserves = new FiatReserves[](1);

        reserves[0] = FiatReserves({
            currency: CURRENCY_USDT,
            amount: quote.usdtAmount
        });

        fundManagerGateway.burnWithReservesDecrease(
            msg.sender,
            reserves,
            quote.is21Amount
        );

        usdt.safeTransfer(msg.sender, quote.usdtAmount);

        emit BurnExecuted(
            msg.sender,
            quote.is21Amount,
            quote.usdtAmount,
            block.timestamp
        );
    }

    ///////////////////////////////////
    // Fund Manager Settlement        //
    ///////////////////////////////////
    function withdrawMintUSDT(
        address to,
        uint256 amount
    ) external onlyFundManager whenNotPaused nonReentrant {
        if (amount == 0 || amount > pendingMintUSDT)
            revert IS21SG__InvalidAmount();

        pendingMintUSDT -= amount;
        usdt.safeTransfer(to, amount);

        emit MintUSDTWithdrawn(amount, block.timestamp);
    }

    function depositBurnUSDT(
        uint256 amount
    ) external onlyFundManager whenNotPaused nonReentrant {
        if (amount == 0) revert IS21SG__InvalidAmount();

        usdt.safeTransferFrom(msg.sender, address(this), amount);
        availableBurnUSDT += amount;

        emit BurnUSDTDeposited(amount, block.timestamp);
    }

    ///////////////////////////////////
    // Admin Controls                //
    ///////////////////////////////////
    /**
        This function allows the owner to approve a fund manager.
        @param fundManager The address of the fund manager to be approved.
        @notice This function can only be called by the current owner and is protected against reentrancy attacks.
        @dev It updates the mapping of approved fund managers and emits an event for tracking purposes.
    */
    function approveFundManager(
        address fundManager
    ) external onlyOwner nonZeroAddress(fundManager) nonReentrant {
        if (sFundManagers.add(fundManager)) {
            emit FundManagerApproved(fundManager, block.timestamp);
        }
    }

    /** 
        This function allows the owner to revoke a fund manager's approval.
        @param fundManager The address of the fund manager to be revoked.
        @notice This function can only be called by the current owner and is protected against reentrancy attacks.
        @dev It updates the mapping of approved fund managers and emits an event for tracking purposes.
    */
    function revokeFundManager(
        address fundManager
    ) external onlyOwner nonZeroAddress(fundManager) nonReentrant {
        if (sFundManagers.remove(fundManager)) {
            emit FundManagerRevoked(fundManager, block.timestamp);
        }
    }

    /**
        This function retrieves the list of all approved fund managers.
        @return An array of addresses representing the approved fund managers.
        @notice This function is view-only and does not modify the state of the contract.
        @dev It can be used to get a list of all fund managers for administrative or informational purposes.
    */
    function getFundManagers() external view returns (address[] memory) {
        return sFundManagers.values();
    }

    function pause() external onlyOwner {
        _pause();
        emit GatewayPaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit GatewayUnpaused(msg.sender, block.timestamp);
    }

    ///////////////////////////////////
    // Views                          //
    ///////////////////////////////////
    function isNonceUsed(
        address user,
        uint256 nonce
    ) external view returns (bool) {
        return sUsedNonces[user][nonce];
    }

    function getFundManagerGateway() external view returns (address) {
        return address(fundManagerGateway);
    }
}
