// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IS21USDTSwappingGateway, FiatReserves} from "src/gateways/IS21USDTSwappingGateway.sol";
import {MockUSDT} from "src/mocks/MockUSDT.sol";

contract MockFundManagerGatewayForSwap {
    address public lastMintTo;
    uint256 public lastMintAmount;
    address public lastBurnFrom;
    uint256 public lastBurnAmount;

    bytes32 public lastMintReserveCurrency;
    uint256 public lastMintReserveAmount;

    bytes32 public lastBurnReserveCurrency;
    uint256 public lastBurnReserveAmount;

    function mintWithReservesIncrease(
        address to,
        FiatReserves[] calldata reserveIncreases,
        uint256 mintAmount
    ) external {
        lastMintTo = to;
        lastMintAmount = mintAmount;

        if (reserveIncreases.length > 0) {
            lastMintReserveCurrency = reserveIncreases[0].currency;
            lastMintReserveAmount = reserveIncreases[0].amount;
        }
    }

    function burnWithReservesDecrease(
        address from,
        FiatReserves[] calldata reserveDecreases,
        uint256 burnAmount
    ) external {
        lastBurnFrom = from;
        lastBurnAmount = burnAmount;

        if (reserveDecreases.length > 0) {
            lastBurnReserveCurrency = reserveDecreases[0].currency;
            lastBurnReserveAmount = reserveDecreases[0].amount;
        }
    }
}

contract IS21USDTSwappingGatewayTest is Test {
    IS21USDTSwappingGateway internal gateway;
    MockUSDT internal usdt;
    MockFundManagerGatewayForSwap internal fundManagerGateway;

    address internal owner = makeAddr("owner");
    address internal fundManager = makeAddr("fundManager");
    address internal fundManager2 = makeAddr("fundManager2");
    address internal user = makeAddr("user");
    address internal stranger = makeAddr("stranger");

    uint256 internal trustedSignerPk = 0xA11CE;
    address internal trustedSigner;

    bytes32 internal constant CURRENCY_USDT = bytes32("USDT");
    bytes32 internal constant MINT_TYPEHASH =
        keccak256(
            "MintQuote(address wallet,uint256 usdtAmount,uint256 is21Amount,uint256 nonce,uint256 expiry)"
        );
    bytes32 internal constant BURN_TYPEHASH =
        keccak256(
            "BurnQuote(address wallet,uint256 is21Amount,uint256 usdtAmount,uint256 nonce,uint256 expiry)"
        );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    function setUp() public {
        trustedSigner = vm.addr(trustedSignerPk);

        usdt = new MockUSDT(owner);
        fundManagerGateway = new MockFundManagerGatewayForSwap();

        gateway = new IS21USDTSwappingGateway(
            owner,
            trustedSigner,
            address(usdt),
            address(fundManagerGateway)
        );

        vm.prank(owner);
        gateway.approveFundManager(fundManager);

        vm.prank(owner);
        usdt.mint(user, 1_000_000_000); // 1000 USDT with 6 decimals

        vm.prank(owner);
        usdt.mint(fundManager, 1_000_000_000);

        vm.prank(user);
        usdt.approve(address(gateway), type(uint256).max);

        vm.prank(fundManager);
        usdt.approve(address(gateway), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256(bytes("IS21USDTSwappingGateway")),
                    keccak256(bytes("1.0.0")),
                    block.chainid,
                    address(gateway)
                )
            );
    }

    function _mintDigest(
        IS21USDTSwappingGateway.MintQuote memory quote
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                MINT_TYPEHASH,
                quote.wallet,
                quote.usdtAmount,
                quote.is21Amount,
                quote.nonce,
                quote.expiry
            )
        );

        return
            keccak256(
                abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
            );
    }

    function _burnDigest(
        IS21USDTSwappingGateway.BurnQuote memory quote
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                BURN_TYPEHASH,
                quote.wallet,
                quote.is21Amount,
                quote.usdtAmount,
                quote.nonce,
                quote.expiry
            )
        );

        return
            keccak256(
                abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
            );
    }

    function _signMintQuote(
        IS21USDTSwappingGateway.MintQuote memory quote
    ) internal view returns (bytes memory) {
        bytes32 digest = _mintDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(trustedSignerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signBurnQuote(
        IS21USDTSwappingGateway.BurnQuote memory quote
    ) internal view returns (bytes memory) {
        bytes32 digest = _burnDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(trustedSignerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR / VIEWS
    //////////////////////////////////////////////////////////////*/

    function testInitialState() public view {
        assertEq(gateway.owner(), owner);
        assertEq(address(gateway.USDT()), address(usdt));
        assertEq(gateway.getFundManagerGateway(), address(fundManagerGateway));
        assertEq(gateway.TRUSTED_SIGNER(), trustedSigner);
        assertEq(gateway.availableUsdt(), 0);
        assertFalse(gateway.isNonceUsed(user, 1));
    }

    function testConstructorRevertsIfOwnerIsZero() public {
        vm.expectRevert();
        new IS21USDTSwappingGateway(
            address(0),
            trustedSigner,
            address(usdt),
            address(fundManagerGateway)
        );
    }

    function testConstructorRevertsIfSignerIsZero() public {
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__ZeroAddress.selector);
        new IS21USDTSwappingGateway(
            owner,
            address(0),
            address(usdt),
            address(fundManagerGateway)
        );
    }

    function testConstructorRevertsIfUsdtIsZero() public {
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__ZeroAddress.selector);
        new IS21USDTSwappingGateway(
            owner,
            trustedSigner,
            address(0),
            address(fundManagerGateway)
        );
    }

    function testConstructorRevertsIfFundManagerGatewayIsZero() public {
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__ZeroAddress.selector);
        new IS21USDTSwappingGateway(
            owner,
            trustedSigner,
            address(usdt),
            address(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           FUND MANAGERS
    //////////////////////////////////////////////////////////////*/

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
            IS21USDTSwappingGateway.IS21SG__NotZeroAddress.selector
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
            IS21USDTSwappingGateway.IS21SG__NotZeroAddress.selector
        );
        gateway.revokeFundManager(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            MINT QUOTES
    //////////////////////////////////////////////////////////////*/

    function testMintWithQuote() public {
        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: user,
                usdtAmount: 250_000_000, // 250 USDT
                is21Amount: 250 ether,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signMintQuote(quote);

        uint256 userUsdtBefore = usdt.balanceOf(user);

        vm.prank(user);
        gateway.mintWithQuote(quote, sig);

        assertEq(usdt.balanceOf(user), userUsdtBefore - quote.usdtAmount);
        assertEq(usdt.balanceOf(address(gateway)), quote.usdtAmount);
        assertEq(gateway.availableUsdt(), quote.usdtAmount);
        assertTrue(gateway.isNonceUsed(user, 1));

        assertEq(fundManagerGateway.lastMintTo(), user);
        assertEq(fundManagerGateway.lastMintAmount(), 250 ether);
        assertEq(fundManagerGateway.lastMintReserveCurrency(), CURRENCY_USDT);
        assertEq(
            fundManagerGateway.lastMintReserveAmount(),
            250_000_000 * 1e12
        );
    }

    function testMintWithQuoteRevertsIfPaused() public {
        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: user,
                usdtAmount: 1,
                is21Amount: 1 ether,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signMintQuote(quote);

        vm.prank(owner);
        gateway.pause();

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.mintWithQuote(quote, sig);
    }

    function testMintWithQuoteRevertsIfWalletZero() public {
        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: address(0),
                usdtAmount: 1,
                is21Amount: 1 ether,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        vm.prank(user);
        vm.expectRevert(
            IS21USDTSwappingGateway.IS21SG__NotZeroAddress.selector
        );
        gateway.mintWithQuote(quote, hex"1234");
    }

    function testMintWithQuoteRevertsIfUsdtAmountZero() public {
        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: user,
                usdtAmount: 0,
                is21Amount: 1 ether,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        vm.prank(user);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__InvalidAmount.selector);
        gateway.mintWithQuote(quote, hex"1234");
    }

    function testMintWithQuoteRevertsIfIs21AmountZero() public {
        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: user,
                usdtAmount: 1,
                is21Amount: 0,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        vm.prank(user);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__InvalidAmount.selector);
        gateway.mintWithQuote(quote, hex"1234");
    }

    function testMintWithQuoteRevertsIfWalletDoesNotMatchSender() public {
        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: user,
                usdtAmount: 1,
                is21Amount: 1 ether,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signMintQuote(quote);

        vm.prank(stranger);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__InvalidWallet.selector);
        gateway.mintWithQuote(quote, sig);
    }

    function testMintWithQuoteRevertsIfExpired() public {
        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: user,
                usdtAmount: 1,
                is21Amount: 1 ether,
                nonce: 1,
                expiry: block.timestamp
            });

        bytes memory sig = _signMintQuote(quote);

        vm.warp(block.timestamp + 1);

        vm.prank(user);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__ExpiredQuote.selector);
        gateway.mintWithQuote(quote, sig);
    }

    function testMintWithQuoteRevertsIfNonceAlreadyUsed() public {
        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: user,
                usdtAmount: 10_000_000,
                is21Amount: 10 ether,
                nonce: 7,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signMintQuote(quote);

        vm.prank(user);
        gateway.mintWithQuote(quote, sig);

        vm.prank(user);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__NonceUsed.selector);
        gateway.mintWithQuote(quote, sig);
    }

    function testMintWithQuoteRevertsIfInvalidSignature() public {
        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: user,
                usdtAmount: 1,
                is21Amount: 1 ether,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        uint256 wrongPk = 0xBEEF;
        bytes32 digest = _mintDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert(
            IS21USDTSwappingGateway.IS21SG__InvalidSignature.selector
        );
        gateway.mintWithQuote(quote, sig);
    }

    /*//////////////////////////////////////////////////////////////
                            BURN QUOTES
    //////////////////////////////////////////////////////////////*/

    function testBurnWithQuote() public {
        vm.startPrank(fundManager);
        gateway.depositUsdt(300_000_000); // 300 USDT
        vm.stopPrank();

        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: user,
                is21Amount: 250 ether,
                usdtAmount: 250_000_000,
                nonce: 2,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signBurnQuote(quote);

        uint256 userUsdtBefore = usdt.balanceOf(user);

        vm.prank(user);
        gateway.burnWithQuote(quote, sig);

        assertEq(usdt.balanceOf(user), userUsdtBefore + quote.usdtAmount);
        assertEq(gateway.availableUsdt(), 50_000_000);
        assertTrue(gateway.isNonceUsed(user, 2));

        assertEq(fundManagerGateway.lastBurnFrom(), user);
        assertEq(fundManagerGateway.lastBurnAmount(), 250 ether);
        assertEq(fundManagerGateway.lastBurnReserveCurrency(), CURRENCY_USDT);
        assertEq(
            fundManagerGateway.lastBurnReserveAmount(),
            250_000_000 * 1e12
        );
    }

    function testBurnWithQuoteRevertsIfPaused() public {
        vm.prank(owner);
        gateway.pause();

        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: user,
                is21Amount: 1 ether,
                usdtAmount: 1,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signBurnQuote(quote);

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.burnWithQuote(quote, sig);
    }

    function testBurnWithQuoteRevertsIfWalletZero() public {
        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: address(0),
                is21Amount: 1 ether,
                usdtAmount: 1,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        vm.prank(user);
        vm.expectRevert(
            IS21USDTSwappingGateway.IS21SG__NotZeroAddress.selector
        );
        gateway.burnWithQuote(quote, hex"1234");
    }

    function testBurnWithQuoteRevertsIfUsdtAmountZero() public {
        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: user,
                is21Amount: 1 ether,
                usdtAmount: 0,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        vm.prank(user);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__InvalidAmount.selector);
        gateway.burnWithQuote(quote, hex"1234");
    }

    function testBurnWithQuoteRevertsIfIs21AmountZero() public {
        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: user,
                is21Amount: 0,
                usdtAmount: 1,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        vm.prank(user);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__InvalidAmount.selector);
        gateway.burnWithQuote(quote, hex"1234");
    }

    function testBurnWithQuoteRevertsIfWalletDoesNotMatchSender() public {
        vm.prank(fundManager);
        gateway.depositUsdt(100_000_000);

        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: user,
                is21Amount: 1 ether,
                usdtAmount: 1,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signBurnQuote(quote);

        vm.prank(stranger);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__InvalidWallet.selector);
        gateway.burnWithQuote(quote, sig);
    }

    function testBurnWithQuoteRevertsIfExpired() public {
        vm.prank(fundManager);
        gateway.depositUsdt(100_000_000);

        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: user,
                is21Amount: 1 ether,
                usdtAmount: 1,
                nonce: 1,
                expiry: block.timestamp
            });

        bytes memory sig = _signBurnQuote(quote);

        vm.warp(block.timestamp + 1);

        vm.prank(user);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__ExpiredQuote.selector);
        gateway.burnWithQuote(quote, sig);
    }

    function testBurnWithQuoteRevertsIfNonceAlreadyUsed() public {
        vm.prank(fundManager);
        gateway.depositUsdt(100_000_000);

        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: user,
                is21Amount: 10 ether,
                usdtAmount: 10_000_000,
                nonce: 9,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signBurnQuote(quote);

        vm.prank(user);
        gateway.burnWithQuote(quote, sig);

        vm.prank(user);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__NonceUsed.selector);
        gateway.burnWithQuote(quote, sig);
    }

    function testBurnWithQuoteRevertsIfInsufficientLiquidity() public {
        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: user,
                is21Amount: 100 ether,
                usdtAmount: 100_000_000,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signBurnQuote(quote);

        vm.prank(user);
        vm.expectRevert(
            IS21USDTSwappingGateway.IS21SG__InsufficientLiquidity.selector
        );
        gateway.burnWithQuote(quote, sig);
    }

    function testBurnWithQuoteRevertsIfInvalidSignature() public {
        vm.prank(fundManager);
        gateway.depositUsdt(100_000_000);

        IS21USDTSwappingGateway.BurnQuote memory quote = IS21USDTSwappingGateway
            .BurnQuote({
                wallet: user,
                is21Amount: 1 ether,
                usdtAmount: 1,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        uint256 wrongPk = 0xBEEF;
        bytes32 digest = _burnDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert(
            IS21USDTSwappingGateway.IS21SG__InvalidSignature.selector
        );
        gateway.burnWithQuote(quote, sig);
    }

    /*//////////////////////////////////////////////////////////////
                      FUND MANAGER SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function testDepositUsdtByFundManager() public {
        uint256 beforeBal = usdt.balanceOf(address(gateway));

        vm.prank(fundManager);
        gateway.depositUsdt(200_000_000);

        assertEq(usdt.balanceOf(address(gateway)), beforeBal + 200_000_000);
        assertEq(gateway.availableUsdt(), 200_000_000);
    }

    function testDepositUsdtRevertsIfNotFundManager() public {
        vm.prank(stranger);
        vm.expectRevert(
            IS21USDTSwappingGateway.IS21SG__OnlyFundManagerCanExecute.selector
        );
        gateway.depositUsdt(1);
    }

    function testDepositUsdtRevertsIfPaused() public {
        vm.prank(owner);
        gateway.pause();

        vm.prank(fundManager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.depositUsdt(1);
    }

    function testDepositUsdtRevertsIfZeroAmount() public {
        vm.prank(fundManager);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__InvalidAmount.selector);
        gateway.depositUsdt(0);
    }

    function testWithdrawUsdtByFundManager() public {
        vm.prank(fundManager);
        gateway.depositUsdt(300_000_000);

        uint256 fundManagerBefore = usdt.balanceOf(fundManager);

        vm.prank(fundManager);
        gateway.withdrawUsdt(fundManager, 120_000_000);

        assertEq(usdt.balanceOf(fundManager), fundManagerBefore + 120_000_000);
        assertEq(gateway.availableUsdt(), 180_000_000);
    }

    function testWithdrawUsdtRevertsIfNotFundManager() public {
        vm.prank(stranger);
        vm.expectRevert(
            IS21USDTSwappingGateway.IS21SG__OnlyFundManagerCanExecute.selector
        );
        gateway.withdrawUsdt(stranger, 1);
    }

    function testWithdrawUsdtRevertsIfPaused() public {
        vm.prank(fundManager);
        gateway.depositUsdt(100_000_000);

        vm.prank(owner);
        gateway.pause();

        vm.prank(fundManager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.withdrawUsdt(fundManager, 1);
    }

    function testWithdrawUsdtRevertsIfAmountZero() public {
        vm.prank(fundManager);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__InvalidAmount.selector);
        gateway.withdrawUsdt(fundManager, 0);
    }

    function testWithdrawUsdtRevertsIfAmountExceedsAvailable() public {
        vm.prank(fundManager);
        gateway.depositUsdt(100_000_000);

        vm.prank(fundManager);
        vm.expectRevert(IS21USDTSwappingGateway.IS21SG__InvalidAmount.selector);
        gateway.withdrawUsdt(fundManager, 100_000_001);
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE / ADMIN
    //////////////////////////////////////////////////////////////*/

    function testPauseAndUnpause() public {
        vm.prank(owner);
        gateway.pause();

        IS21USDTSwappingGateway.MintQuote memory quote = IS21USDTSwappingGateway
            .MintQuote({
                wallet: user,
                usdtAmount: 1,
                is21Amount: 1 ether,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });

        bytes memory sig = _signMintQuote(quote);

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gateway.mintWithQuote(quote, sig);

        vm.prank(owner);
        gateway.unpause();

        vm.prank(user);
        gateway.mintWithQuote(quote, sig);

        assertEq(gateway.availableUsdt(), 1);
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
