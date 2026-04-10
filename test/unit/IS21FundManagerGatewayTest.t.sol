// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IS21FundManagerGateway, FiatReserves} from "src/gateways/IS21FundManagerGateway.sol";

contract MockIS21EngineForGateway {
    mapping(bytes32 => uint256) internal sReserves;
    mapping(address => uint256) internal sBalances;

    address public lastMintTo;
    uint256 public lastMintAmount;

    address public lastBurnFrom;
    uint256 public lastBurnAmount;

    function mintIs21To(address to, uint256 amount) external {
        sBalances[to] += amount;
        lastMintTo = to;
        lastMintAmount = amount;
    }

    function burnIs21From(address from, uint256 amount) external {
        sBalances[from] -= amount;
        lastBurnFrom = from;
        lastBurnAmount = amount;
    }

    function getFiatReserve(bytes32 currency) external view returns (uint256) {
        return sReserves[currency];
    }

    function updateFiatReserve(bytes32 currency, uint256 amount) external {
        sReserves[currency] = amount;
    }

    function updateFiatReserves(FiatReserves[] calldata reserves) external {
        for (uint256 i = 0; i < reserves.length; i++) {
            sReserves[reserves[i].currency] = reserves[i].amount;
        }
    }

    function setReserve(bytes32 currency, uint256 amount) external {
        sReserves[currency] = amount;
    }

    function setBalance(address account, uint256 amount) external {
        sBalances[account] = amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return sBalances[account];
    }
}

contract IS21FundManagerGatewayTest is Test {
    IS21FundManagerGateway internal gateway;
    MockIS21EngineForGateway internal engine;

    address internal owner = makeAddr("owner");
    address internal authorizedCaller = makeAddr("authorizedCaller");
    address internal authorizedCaller2 = makeAddr("authorizedCaller2");
    address internal fundManager = makeAddr("fundManager");
    address internal fundManager2 = makeAddr("fundManager2");
    address internal user = makeAddr("user");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant USD = bytes32("USD");
    bytes32 internal constant EUR = bytes32("EUR");
    bytes32 internal constant ZAR = bytes32("ZAR");

    function setUp() public {
        engine = new MockIS21EngineForGateway();
        gateway = new IS21FundManagerGateway(owner, address(engine));

        vm.startPrank(owner);
        gateway.authorizeCaller(authorizedCaller);
        gateway.approveFundManager(fundManager);
        vm.stopPrank();
    }

    /* ---------------- Constructor / Views ---------------- */

    function testInitialState() public view {
        assertEq(gateway.owner(), owner);
        assertEq(address(gateway.is21()), address(engine));
        assertEq(gateway.getVersion(), "1.0.0");
    }

    function testConstructorRevertsIfOwnerIsZero() public {
        vm.expectRevert();
        new IS21FundManagerGateway(address(0), address(engine));
    }

    function testConstructorRevertsIfEngineIsZero() public {
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__NotZeroAddress.selector
        );
        new IS21FundManagerGateway(owner, address(0));
    }

    /* ---------------- Authorization Management ---------------- */

    function testAuthorizeCaller() public {
        vm.prank(owner);
        gateway.authorizeCaller(authorizedCaller2);

        address[] memory callers = gateway.getAuthorizedCallers();
        assertEq(callers.length, 2);
    }

    function testAuthorizeCallerRevertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        gateway.authorizeCaller(authorizedCaller2);
    }

    function testAuthorizeCallerRevertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__NotZeroAddress.selector
        );
        gateway.authorizeCaller(address(0));
    }

    function testAuthorizeCallerIdempotent() public {
        vm.prank(owner);
        gateway.authorizeCaller(authorizedCaller);

        address[] memory callers = gateway.getAuthorizedCallers();
        assertEq(callers.length, 1);
    }

    function testRevokeCaller() public {
        vm.prank(owner);
        gateway.revokeCaller(authorizedCaller);

        address[] memory callers = gateway.getAuthorizedCallers();
        assertEq(callers.length, 0);
    }

    function testRevokeCallerNoOpWhenAlreadyFalse() public {
        vm.prank(owner);
        gateway.revokeCaller(authorizedCaller2);

        address[] memory callers = gateway.getAuthorizedCallers();
        assertEq(callers.length, 1);
        assertEq(callers[0], authorizedCaller);
    }

    function testRevokeCallerRevertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__NotZeroAddress.selector
        );
        gateway.revokeCaller(address(0));
    }

    function testApproveFundManager() public {
        vm.prank(owner);
        gateway.approveFundManager(fundManager2);

        address[] memory managers = gateway.getFundManagers();
        assertEq(managers.length, 2);
    }

    function testApproveFundManagerRevertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        gateway.approveFundManager(fundManager2);
    }

    function testApproveFundManagerRevertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__NotZeroAddress.selector
        );
        gateway.approveFundManager(address(0));
    }

    function testApproveFundManagerIdempotent() public {
        vm.prank(owner);
        gateway.approveFundManager(fundManager);

        address[] memory managers = gateway.getFundManagers();
        assertEq(managers.length, 1);
    }

    function testRevokeFundManager() public {
        vm.prank(owner);
        gateway.revokeFundManager(fundManager);

        address[] memory managers = gateway.getFundManagers();
        assertEq(managers.length, 0);
    }

    function testRevokeFundManagerNoOpWhenAlreadyFalse() public {
        vm.prank(owner);
        gateway.revokeFundManager(fundManager2);

        address[] memory managers = gateway.getFundManagers();
        assertEq(managers.length, 1);
        assertEq(managers[0], fundManager);
    }

    function testRevokeFundManagerRevertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__NotZeroAddress.selector
        );
        gateway.revokeFundManager(address(0));
    }

    /* ---------------- Mint With Reserve Increase ---------------- */

    function testMintWithReservesIncreaseSingleCurrency() public {
        FiatReserves[] memory increases = new FiatReserves[](1);
        increases[0] = FiatReserves({currency: USD, amount: 500});

        vm.prank(authorizedCaller);
        gateway.mintWithReservesIncrease(user, increases, 1_000);

        assertEq(engine.getFiatReserve(USD), 500);
        assertEq(engine.balanceOf(user), 1_000);
        assertEq(engine.lastMintTo(), user);
        assertEq(engine.lastMintAmount(), 1_000);
    }

    function testMintWithReservesIncreaseMultipleCurrencies() public {
        engine.setReserve(USD, 100);
        engine.setReserve(EUR, 200);

        FiatReserves[] memory increases = new FiatReserves[](3);
        increases[0] = FiatReserves({currency: USD, amount: 50});
        increases[1] = FiatReserves({currency: EUR, amount: 25});
        increases[2] = FiatReserves({currency: ZAR, amount: 75});

        vm.prank(authorizedCaller);
        gateway.mintWithReservesIncrease(user, increases, 10_000);

        assertEq(engine.getFiatReserve(USD), 150);
        assertEq(engine.getFiatReserve(EUR), 225);
        assertEq(engine.getFiatReserve(ZAR), 75);
        assertEq(engine.balanceOf(user), 10_000);
    }

    function testMintWithReservesIncreaseRevertsIfNotAuthorizedCaller() public {
        FiatReserves[] memory increases = new FiatReserves[](1);
        increases[0] = FiatReserves({currency: USD, amount: 1});

        vm.prank(stranger);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__UnauthorizedCaller.selector
        );
        gateway.mintWithReservesIncrease(user, increases, 1);
    }

    function testMintWithReservesIncreaseRevertsIfPaused() public {
        FiatReserves[] memory increases = new FiatReserves[](1);
        increases[0] = FiatReserves({currency: USD, amount: 1});

        vm.prank(owner);
        gateway.pause();

        vm.prank(authorizedCaller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.mintWithReservesIncrease(user, increases, 1);
    }

    function testMintWithReservesIncreaseRevertsIfMintAmountZero() public {
        FiatReserves[] memory increases = new FiatReserves[](1);
        increases[0] = FiatReserves({currency: USD, amount: 1});

        vm.prank(authorizedCaller);
        vm.expectRevert(IS21FundManagerGateway.IS21FMG__InvalidAmount.selector);
        gateway.mintWithReservesIncrease(user, increases, 0);
    }

    function testMintWithReservesIncreaseRevertsIfToZeroAddress() public {
        FiatReserves[] memory increases = new FiatReserves[](1);
        increases[0] = FiatReserves({currency: USD, amount: 1});

        vm.prank(authorizedCaller);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__NotZeroAddress.selector
        );
        gateway.mintWithReservesIncrease(address(0), increases, 1);
    }

    function testMintWithReservesIncreaseRevertsIfReserveArrayEmpty() public {
        FiatReserves[] memory increases = new FiatReserves[](1);

        vm.prank(authorizedCaller);
        vm.expectRevert(IS21FundManagerGateway.IS21FMG__InvalidAmount.selector);
        gateway.mintWithReservesIncrease(user, increases, 1);
    }

    function testMintWithReservesIncreaseRevertsIfCurrencyZero() public {
        FiatReserves[] memory increases = new FiatReserves[](1);
        increases[0] = FiatReserves({currency: bytes32(0), amount: 1});

        vm.prank(authorizedCaller);
        vm.expectRevert(IS21FundManagerGateway.IS21FMG__InvalidAmount.selector);
        gateway.mintWithReservesIncrease(user, increases, 1);
    }

    function testMintWithReservesIncreaseRevertsIfReserveDeltaZero() public {
        FiatReserves[] memory increases = new FiatReserves[](1);
        increases[0] = FiatReserves({currency: USD, amount: 0});

        vm.prank(authorizedCaller);
        vm.expectRevert(IS21FundManagerGateway.IS21FMG__InvalidAmount.selector);
        gateway.mintWithReservesIncrease(user, increases, 1);
    }

    /* ---------------- Burn With Reserve Decrease ---------------- */

    function testBurnWithReservesDecreaseSingleCurrency() public {
        engine.setReserve(USD, 900);
        engine.setBalance(user, 5_000);

        FiatReserves[] memory decreases = new FiatReserves[](1);
        decreases[0] = FiatReserves({currency: USD, amount: 300});

        vm.prank(authorizedCaller);
        gateway.burnWithReservesDecrease(user, decreases, 1_000);

        assertEq(engine.getFiatReserve(USD), 600);
        assertEq(engine.balanceOf(user), 4_000);
        assertEq(engine.lastBurnFrom(), user);
        assertEq(engine.lastBurnAmount(), 1_000);
    }

    function testBurnWithReservesDecreaseMultipleCurrencies() public {
        engine.setReserve(USD, 500);
        engine.setReserve(EUR, 400);
        engine.setBalance(user, 20_000);

        FiatReserves[] memory decreases = new FiatReserves[](3);
        decreases[0] = FiatReserves({currency: USD, amount: 100});
        decreases[1] = FiatReserves({currency: EUR, amount: 50});
        decreases[2] = FiatReserves({currency: ZAR, amount: 0});

        vm.prank(authorizedCaller);
        vm.expectRevert(IS21FundManagerGateway.IS21FMG__InvalidAmount.selector);
        gateway.burnWithReservesDecrease(user, decreases, 1_000);
    }

    function testBurnWithReservesDecreaseMultipleCurrenciesSuccess() public {
        engine.setReserve(USD, 500);
        engine.setReserve(EUR, 400);
        engine.setReserve(ZAR, 300);
        engine.setBalance(user, 20_000);

        FiatReserves[] memory decreases = new FiatReserves[](3);
        decreases[0] = FiatReserves({currency: USD, amount: 100});
        decreases[1] = FiatReserves({currency: EUR, amount: 50});
        decreases[2] = FiatReserves({currency: ZAR, amount: 25});

        vm.prank(authorizedCaller);
        gateway.burnWithReservesDecrease(user, decreases, 1_000);

        assertEq(engine.getFiatReserve(USD), 400);
        assertEq(engine.getFiatReserve(EUR), 350);
        assertEq(engine.getFiatReserve(ZAR), 275);
        assertEq(engine.balanceOf(user), 19_000);
    }

    function testBurnWithReservesDecreaseRevertsIfNotAuthorizedCaller() public {
        FiatReserves[] memory decreases = new FiatReserves[](1);
        decreases[0] = FiatReserves({currency: USD, amount: 1});

        vm.prank(stranger);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__UnauthorizedCaller.selector
        );
        gateway.burnWithReservesDecrease(user, decreases, 1);
    }

    function testBurnWithReservesDecreaseRevertsIfPaused() public {
        FiatReserves[] memory decreases = new FiatReserves[](1);
        decreases[0] = FiatReserves({currency: USD, amount: 1});

        vm.prank(owner);
        gateway.pause();

        vm.prank(authorizedCaller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.burnWithReservesDecrease(user, decreases, 1);
    }

    function testBurnWithReservesDecreaseRevertsIfBurnAmountZero() public {
        FiatReserves[] memory decreases = new FiatReserves[](1);
        decreases[0] = FiatReserves({currency: USD, amount: 1});

        vm.prank(authorizedCaller);
        vm.expectRevert(IS21FundManagerGateway.IS21FMG__InvalidAmount.selector);
        gateway.burnWithReservesDecrease(user, decreases, 0);
    }

    function testBurnWithReservesDecreaseRevertsIfFromZeroAddress() public {
        FiatReserves[] memory decreases = new FiatReserves[](1);
        decreases[0] = FiatReserves({currency: USD, amount: 1});

        vm.prank(authorizedCaller);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__NotZeroAddress.selector
        );
        gateway.burnWithReservesDecrease(address(0), decreases, 1);
    }

    function testBurnWithReservesDecreaseRevertsIfReserveArrayEmpty() public {
        FiatReserves[] memory decreases = new FiatReserves[](0);

        vm.prank(authorizedCaller);
        vm.expectRevert(IS21FundManagerGateway.IS21FMG__InvalidAmount.selector);
        gateway.burnWithReservesDecrease(user, decreases, 1);
    }

    function testBurnWithReservesDecreaseRevertsIfCurrencyZero() public {
        engine.setBalance(user, 100);

        FiatReserves[] memory decreases = new FiatReserves[](1);
        decreases[0] = FiatReserves({currency: bytes32(0), amount: 1});

        vm.prank(authorizedCaller);
        vm.expectRevert(IS21FundManagerGateway.IS21FMG__InvalidAmount.selector);
        gateway.burnWithReservesDecrease(user, decreases, 1);
    }

    function testBurnWithReservesDecreaseRevertsIfReserveDeltaZero() public {
        engine.setBalance(user, 100);

        FiatReserves[] memory decreases = new FiatReserves[](1);
        decreases[0] = FiatReserves({currency: USD, amount: 0});

        vm.prank(authorizedCaller);
        vm.expectRevert(IS21FundManagerGateway.IS21FMG__InvalidAmount.selector);
        gateway.burnWithReservesDecrease(user, decreases, 1);
    }

    function testBurnWithReservesDecreaseRevertsIfInsufficientReserve() public {
        engine.setReserve(USD, 10);
        engine.setBalance(user, 100);

        FiatReserves[] memory decreases = new FiatReserves[](1);
        decreases[0] = FiatReserves({currency: USD, amount: 11});

        vm.prank(authorizedCaller);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__InsufficientReserve.selector
        );
        gateway.burnWithReservesDecrease(user, decreases, 1);
    }

    /* ---------------- Emergency Reserve Sync ---------------- */

    function testUpdateFiatReserveByFundManager() public {
        vm.prank(fundManager);
        gateway.updateFiatReserve(USD, 12345);

        assertEq(engine.getFiatReserve(USD), 12345);
    }

    function testUpdateFiatReserveRevertsIfNotFundManager() public {
        vm.prank(stranger);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__OnlyFundManagerCanExecute.selector
        );
        gateway.updateFiatReserve(USD, 12345);
    }

    function testUpdateFiatReservesByFundManager() public {
        FiatReserves[] memory reserves = new FiatReserves[](2);
        reserves[0] = FiatReserves({currency: USD, amount: 100});
        reserves[1] = FiatReserves({currency: EUR, amount: 200});

        vm.prank(fundManager);
        gateway.updateFiatReserves(reserves);

        assertEq(engine.getFiatReserve(USD), 100);
        assertEq(engine.getFiatReserve(EUR), 200);
    }

    function testUpdateFiatReservesRevertsIfNotFundManager() public {
        FiatReserves[] memory reserves = new FiatReserves[](1);
        reserves[0] = FiatReserves({currency: USD, amount: 100});

        vm.prank(stranger);
        vm.expectRevert(
            IS21FundManagerGateway.IS21FMG__OnlyFundManagerCanExecute.selector
        );
        gateway.updateFiatReserves(reserves);
    }

    /* ---------------- Pause / Unpause ---------------- */

    function testPauseAndUnpause() public {
        vm.prank(owner);
        gateway.pause();

        FiatReserves[] memory increases = new FiatReserves[](1);
        increases[0] = FiatReserves({currency: USD, amount: 1});

        vm.prank(authorizedCaller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.mintWithReservesIncrease(user, increases, 1);

        vm.prank(owner);
        gateway.unpause();

        vm.prank(authorizedCaller);
        gateway.mintWithReservesIncrease(user, increases, 1);

        assertEq(engine.getFiatReserve(USD), 1);
        assertEq(engine.balanceOf(user), 1);
    }

    function testPauseRevertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        gateway.pause();
    }

    function testUnpauseRevertsIfNotOwner() public {
        vm.prank(owner);
        gateway.pause();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        gateway.unpause();
    }
}
