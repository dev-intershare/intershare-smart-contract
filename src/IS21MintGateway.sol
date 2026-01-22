// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IS21MintGateway
 * @author InterShare Team
 *
 */

interface IIS21Engine {
    function mintIs21To(address to, uint256 amount) external;
}

contract IS21MintGateway is EIP712, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ///////////////
    // Errors    //
    ///////////////
    error IS21MintGateway__ExpiredQuote();
    error IS21MintGateway__InvalidSignature();
    error IS21MintGateway__QuoteAlreadyUsed();
    error IS21MintGateway__InvalidWallet();
    error IS21MintGateway__InvalidTokenContract();
    error IS21MintGateway__NotZeroAddress();
    error IS21MintGateway__InvalidAmount();

    //////////////////
    // Structs      //
    //////////////////
    struct MintQuote {
        address wallet;
        uint256 depositAmount;
        uint256 is21Amount;
        uint256 nav;
        uint256 nonce;
        uint256 expiry;
    }

    /////////////////////
    // State Variables //
    /////////////////////
    bytes32 private constant MINT_TYPEHASH =
        keccak256(
            "MintQuote(address wallet,uint256 depositAmount,uint256 is21Amount,uint256 nav,uint256 nonce,uint256 expiry)"
        );

    address public immutable trustedSigner;
    IIS21Engine public immutable is21;
    IERC20 public immutable usdt;

    mapping(address => mapping(uint256 => bool)) private sUsedNonces;

    ////////////
    // Events //
    ////////////
    event IS21MintExecuted(
        address indexed wallet,
        uint256 usdtAmount,
        uint256 is21Amount,
        uint256 nav,
        uint256 nonce,
        uint256 timestamp
    );

    event TreasuryWithdrawal(
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );

    /////////////////
    // Constructor //
    /////////////////

    /** 
        @param ownerAddress The address of the owner of the contract.
        @param _trustedSigner The address who can signs mint actions.
        @param _usdt The USDT contract address.
        @param _is21 The IS21 contract address.
        @notice The owner address cannot be zero.
        @notice The contract is initialized with the name "InterShare21" and symbol "IS21".
        @dev The contract uses OpenZeppelin's ERC20 implementation for token functionality.
        @dev The constructor initializes the contract with the owner's address.
    */
    constructor(
        address ownerAddress,
        address _trustedSigner,
        address _usdt,
        address _is21
    ) EIP712("IS21MintGateway", "1") Ownable(ownerAddress) {
        if (ownerAddress == address(0)) {
            revert IS21MintGateway__NotZeroAddress();
        }

        if (_trustedSigner == address(0)) {
            revert IS21MintGateway__NotZeroAddress();
        }

        if (_usdt == address(0)) {
            revert IS21MintGateway__NotZeroAddress();
        }

        if (_is21 == address(0)) {
            revert IS21MintGateway__NotZeroAddress();
        }

        trustedSigner = _trustedSigner;
        usdt = IERC20(_usdt);
        is21 = IIS21Engine(_is21);
    }

    ///////////////////////////////////
    //  External/Public Functions    //
    ///////////////////////////////////
    function mintWithQuote(
        MintQuote calldata quote,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (quote.wallet != msg.sender) {
            revert IS21MintGateway__InvalidWallet();
        }

        if (block.timestamp > quote.expiry) {
            revert IS21MintGateway__ExpiredQuote();
        }

        if (sUsedNonces[quote.wallet][quote.nonce]) {
            revert IS21MintGateway__QuoteAlreadyUsed();
        }

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    MINT_TYPEHASH,
                    quote.wallet,
                    quote.depositAmount,
                    quote.is21Amount,
                    quote.nav,
                    quote.nonce,
                    quote.expiry
                )
            )
        );

        address recovered = ECDSA.recover(digest, signature);
        if (recovered != trustedSigner) {
            revert IS21MintGateway__InvalidSignature();
        }

        if (quote.depositAmount == 0 || quote.is21Amount == 0) {
            revert IS21MintGateway__InvalidAmount();
        }

        sUsedNonces[quote.wallet][quote.nonce] = true;

        // Transfer USDT from user to this contract
        usdt.safeTransferFrom(msg.sender, address(this), quote.depositAmount);

        // Mint IS21 to user
        is21.mintIs21To(msg.sender, quote.is21Amount);

        emit IS21MintExecuted(
            msg.sender,
            quote.depositAmount,
            quote.is21Amount,
            quote.nav,
            quote.nonce,
            block.timestamp
        );
    }

    function isNonceUsed(
        address wallet,
        uint256 nonce
    ) external view returns (bool) {
        return sUsedNonces[wallet][nonce];
    }

    /////////////////////////
    //  Admin Functions    //
    /////////////////////////
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueERC20(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(to, amount);
    }

    function withdrawUSDT(
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        usdt.safeTransfer(to, amount);
        emit TreasuryWithdrawal(to, amount, block.timestamp);
    }
}
