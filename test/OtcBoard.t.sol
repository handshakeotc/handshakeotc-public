// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {OtcBoard} from "../src/OtcBoard.sol";
import {OtcFactory} from "../src/OtcFactory.sol";
import {MockToken, FeeOnTransferToken} from "./mocks/MockToken.sol";

/// The rules, each written down before the contract existed:
///  - a maker's order pays out exactly what it says, and the taker pays exactly the order: there is no fee
///  - rounding always favours the resting side
///  - an order is firm: its coins sit in the contract until it is filled, cancelled or reclaimed
///  - nobody, not even whoever deployed the factory, can move anyone's coins or change the rules
contract OtcBoardTest is Test {
    OtcFactory factory;
    OtcBoard board;
    MockToken dime;
    MockToken usdc;

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");

    uint256 constant ONE = 1e18; // one DIME
    uint256 constant PRICE = 45_610; // 0.04561 USDC per DIME
    uint64 expiry;

    function setUp() public {
        dime = new MockToken("DIME", 18);
        usdc = new MockToken("USDC", 6);
        factory = new OtcFactory();
        board = factory.createBoard(dime, usdc);
        expiry = uint64(block.timestamp + 1 days);

        dime.mint(maker, 1_000_000 * ONE);
        dime.mint(taker, 1_000_000 * ONE);
        usdc.mint(maker, 1_000_000e6);
        usdc.mint(taker, 1_000_000e6);
        for (uint256 i; i < 2; i++) {
            address who = i == 0 ? maker : taker;
            vm.startPrank(who);
            dime.approve(address(board), type(uint256).max);
            usdc.approve(address(board), type(uint256).max);
            vm.stopPrank();
        }
    }

    // --- helpers ------------------------------------------------------------------------------------

    function sell(uint256 amount, uint256 minFill) internal returns (uint256) {
        vm.prank(maker);
        return board.createOrder(OtcBoard.Side.Sell, PRICE, amount, minFill, expiry, address(0));
    }

    function buy(uint256 amount, uint256 minFill) internal returns (uint256) {
        vm.prank(maker);
        return board.createOrder(OtcBoard.Side.Buy, PRICE, amount, minFill, expiry, address(0));
    }

    function fill(uint256 id, uint256 amount) internal {
        vm.prank(taker);
        board.fill(id, amount);
    }

    // --- creating ---------------------------------------------------------------------------------

    function test_aSellOrderEscrowsTheCoinsAndRecordsItsTerms() public {
        uint256 id = sell(50_000 * ONE, 10_000 * ONE);

        assertEq(id, 1, "ids start at 1 so 0 can mean none");
        assertEq(dime.balanceOf(address(board)), 50_000 * ONE);
        OtcBoard.Order memory o = board.getOrder(id);
        assertEq(o.maker, maker);
        assertEq(uint8(o.side), uint8(OtcBoard.Side.Sell));
        assertEq(o.price, PRICE);
        assertEq(o.remaining, 50_000 * ONE);
        assertEq(o.minFill, 10_000 * ONE);
        assertEq(o.expiry, expiry);
        assertEq(o.escrow, 50_000 * ONE);
    }

    function test_aBuyOrderEscrowsTheUsdcItCanPayOut() public {
        uint256 id = buy(50_000 * ONE, 0);
        // 50,000 x 0.04561 = 2,280.5 USDC
        assertEq(usdc.balanceOf(address(board)), 2_280_500_000);
        assertEq(board.getOrder(id).escrow, 2_280_500_000);
    }

    function test_idsNeverRepeat() public {
        uint256 a = sell(ONE * 1000, 0);
        vm.prank(maker);
        board.cancel(a);
        uint256 b = sell(ONE * 1000, 0);
        assertEq(b, a + 1);
    }

    function test_nonsenseOrdersAreRefused() public {
        vm.startPrank(maker);
        vm.expectRevert(OtcBoard.ZeroPrice.selector);
        board.createOrder(OtcBoard.Side.Sell, 0, ONE, 0, expiry, address(0));
        vm.expectRevert(OtcBoard.ZeroAmount.selector);
        board.createOrder(OtcBoard.Side.Sell, PRICE, 0, 0, expiry, address(0));
        vm.expectRevert(OtcBoard.MinFillAboveAmount.selector);
        board.createOrder(OtcBoard.Side.Sell, PRICE, ONE, ONE + 1, expiry, address(0));
        vm.expectRevert(OtcBoard.AlreadyExpired.selector);
        board.createOrder(OtcBoard.Side.Sell, PRICE, ONE, 0, uint64(block.timestamp), address(0));
        vm.stopPrank();
    }

    function test_aBuyOrderWorthLessThanOneUsdcAtomIsRefused() public {
        // 1 wei of DIME at 0.04561 is worth 0 USDC atoms: there would be nothing to escrow
        vm.prank(maker);
        vm.expectRevert(OtcBoard.ZeroQuote.selector);
        board.createOrder(OtcBoard.Side.Buy, PRICE, 1, 0, expiry, address(0));
    }

    function test_aTokenThatDeliversLessThanSentCannotBeEscrowed() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        OtcBoard odd = factory.createBoard(fot, usdc);
        fot.mint(maker, 1000 * ONE);
        vm.startPrank(maker);
        fot.approve(address(odd), type(uint256).max);
        vm.expectRevert(OtcBoard.TransferShortfall.selector);
        odd.createOrder(OtcBoard.Side.Sell, PRICE, 1000 * ONE, 0, expiry, address(0));
        vm.stopPrank();
    }

    // --- filling a sell order ------------------------------------------------------------------------

    function test_aFullFillSwapsExactlyAndClosesTheOrder() public {
        uint256 id = sell(50_000 * ONE, 0);
        uint256 makerUsdc = usdc.balanceOf(maker);
        uint256 takerUsdc = usdc.balanceOf(taker);
        uint256 takerDime = dime.balanceOf(taker);

        fill(id, 50_000 * ONE);

        assertEq(usdc.balanceOf(maker) - makerUsdc, 2_280_500_000);
        assertEq(takerUsdc - usdc.balanceOf(taker), 2_280_500_000);
        assertEq(dime.balanceOf(taker) - takerDime, 50_000 * ONE);
        assertEq(dime.balanceOf(address(board)), 0);
        assertEq(board.getOrder(id).maker, address(0), "a filled order is gone");
    }

    function test_theTakerPaysRoundedUpWhenThePriceDoesNotDivideEvenly() public {
        uint256 id = sell(1000 * ONE, 0);
        uint256 before = usdc.balanceOf(maker);
        // 1.0000001 DIME x 0.04561 = 45,610.004561 atoms: the taker pays 45,611
        fill(id, ONE + 1e11);
        assertEq(usdc.balanceOf(maker) - before, 45_611);
    }

    function test_partialFillsRespectTheMinimumButTheLastRemainderMayBeSmaller() public {
        uint256 id = sell(25_000 * ONE, 10_000 * ONE);

        vm.prank(taker);
        vm.expectRevert(OtcBoard.BelowMinFill.selector);
        board.fill(id, 9_999 * ONE);

        fill(id, 10_000 * ONE);
        fill(id, 10_000 * ONE);
        assertEq(board.getOrder(id).remaining, 5_000 * ONE);
        fill(id, 5_000 * ONE); // under the minimum, but it is everything that is left
        assertEq(board.getOrder(id).maker, address(0));
    }

    function test_youCannotTakeMoreThanIsLeftOrNothing() public {
        uint256 id = sell(1000 * ONE, 0);
        vm.startPrank(taker);
        vm.expectRevert(OtcBoard.AboveRemaining.selector);
        board.fill(id, 1000 * ONE + 1);
        vm.expectRevert(OtcBoard.ZeroAmount.selector);
        board.fill(id, 0);
        vm.stopPrank();
    }

    function test_aFillWorthLessThanOneUsdcAtomIsRefused() public {
        // otherwise dust fills could take coins for a rounded-up 1 atom each... or, on a buy order, for 0
        uint256 id = buy(1000 * ONE, 0);
        vm.prank(taker);
        vm.expectRevert(OtcBoard.ZeroQuote.selector);
        board.fill(id, 1);
    }

    function test_anOrderExpiresAtItsExpirySecond() public {
        uint256 id = sell(1000 * ONE, 0);
        vm.warp(expiry - 1);
        fill(id, 500 * ONE);
        vm.warp(expiry);
        vm.prank(taker);
        vm.expectRevert(OtcBoard.Expired.selector);
        board.fill(id, 500 * ONE);
    }

    function test_aCancelledOrUnknownOrderCannotBeFilled() public {
        uint256 id = sell(1000 * ONE, 0);
        vm.prank(maker);
        board.cancel(id);
        vm.startPrank(taker);
        vm.expectRevert(OtcBoard.NoSuchOrder.selector);
        board.fill(id, ONE);
        vm.expectRevert(OtcBoard.NoSuchOrder.selector);
        board.fill(999, ONE);
        vm.stopPrank();
    }

    function test_aMakerMayFillTheirOwnOrder() public {
        // that is how you test it end to end with no counterparty
        uint256 id = sell(1000 * ONE, 0);
        uint256 dimeBefore = dime.balanceOf(maker);
        vm.prank(maker);
        board.fill(id, 1000 * ONE);
        assertEq(dime.balanceOf(maker) - dimeBefore, 1000 * ONE);
    }

    // --- filling a buy order -------------------------------------------------------------------------

    function test_aBuyOrderPaysTheTakerFromEscrow() public {
        uint256 id = buy(50_000 * ONE, 0);
        uint256 makerDime = dime.balanceOf(maker);
        uint256 takerUsdc = usdc.balanceOf(taker);

        fill(id, 20_000 * ONE);

        assertEq(dime.balanceOf(maker) - makerDime, 20_000 * ONE);
        assertEq(usdc.balanceOf(taker) - takerUsdc, 912_200_000); // 20,000 x 0.04561
        assertEq(board.getOrder(id).escrow, 2_280_500_000 - 912_200_000);
    }

    function test_roundingDustInABuyOrderGoesBackToTheMakerWhenItCloses() public {
        // 3 DIME at 3 atoms each escrows 9 atoms; two fills of 1.5 DIME are worth 4.5 atoms, paid as 4 each,
        // so 1 atom is left over when the order closes and must go home, not sit in the contract forever
        vm.prank(maker);
        uint256 id = board.createOrder(OtcBoard.Side.Buy, 3, 3 * ONE, 0, expiry, address(0));
        assertEq(usdc.balanceOf(address(board)), 9);
        uint256 makerUsdc = usdc.balanceOf(maker);
        fill(id, 15e17);
        fill(id, 15e17);
        assertEq(usdc.balanceOf(address(board)), 0, "nothing is left behind");
        assertEq(usdc.balanceOf(maker) - makerUsdc, 1, "the dust came home");
        assertEq(board.getOrder(id).maker, address(0));
    }

    // --- private offers ---------------------------------------------------------------------------------

    function privateSell(address only) internal returns (uint256) {
        vm.prank(maker);
        return board.createOrder(OtcBoard.Side.Sell, PRICE, 10_000 * ONE, 2_000 * ONE, expiry, only);
    }

    function test_aPrivateOfferRecordsWhoMayTakeIt() public {
        uint256 id = privateSell(taker);
        assertEq(board.getOrder(id).taker, taker);
        assertEq(board.getOrder(sell(1000 * ONE, 0)).taker, address(0), "no name means anyone");
    }

    function test_onlyTheNamedTakerCanFillAPrivateOffer() public {
        uint256 id = privateSell(taker);
        address stranger = makeAddr("stranger");
        usdc.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(board), type(uint256).max);
        vm.expectRevert(OtcBoard.NotYourOffer.selector);
        board.fill(id, 10_000 * ONE);
        vm.stopPrank();

        fill(id, 10_000 * ONE);
        assertEq(dime.balanceOf(taker), 1_000_000 * ONE + 10_000 * ONE);
    }

    function test_theNamedTakerCanFillInPartsWithinTheMinimum() public {
        uint256 id = privateSell(taker);
        vm.prank(taker);
        vm.expectRevert(OtcBoard.BelowMinFill.selector);
        board.fill(id, 1_000 * ONE);
        fill(id, 4_000 * ONE);
        assertEq(board.getOrder(id).remaining, 6_000 * ONE);
    }

    function test_aPrivateBuyOfferWorksTheSameWay() public {
        vm.prank(maker);
        uint256 id = board.createOrder(OtcBoard.Side.Buy, PRICE, 10_000 * ONE, 0, expiry, taker);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(OtcBoard.NotYourOffer.selector);
        board.fill(id, 10_000 * ONE);
        fill(id, 10_000 * ONE);
        assertEq(board.getOrder(id).maker, address(0));
    }

    function test_theMakerCanStillCancelAPrivateOffer() public {
        uint256 id = privateSell(taker);
        uint256 before = dime.balanceOf(maker);
        vm.prank(maker);
        board.cancel(id);
        assertEq(dime.balanceOf(maker) - before, 10_000 * ONE);
    }

    function test_aMakerMayReserveAnOfferForThemselves() public {
        // how you rehearse a private deal alone
        uint256 id = privateSell(maker);
        vm.prank(maker);
        board.fill(id, 10_000 * ONE);
        assertEq(board.getOrder(id).maker, address(0));
    }

    // --- cancelling ----------------------------------------------------------------------------------

    function test_onlyTheMakerCanCancelAndGetsBackWhatIsLeft() public {
        uint256 id = sell(10_000 * ONE, 0);
        fill(id, 4_000 * ONE);

        vm.prank(taker);
        vm.expectRevert(OtcBoard.NotMaker.selector);
        board.cancel(id);

        uint256 before = dime.balanceOf(maker);
        vm.prank(maker);
        board.cancel(id);
        assertEq(dime.balanceOf(maker) - before, 6_000 * ONE);
        assertEq(dime.balanceOf(address(board)), 0);

        vm.prank(maker);
        vm.expectRevert(OtcBoard.NoSuchOrder.selector);
        board.cancel(id);
    }

    function test_anExpiredOrderCanStillBeCancelledSoCoinsNeverGetStuck() public {
        uint256 id = buy(10_000 * ONE, 0);
        vm.warp(expiry + 365 days);
        uint256 before = usdc.balanceOf(maker);
        vm.prank(maker);
        board.cancel(id);
        assertEq(usdc.balanceOf(maker) - before, 456_100_000);
    }

    // --- nobody in charge ------------------------------------------------------------------------------

    function test_aFillMovesExactlyTheOrderAndNothingGoesToAThirdParty() public {
        uint256 id = buy(50_000 * ONE, 0);
        uint256 supply = usdc.balanceOf(maker) + usdc.balanceOf(taker) + usdc.balanceOf(address(board));
        fill(id, 50_000 * ONE);
        assertEq(usdc.balanceOf(maker) + usdc.balanceOf(taker), supply, "every atom stays between the two sides");
        assertEq(usdc.balanceOf(address(board)), 0);
        assertEq(usdc.balanceOf(address(factory)), 0);
    }

    function test_theFactoryHasNoWayToTouchEscrowedCoins() public {
        sell(10_000 * ONE, 0);
        vm.prank(address(factory));
        vm.expectRevert(OtcBoard.NotMaker.selector);
        board.cancel(1);
        assertEq(dime.balanceOf(address(board)), 10_000 * ONE);
    }

    // --- fuzz ------------------------------------------------------------------------------------------

    /// Whatever the sizes and price: nothing is created or lost, the maker gets the order's terms rounded up by at
    /// most one atom, the taker pays exactly what the maker gets, and the escrow balances.
    function testFuzz_aSellFillConservesEverything(uint96 amount, uint96 part, uint64 price) public {
        amount = uint96(bound(amount, ONE, 1_000_000 * ONE));
        part = uint96(bound(part, 1, amount));
        price = uint64(bound(price, 1, 1e9)); // up to 1,000 USDC per DIME
        vm.assume(uint256(part) * price >= 1e18); // at least one USDC atom
        usdc.mint(taker, uint256(amount) * price / 1e18 + 1e6); // enough for any fill

        vm.prank(maker);
        uint256 id = board.createOrder(OtcBoard.Side.Sell, price, amount, 0, expiry, address(0));
        uint256 supply = usdc.balanceOf(maker) + usdc.balanceOf(taker);
        uint256 makerUsdc = usdc.balanceOf(maker);
        uint256 takerUsdc = usdc.balanceOf(taker);

        fill(id, part);

        uint256 exact = uint256(part) * price;
        uint256 got = usdc.balanceOf(maker) - makerUsdc;
        assertGe(got * 1e18, exact, "the maker never gets less than the order");
        assertLt(got * 1e18, exact + 1e18, "and at most one atom more");
        assertEq(takerUsdc - usdc.balanceOf(taker), got, "the taker pays what the maker gets, no more");
        assertEq(usdc.balanceOf(maker) + usdc.balanceOf(taker), supply);
        assertEq(dime.balanceOf(address(board)), amount - part);
    }

    function testFuzz_aBuyOrderNeverPaysOutMoreThanItEscrowed(uint96 amount, uint96[4] memory parts, uint64 price)
        public
    {
        amount = uint96(bound(amount, ONE, 1_000_000 * ONE));
        price = uint64(bound(price, 1_000, 1e9));
        usdc.mint(maker, uint256(amount) * price / 1e18 + 1);
        vm.prank(maker);
        uint256 id = board.createOrder(OtcBoard.Side.Buy, price, amount, 0, expiry, address(0));

        uint256 left = amount;
        for (uint256 i; i < 4 && left > 0; i++) {
            uint256 part = i == 3 ? left : bound(parts[i], 1, left);
            if (part * price < 1e18) continue;
            fill(id, part);
            left -= part;
        }
        if (left == 0) assertEq(usdc.balanceOf(address(board)), 0, "a closed order leaves nothing behind");
        else assertEq(usdc.balanceOf(address(board)), board.getOrder(id).escrow);
    }
}
