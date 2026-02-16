// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title IS21FundManagerGateway
 * @author InterShare Team
 *
 * @notice
 * This contract is the SINGLE authorized fund manager of IS21Engine.
 * It is responsible for ALL minting, burning, and fiat reserve updates.
 * It serves as a gateway contract to interact with the IS21Engine.
 *
 */
interface IIS21Engine {
    function mintIs21To(address to, uint256 amount) external;

    function burnIs21From(address from, uint256 amount) external;

    function getFiatReserve(bytes32 currency) external view returns (uint256);

    function updateFiatReserve(bytes32 currency, uint256 amount) external;

    function updateFiatReserves(FiatReserves[] calldata reserves) external;
}

struct FiatReserves {
    bytes32 currency;
    uint256 amount;
}

contract IS21FundManagerGateway is Ownable, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    ///////////////
    // Errors    //
    ///////////////
    error IS21FMG__UnauthorizedCaller();
    error IS21FMG__OnlyFundManagerCanExecute();
    error IS21FMG__InvalidAmount();
    error IS21FMG__InsufficientReserve();
    error IS21FMG__NotZeroAddress();

    /////////////////////
    // State Variables //
    /////////////////////
    string public constant IS21FMG_VERSION = "1.0.0"; // Semantic versioning for the IS21FundManagerGateway contract
    IIS21Engine public immutable is21;

    // Contracts allowed to request mint/burn operations
    EnumerableSet.AddressSet private sAuthorizedCallers;
    EnumerableSet.AddressSet private sFundManagers;

    ////////////
    // Events //
    ////////////
    event CallerAuthorized(address indexed caller, uint256 timestamp);
    event CallerRevoked(address indexed caller, uint256 timestamp);
    event FundManagerApproved(address indexed caller, uint256 timestamp);
    event FundManagerRevoked(address indexed caller, uint256 timestamp);

    event ReserveIncreased(
        bytes32 indexed currency,
        uint256 delta,
        uint256 newTotal,
        uint256 timestamp
    );

    event ReserveDecreased(
        bytes32 indexed currency,
        uint256 delta,
        uint256 newTotal,
        uint256 timestamp
    );

    event IS21Minted(
        address indexed caller,
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );
    event IS21Burned(
        address indexed caller,
        address indexed from,
        uint256 amount,
        uint256 timestamp
    );
    event GatewayPaused(address indexed caller, uint256 timestamp);
    event GatewayUnpaused(address indexed caller, uint256 timestamp);

    ///////////////
    // Modifiers //
    ///////////////
    modifier onlyFundManager() {
        if (!sFundManagers.contains(msg.sender)) {
            revert IS21FMG__OnlyFundManagerCanExecute();
        }
        _;
    }

    modifier onlyAuthorizedCaller() {
        if (!sAuthorizedCallers.contains(msg.sender)) {
            revert IS21FMG__UnauthorizedCaller();
        }
        _;
    }

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert IS21FMG__InvalidAmount();
        }
        _;
    }

    modifier nonZeroAddress(address to) {
        if (to == address(0)) {
            revert IS21FMG__NotZeroAddress();
        }
        _;
    }

    /////////////////
    // Constructor //
    /////////////////

    /** 
        @param ownerAddress The address of the owner of the contract.
        @param is21Engine The address of the IS21 engine contract.
        @notice The owner address/is21 address cannot be zero.
        @dev The constructor initializes the contract with the owner's address and the IS21 engine address.
    */
    constructor(
        address ownerAddress,
        address is21Engine
    ) Ownable(ownerAddress) {
        if (ownerAddress == address(0)) {
            revert IS21FMG__NotZeroAddress();
        }

        if (is21Engine == address(0)) {
            revert IS21FMG__NotZeroAddress();
        }

        is21 = IIS21Engine(is21Engine);
    }

    ///////////////////////////////////
    // Authorization Management      //
    ///////////////////////////////////

    /**
        This function allows the owner to approve an address or contract to use this minting and burning.
        @param caller The address of the caller to be approved.
        @notice This function can only be called by the current owner and is protected against reentrancy attacks.
        @dev It updates the mapping of authorized addresses and emits an event for tracking purposes.
    */
    function authorizeCaller(
        address caller
    ) external onlyOwner nonZeroAddress(caller) nonReentrant {
        if (sAuthorizedCallers.add(caller)) {
            emit CallerAuthorized(caller, block.timestamp);
        }
    }

    /** 
        This function allows the owner to revoke an address or contract to use this minting and burning.
        @param caller The address of the caller to be revoked.
        @notice This function can only be called by the current owner and is protected against reentrancy attacks.
        @dev It updates the mapping of approved authorized callers and emits an event for tracking purposes.
    */
    function revokeCaller(
        address caller
    ) external onlyOwner nonZeroAddress(caller) nonReentrant {
        if (sAuthorizedCallers.remove(caller)) {
            emit CallerRevoked(caller, block.timestamp);
        }
    }

    /**
        This function retrieves the list of all approved authorized callers.
        @return An array of addresses representing the approved authorized callers.
        @notice This function is view-only and does not modify the state of the contract.
        @dev It can be used to get a list of all authorized addresses for administrative or informational purposes.
    */
    function getAuthorizedCallers() external view returns (address[] memory) {
        return sAuthorizedCallers.values();
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

    ///////////////////////////////////
    // Core Accounting Operations    //
    ///////////////////////////////////

    /**
     * @notice Mint IS21 while atomically increasing reserves
     */
    function mintWithReservesIncrease(
        address to,
        FiatReserves[] calldata reserveIncreases,
        uint256 mintAmount
    )
        external
        nonReentrant
        onlyAuthorizedCaller
        moreThanZero(mintAmount)
        nonZeroAddress(to)
        whenNotPaused
    {
        if (reserveIncreases.length == 0) {
            revert IS21FMG__InvalidAmount();
        }

        FiatReserves[] memory updates = new FiatReserves[](
            reserveIncreases.length
        );

        for (uint256 i = 0; i < reserveIncreases.length; ) {
            FiatReserves calldata r = reserveIncreases[i];

            if (r.currency == bytes32(0) || r.amount == 0) {
                revert IS21FMG__InvalidAmount();
            }

            uint256 current = is21.getFiatReserve(r.currency);
            uint256 newTotal = current + r.amount;

            updates[i] = FiatReserves({currency: r.currency, amount: newTotal});

            emit ReserveIncreased(
                r.currency,
                r.amount,
                newTotal,
                block.timestamp
            );

            unchecked {
                ++i;
            }
        }

        is21.updateFiatReserves(updates);
        is21.mintIs21To(to, mintAmount);

        emit IS21Minted(msg.sender, to, mintAmount, block.timestamp);
    }

    /**
     * @notice Burn IS21 while atomically decreasing reserves
     */
    function burnWithReservesDecrease(
        address from,
        FiatReserves[] calldata reserveDecreases,
        uint256 burnAmount
    )
        external
        nonReentrant
        onlyAuthorizedCaller
        moreThanZero(burnAmount)
        nonZeroAddress(from)
        whenNotPaused
    {
        if (reserveDecreases.length == 0) {
            revert IS21FMG__InvalidAmount();
        }

        FiatReserves[] memory updates = new FiatReserves[](
            reserveDecreases.length
        );

        for (uint256 i = 0; i < reserveDecreases.length; ) {
            FiatReserves calldata r = reserveDecreases[i];

            if (r.currency == bytes32(0) || r.amount == 0) {
                revert IS21FMG__InvalidAmount();
            }

            uint256 current = is21.getFiatReserve(r.currency);

            if (r.amount > current) {
                revert IS21FMG__InsufficientReserve();
            }

            uint256 newTotal = current - r.amount;

            updates[i] = FiatReserves({currency: r.currency, amount: newTotal});

            emit ReserveDecreased(
                r.currency,
                r.amount,
                newTotal,
                block.timestamp
            );

            unchecked {
                ++i;
            }
        }

        is21.updateFiatReserves(updates);
        is21.burnIs21From(from, burnAmount);
        emit IS21Burned(msg.sender, from, burnAmount, block.timestamp);
    }

    /**
     * @notice Emergency reserve sync (absolute set)
     * @dev Use ONLY for auditor-verified corrections
     */
    function updateFiatReserve(
        bytes32 currency,
        uint256 amount
    ) external onlyFundManager nonReentrant {
        is21.updateFiatReserve(currency, amount);
    }

    /**
     * @notice Emergency reserve sync (absolute set)
     * @dev Use ONLY for auditor-verified corrections
     */
    function updateFiatReserves(
        FiatReserves[] calldata reserves
    ) external onlyFundManager nonReentrant {
        is21.updateFiatReserves(reserves);
    }

    function pause() external onlyOwner {
        _pause();
        emit GatewayPaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit GatewayUnpaused(msg.sender, block.timestamp);
    }

    /**
        @return The current version of the IS21Engine contract as a string.
        @dev This function returns a constant string defined in the contract.
     */
    function getVersion() external pure returns (string memory) {
        return IS21FMG_VERSION;
    }
}
