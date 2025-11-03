// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Public struct for fiat reserve metadata
struct FiatReserves {
    bytes32 currency; // The currency code (e.g., "USD", "EUR", "ZAR").
    uint256 amount; // The amount of fiat in the smallest unit (e.g., cents).
}

/**
 * @title IS21Engine
 * @author BlueAsset Technology Team
 *
 * @notice The IS21Engine contract is the foundation of the InterShare21 reserve currency system.
 * It governs the issuance and management of InterShare21 (IS21) tokens, a decentralized,
 * exogenously collateralized, fiat-backed currency. It is the official token contract for IS21 and
 * for the InterShare Loan Engine (ISLoanEngine).
 *
 * @dev Key Principles:
 * - Exogenously Collateralized: Backed by external fiat reserves stored in trusted institutions.
 * - Fiat Backed: Each IS21 token corresponds to reserves of major global fiat currencies.
 * - Managed Supply: IS21 tokens are minted or burned in response to verified reserve changes.
 * - Transparent Verification: Approved auditors publish proof-of-reserve reports (e.g., via IPFS/Arweave),
 *   and fund managers ensure reserves remain adequate.
 *
 * @dev Contract Capabilities:
 * - Minting and burning of IS21 tokens by approved fund managers.
 * - Approval and revocation of auditors and fund managers.
 * - Recording and publishing of off-chain reserve proof hashes.
 * - Fiat reserve tracking across multiple currencies.
 * - Pausable contract functionality for added security.
 *
 * @notice IS21 is designed as a global reserve currency system to provide stability,
 * transparency, and decentralization in financial ecosystems.
 */

contract IS21Engine is
    ERC20,
    ERC20Permit,
    ReentrancyGuard,
    ERC20Pausable,
    Ownable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    ///////////////
    // Errors    //
    ///////////////
    error IS21Engine__AmountMustBeMoreThanZero();
    error IS21Engine__BurnAmountExceedsBalance();
    error IS21Engine__NotZeroAddress();
    error IS21Engine__OnlyFundManagerCanExecute();
    error IS21Engine__OnlyAuditorCanExecute();
    error IS21Engine__ETHNotAccepted();
    error IS21Engine__CannotSendToContract();

    /////////////////////
    // State Variables //
    /////////////////////
    string public constant IS21_VERSION = "1.0.0"; // Semantic versioning for the IS21Engine contract
    mapping(bytes32 => uint256) private sCurrencyToReserve;
    EnumerableSet.AddressSet private sFundManagers;
    EnumerableSet.AddressSet private sAuditors;
    string private sLatestReserveProofHash;

    ////////////
    // Events //
    ////////////
    event IS21Minted(address indexed to, uint256 amount);
    event IS21Burned(address indexed from, uint256 amount);
    event AuditorApproved(address indexed auditor, uint256 timestamp);
    event AuditorRevoked(address indexed auditor, uint256 timestamp);
    event FundManagerApproved(address indexed fundManager, uint256 timestamp);
    event FundManagerRevoked(address indexed fundManager, uint256 timestamp);
    event ContractPaused(address indexed caller, uint256 timestamp);
    event ContractUnpaused(address indexed caller, uint256 timestamp);
    event ReserveVerified(
        address indexed auditor,
        uint256 timestamp,
        string message
    );
    event FiatReserveUpdated(
        address indexed fundManager,
        bytes32 indexed currency,
        uint256 amount,
        uint256 timestamp
    );
    event ReserveProofHashUpdated(
        address indexed auditor,
        string oldHash,
        string newHash,
        uint256 timestamp
    );

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert IS21Engine__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier nonZeroAddress(address to) {
        if (to == address(0)) {
            revert IS21Engine__NotZeroAddress();
        }
        _;
    }

    modifier onlyFundManager() {
        if (!sFundManagers.contains(msg.sender)) {
            revert IS21Engine__OnlyFundManagerCanExecute();
        }
        _;
    }

    modifier onlyAuditor() {
        if (!sAuditors.contains(msg.sender)) {
            revert IS21Engine__OnlyAuditorCanExecute();
        }
        _;
    }

    modifier cannotSendToContract(address to) {
        if (to == address(this)) {
            revert IS21Engine__CannotSendToContract();
        }
        _;
    }

    /////////////////
    // Constructor //
    /////////////////

    /** 
        @param ownerAddress The address of the owner of the contract.
        @notice The owner address cannot be zero.
        @notice The contract is initialized with the name "InterShare21" and symbol "IS21".
        @dev The contract uses OpenZeppelin's ERC20 implementation for token functionality.
        @dev The constructor initializes the contract with the owner's address.
    */
    constructor(
        address ownerAddress
    )
        ERC20("InterShare21", "IS21")
        ERC20Permit("InterShare21")
        Ownable(ownerAddress)
    {
        if (ownerAddress == address(0)) {
            revert IS21Engine__NotZeroAddress();
        }
    }

    ///////////////////////////////////
    //  External/Public Functions    //
    ///////////////////////////////////

    /**
        @return The number of decimals used to get its user representation.
        @dev This function overrides the default decimals function in the ERC20 contract.
        @dev IS21 uses 18 decimals, similar to Ether and many other ERC20 tokens.
    */
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /**
        @return The current version of the IS21Engine contract as a string.
        @dev This function returns a constant string defined in the contract.
     */
    function getVersion() external pure returns (string memory) {
        return IS21_VERSION;
    }

    /**
        This function allows the owner to rescue ERC20 tokens from the contract.
        @param token The address of the ERC20 token contract.
        @param amount The amount of tokens to rescue.
        @param to The address to which the rescued tokens will be sent.
        @notice This function can only be called by the owner and is protected against reentrancy attacks.
        @dev It uses the transfer function from the IERC20 interface to send the tokens.
    */
    function rescueErc20(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner nonZeroAddress(to) nonZeroAddress(token) nonReentrant {
        IERC20(token).safeTransfer(to, amount);
    }

    /**
        Returns the latest reserve proof hash published by an auditor.
        @return The string hash (e.g., IPFS CID) pointing to the proof document.
    */
    function getLatestReserveProofHash() external view returns (string memory) {
        return sLatestReserveProofHash;
    }

    /**
        Allows an approved auditor to update the off-chain proof-of-reserve hash.
        @param newHash The IPFS or Arweave hash of the signed reserve audit report.
        @notice This function can only be called by an approved auditor.
        @dev Emits an event to log and trace reserve proof updates.
    */
    function setReserveProofHash(
        string calldata newHash
    ) external onlyAuditor nonReentrant {
        string memory oldHash = sLatestReserveProofHash;
        sLatestReserveProofHash = newHash;
        emit ReserveProofHashUpdated(
            msg.sender,
            oldHash,
            newHash,
            block.timestamp
        );
    }

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

    /**
        This function checks if an address is an approved fund manager.
        @param account The address to check for fund manager approval.
        @return A boolean indicating whether the address is an approved fund manager.
        @notice This function is view-only and does not modify the state of the contract.
        @dev It can be used to verify if an address has fund management privileges.
    */
    function isFundManager(address account) external view returns (bool) {
        return sFundManagers.contains(account);
    }

    /** 
        This function allows the owner to approve an auditor.
        @param auditor The address of the auditor to be approved.
        @notice This function can only be called by the owner and is protected against reentrancy attacks.
        @dev It updates the mapping of approved auditors and emits an event for tracking purposes.
    */
    function approveAuditor(
        address auditor
    ) external onlyOwner nonZeroAddress(auditor) nonReentrant {
        if (sAuditors.add(auditor)) {
            emit AuditorApproved(auditor, block.timestamp);
        }
    }

    /** 
        This function allows the owner to revoke an auditor's approval.
        @param auditor The address of the auditor to be revoked.
        @notice This function can only be called by the owner and is protected against reentrancy attacks.
        @dev It updates the mapping of approved auditors and emits an event for tracking purposes.
    */
    function revokeAuditor(
        address auditor
    ) external onlyOwner nonZeroAddress(auditor) nonReentrant {
        if (sAuditors.remove(auditor)) {
            emit AuditorRevoked(auditor, block.timestamp);
        }
    }

    /**
        This function retrieves the list of all approved auditors.
        @return An array of addresses representing the approved auditors.
        @notice This function is view-only and does not modify the state of the contract.
        @notice Some may currently be revoked; check isAuditor() to confirm active status.
        @dev It can be used to get a list of all auditors for administrative or informational purposes.
    */
    function getAuditors() external view returns (address[] memory) {
        return sAuditors.values();
    }

    /**
        This function checks if an address is an approved auditor.
        @param account The address to check for auditor approval.
        @return A boolean indicating whether the address is an approved auditor.
        @notice This function is view-only and does not modify the state of the contract.
        @dev It can be used to verify if an address has auditor privileges.
    */
    function isAuditor(address account) external view returns (bool) {
        return sAuditors.contains(account);
    }

    /**        
        This function allows an auditor to verify the reserves of the contract.
        @param message A string message that can be used to provide context or details about the verification.
        @notice This function can only be called by an approved auditor and is protected against reentrancy attacks.
        @dev It emits a ReserveVerified event with the auditor's address, current timestamp, and the provided message.
        @dev The auditor's address must be approved by the owner before calling this function.
    */
    function verifyReserves(
        string calldata message
    ) external onlyAuditor nonReentrant {
        emit ReserveVerified(msg.sender, block.timestamp, message);
    }

    /**
        This function allows the fund manager to update a single fiat reserve for a specific currency.
        @param currency The currency code (e.g., "USD", "EUR", "ZAR") for which the reserve is being updated.
        @param amount The amount of fiat in the smallest unit (e.g., cents) to be set as the reserve for the specified currency.
        @notice This function can only be called by the fund manager and is protected against reentrancy attacks.
        @dev It updates the mapping of currency to reserve and emits an event for tracking purposes.
    */
    function updateFiatReserve(
        bytes32 currency,
        uint256 amount
    ) external onlyFundManager nonReentrant {
        sCurrencyToReserve[currency] = amount;
        emit FiatReserveUpdated(msg.sender, currency, amount, block.timestamp);
    }

    /** This function allows the fund manager to update multiple fiat reserves at once.
        @param reserves An array of FiatReserves structs, each containing a currency code and the corresponding amount to be set as the reserve.
        @notice This function can only be called by the fund manager and is protected against reentrancy attacks.
        @dev It iterates through the array of reserves, updating the mapping of currency to reserve for each entry and emitting an event for each update.
    */
    function updateFiatReserves(
        FiatReserves[] calldata reserves
    ) external onlyFundManager nonReentrant {
        for (uint256 i = 0; i < reserves.length; ) {
            sCurrencyToReserve[reserves[i].currency] = reserves[i].amount;
            emit FiatReserveUpdated(
                msg.sender,
                reserves[i].currency,
                reserves[i].amount,
                block.timestamp
            );
            unchecked {
                ++i;
            }
        }
    }

    /**
        This function allows anyone to retrieve the fiat reserve for a specific currency.
        @param currency The currency code (e.g., "USD", "EUR", "ZAR") for which the reserve is being queried.
        @return The amount of fiat in the smallest unit (e.g., cents) that is reserved for the specified currency.
        @notice This function is view-only and does not modify the state of the contract.
    */
    function getFiatReserve(bytes32 currency) external view returns (uint256) {
        return sCurrencyToReserve[currency];
    }

    /**
        This function allows anyone to retrieve the fiat reserves for multiple currencies.
        @param currencies An array of currency codes (e.g., ["USD", "EUR", "ZAR"]) for which the reserves are being queried.
        @return An array of amounts, where each amount corresponds to the reserve for the specified currency in the same index.
        @notice This function is view-only and does not modify the state of the contract.
    */
    function getFiatReserves(
        bytes32[] calldata currencies
    ) external view returns (uint256[] memory) {
        uint256[] memory reserves = new uint256[](currencies.length);
        for (uint256 i = 0; i < currencies.length; ) {
            reserves[i] = sCurrencyToReserve[currencies[i]];
            unchecked {
                ++i;
            }
        }
        return reserves;
    }

    /**
        This function allows fund managers to mint IS21 tokens directly to their own address.
        @param amount The amount of IS21 tokens to mint.
        @notice This function can only be called by an approved fund manager, when not paused, and with a positive amount.
        @dev Equivalent to mintIs21To(msg.sender, amount).
     */
    function mintIs21(uint256 amount) external {
        mintIs21To(msg.sender, amount);
    }

    /**
        @notice Allows an approved fund manager to mint IS21 tokens directly to a specified address.
        @param to The address that will receive the minted tokens.
        @param amount The amount of IS21 tokens to mint.
        @dev Only callable by an approved fund manager, when not paused, and with a positive amount.
    **/
    function mintIs21To(
        address to,
        uint256 amount
    )
        public
        onlyFundManager
        nonZeroAddress(to)
        moreThanZero(amount)
        nonReentrant
    {
        _mintInterShare21(to, amount);
        emit IS21Minted(to, amount);
    }

    /**
        This function allows fund managers to burn IS21 tokens.
        @param amount The amount of IS21 tokens to burn.
        @notice This function can only be called by the fund manager and must be more than zero.
        @dev It checks if the sender has enough balance before burning the tokens.
        @dev It uses the _burnInterShare21 function to burn the tokens and emits an InterShare21Burned event to log the burning action.
        @dev It is protected against reentrancy attacks and can only be executed when the contract is not paused.
    */
    function burnIs21(
        uint256 amount
    ) external onlyFundManager moreThanZero(amount) nonReentrant {
        if (balanceOf(msg.sender) < amount) {
            revert IS21Engine__BurnAmountExceedsBalance();
        }

        _burnInterShare21(msg.sender, amount);
        emit IS21Burned(msg.sender, amount);
    }

    /**
        This function allows fund managers to burn IS21 tokens from a specified account.
        @param account The address from which the IS21 tokens will be burned.
        @param amount The amount of IS21 tokens to burn.
        @notice This function can only be called by the fund manager and must be more than zero.
        @dev It checks if the account has enough balance before burning the tokens.
        @dev It uses the _spendAllowance function to check and reduce the allowance, and the _burn function to burn the tokens.
        @dev It emits an InterShare21Burned event to log the burning action.
        @dev It is protected against reentrancy attacks and can only be executed when the contract is not paused.
    */
    function burnIs21From(
        address account,
        uint256 amount
    )
        external
        onlyFundManager
        moreThanZero(amount)
        nonZeroAddress(account)
        nonReentrant
    {
        _spendAllowance(account, msg.sender, amount);
        _burnInterShare21(account, amount);
        emit IS21Burned(account, amount);
    }

    /**
        This function allows the owner to pause the contract.
        @notice This function can only be called by the owner.
        @dev It uses the _pause function from the Pausable contract to pause the contract.
        @dev It emits a ContractPaused event to log the pausing action.
    */
    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender, block.timestamp);
    }

    /**
        This function allows the owner to unpause the contract.
        @notice This function can only be called by the owner.
        @dev It uses the _unpause function from the Pausable contract to unpause the contract.
        @dev It emits a ContractUnpaused event to log the unpausing action.
    */
    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender, block.timestamp);
    }

    /**
        This function specifies that the contract does not accept ETH.
        @notice It reverts any incoming ETH transactions with a custom error.
        @dev This function is used to prevent accidental ETH transfers to the contract.
    */
    receive() external payable {
        revert IS21Engine__ETHNotAccepted();
    }

    /**
        This function specifies that the contract does not accept ETH.
        @notice It reverts any incoming ETH transactions with a custom error.
        @dev This function is used to prevent accidental ETH transfers to the contract.
    */
    fallback() external payable {
        revert IS21Engine__ETHNotAccepted();
    }

    ////////////////////////////////////
    //  Internal/Private Functions    //
    ////////////////////////////////////

    /**
        This function burns InterShare21 tokens from the sender's balance.
        @param amount The amount of InterShare21 tokens to burn.
        @notice This function is private and can only be called internally.
        @dev It checks if the sender has enough balance before burning the tokens.
    */
    function _burnInterShare21(address from, uint256 amount) private {
        _burn(from, amount);
    }

    /**
        This function mints InterShare21 tokens to a specified address.
        @param to The address to which the InterShare21 tokens will be minted.
        @param amount The amount of InterShare21 tokens to mint.
        @notice This function is private and can only be called internally.
        @dev It uses the _mint function from the ERC20 contract to mint the tokens.
        @dev It includes a check to prevent minting tokens to the contract itself.
    */
    function _mintInterShare21(
        address to,
        uint256 amount
    ) private cannotSendToContract(to) {
        _mint(to, amount);
    }

    /**
        This function overrides the _update function from the ERC20 and ERC20Pausable contracts.
        It is called during token transfers, mints, and burns to ensure that the contract is not paused.
        @param from The address from which tokens are being transferred.
        @param to The address to which tokens are being transferred.
        @param value The amount of tokens being transferred.
        @dev It calls the super implementation of the _update function to perform the actual token transfer logic.
        @dev It adds a check to prevent transfers to the token contract itself.
    */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) cannotSendToContract(to) {
        super._update(from, to, value);
    }
}
