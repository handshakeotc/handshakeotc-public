// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OtcFactory} from "../src/OtcFactory.sol";
import {OtcBoard} from "../src/OtcBoard.sol";
import {MockToken, UsdtLikeToken} from "./mocks/MockToken.sol";

/// The factory has no owner: it only creates boards and remembers them. Rules written before the code:
///  - anyone can create the board for any pair, once; the same code runs every board, so who made it is irrelevant
///  - nobody can list, delist, pause, charge a fee or change anything after deployment
///  - prices are per whole base token, whatever its decimals (18 for DIME, 8 for WBTC, 6 for others)
///  - every transfer must deliver exactly what was sent, or the call reverts (USDT can switch a fee on)
contract OtcFactoryTest is Test {
    OtcFactory factory;
    MockToken dime;
    MockToken usdc;
    MockToken weth;
    MockToken wbtc;
    UsdtLikeToken usdt;

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    uint64 expiry;

    function setUp() public {
        factory = new OtcFactory();
        dime = new MockToken("DIME", 18);
        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        wbtc = new MockToken("WBTC", 8);
        usdt = new UsdtLikeToken();
        expiry = uint64(block.timestamp + 1 days);
    }

    function board(IERC20 base, IERC20 quote) internal returns (OtcBoard b) {
        vm.prank(makeAddr("anyone"));
        b = factory.createBoard(base, quote);
    }

    function fund(address who, MockToken token, uint256 amount, OtcBoard b) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(b), type(uint256).max);
    }

    // --- creating boards ------------------------------------------------------------------------------

    function test_anyoneCreatesTheOneBoardForAPair() public {
        OtcBoard b = board(dime, usdc);
        assertEq(address(b.base()), address(dime));
        assertEq(address(b.quote()), address(usdc));
        assertEq(b.factory(), address(factory));
        assertEq(factory.boardFor(address(dime), address(usdc)), address(b));
        assertTrue(factory.isBoard(address(b)));
        assertEq(factory.boardCount(), 1);

        vm.expectRevert(OtcFactory.BoardExists.selector);
        factory.createBoard(dime, usdc);
    }

    function test_anyTokenCanBeTheQuoteSide() public {
        // there is no allowlist to keep: which markets matter is the front end's call, not the contract's
        OtcBoard b = board(usdc, dime);
        assertEq(address(b.quote()), address(dime));
        assertEq(factory.boardCount(), 1);
    }

    function test_nonsensePairsAreRefused() public {
        vm.expectRevert(OtcFactory.BadPair.selector);
        factory.createBoard(usdc, usdc);
        vm.expectRevert(OtcFactory.BadPair.selector);
        factory.createBoard(IERC20(address(0)), usdc);
        vm.expectRevert(OtcFactory.BadPair.selector);
        factory.createBoard(dime, IERC20(address(0)));
    }

    function test_aTokenWithAbsurdDecimalsCannotGetABoard() public {
        MockToken odd = new MockToken("ODD", 40);
        vm.expectRevert(OtcBoard.BadDecimals.selector);
        factory.createBoard(odd, usdc);
    }

    function test_nobodyAdministersTheFactory() public {
        // the functions an owner used to have are gone, not merely locked: a call to any of them fails
        bytes[4] memory gone = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("setFee(uint16,address)", uint16(10), maker),
            abi.encodeWithSignature("setListed(address,bool)", maker, false),
            abi.encodeWithSignature("setQuoteAllowed(address,bool)", maker, true)
        ];
        for (uint256 i; i < gone.length; i++) {
            (bool ok,) = address(factory).call(gone[i]);
            assertFalse(ok);
        }
    }

    // --- prices per whole token, whatever the decimals -----------------------------------------------

    function test_an8DecimalBaseIsPricedPerWholeCoin() public {
        OtcBoard b = board(wbtc, usdc); // 60,000 USDC per WBTC
        assertEq(b.BASE_UNIT(), 1e8);
        fund(maker, wbtc, 1e8, b);
        fund(taker, usdc, 30_000e6, b);
        vm.prank(maker);
        uint256 id = b.createOrder(OtcBoard.Side.Sell, 60_000e6, 1e8, 0, expiry, address(0));
        vm.prank(taker);
        b.fill(id, 5e7); // half a coin
        assertEq(usdc.balanceOf(maker), 30_000e6);
        assertEq(wbtc.balanceOf(taker), 5e7);
    }

    function test_aWethQuoteIsPricedInWeiPerWholeDime() public {
        OtcBoard b = board(dime, weth); // 0.0000115 ETH per DIME
        fund(maker, dime, 100_000e18, b);
        fund(taker, weth, 2e18, b);
        vm.prank(maker);
        uint256 id = b.createOrder(OtcBoard.Side.Sell, 11_500_000_000_000, 100_000e18, 0, expiry, address(0));
        vm.prank(taker);
        b.fill(id, 100_000e18);
        assertEq(weth.balanceOf(maker), 1.15e18);
    }

    // --- USDT --------------------------------------------------------------------------------------------

    function _usdtBoard() internal returns (OtcBoard b) {
        b = board(dime, IERC20(address(usdt)));
        fund(maker, dime, 100_000e18, b);
        usdt.mint(taker, 10_000e6);
        vm.prank(taker);
        usdt.approve(address(b), type(uint256).max);
    }

    function test_usdtWorksDespiteReturningNothing() public {
        OtcBoard b = _usdtBoard();
        vm.prank(maker);
        uint256 id = b.createOrder(OtcBoard.Side.Sell, 50_000, 100_000e18, 0, expiry, address(0));
        vm.prank(taker);
        b.fill(id, 100_000e18);
        assertEq(usdt.balanceOf(maker), 5_000e6);
    }

    function test_ifUsdtSwitchesItsFeeOnAFillRevertsRatherThanShortTheMaker() public {
        OtcBoard b = _usdtBoard();
        vm.prank(maker);
        uint256 id = b.createOrder(OtcBoard.Side.Sell, 50_000, 100_000e18, 0, expiry, address(0));
        usdt.setFee(10); // 0.1%, Tether's switch
        vm.prank(taker);
        vm.expectRevert(OtcBoard.TransferShortfall.selector);
        b.fill(id, 100_000e18);
        vm.prank(maker);
        b.cancel(id); // and the maker's coins are not stuck
        assertEq(dime.balanceOf(maker), 100_000e18);
    }

    function test_aUsdtBuyOrderCannotBeEscrowedWhileTheFeeIsOn() public {
        OtcBoard b = _usdtBoard();
        usdt.mint(maker, 1_000e6);
        vm.prank(maker);
        usdt.approve(address(b), type(uint256).max);
        usdt.setFee(10);
        vm.prank(maker);
        vm.expectRevert(OtcBoard.TransferShortfall.selector);
        b.createOrder(OtcBoard.Side.Buy, 50_000, 10_000e18, 0, expiry, address(0));
    }
}
