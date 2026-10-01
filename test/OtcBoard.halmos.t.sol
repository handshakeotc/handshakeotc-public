// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {OtcBoard} from "../src/OtcBoard.sol";
import {OtcFactory} from "../src/OtcFactory.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// Symbolic tests for Halmos (a16z): each `check_` function is proven for every possible input, not sampled.
/// forge ignores them (they are not `test_`); run with
///   halmos --contract OtcBoardSymbolicTest
/// Prices are fixed per check where a symbolic price times a symbolic amount would make the solver's job
/// non-linear; the amount stays fully symbolic.
contract OtcBoardSymbolicTest is Test {
    OtcFactory factory;
    OtcBoard board;
    MockToken dime;
    MockToken usdc;

    address maker = address(0xA11CE);
    address taker = address(0xB0B);

    uint256 constant AMOUNT = 1_000_000e18; // one million DIME on offer
    uint256 constant PRICE = 45_610; // 0.04561 USDC per DIME
    uint64 constant EXPIRY = 2_000_000_000;

    function setUp() public {
        dime = new MockToken("DIME", 18);
        usdc = new MockToken("USDC", 6);
        factory = new OtcFactory();
        board = factory.createBoard(dime, usdc);

        dime.mint(maker, 10_000_000e18);
        usdc.mint(maker, 10_000_000e6);
        dime.mint(taker, 10_000_000e18);
        usdc.mint(taker, 10_000_000e6);
        vm.startPrank(maker);
        dime.approve(address(board), type(uint256).max);
        usdc.approve(address(board), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(taker);
        dime.approve(address(board), type(uint256).max);
        usdc.approve(address(board), type(uint256).max);
        vm.stopPrank();
    }

    /// 1. Nobody but the named taker can fill a private offer - even someone funded and approved.
    function check_onlyTheNamedTakerCanFillAPrivateOffer(address caller) public {
        vm.assume(caller != taker && caller != address(0) && caller != address(board));
        vm.prank(maker);
        uint256 id = board.createOrder(OtcBoard.Side.Sell, PRICE, 1_000e18, 0, EXPIRY, taker);
        usdc.mint(caller, 1_000e6);
        vm.prank(caller);
        usdc.approve(address(board), type(uint256).max);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(board).call(abi.encodeCall(OtcBoard.fill, (id, 1_000e18)));
        assert(!ok);
        assert(bytes4(ret) == OtcBoard.NotYourOffer.selector);
    }

    /// 2. Any sell fill settles exactly: the maker gets the order's price rounded up to the next USDC atom
    ///    (never less), the taker gets exactly the DIME, and the escrow shrinks by exactly that.
    ///    `part` is a uint80, which covers the whole million-DIME order (1e24 < 2^80) and keeps the solver fast.
    function check_aSellFillSettlesExactly(uint80 part) public {
        vm.assume(part > 0 && part <= AMOUNT && uint256(part) * PRICE >= 1e18);
        vm.prank(maker);
        uint256 id = board.createOrder(OtcBoard.Side.Sell, PRICE, AMOUNT, 0, EXPIRY, address(0));
        uint256 makerUsdc = usdc.balanceOf(maker);
        uint256 takerDime = dime.balanceOf(taker);

        vm.prank(taker);
        board.fill(id, part);

        assert(usdc.balanceOf(maker) - makerUsdc == (uint256(part) * PRICE + 1e18 - 1) / 1e18);
        assert(dime.balanceOf(taker) - takerDime == part);
        assert(dime.balanceOf(address(board)) == AMOUNT - part);
    }

    /// 3. A buy order's escrow covers any split into two fills, and closing it leaves nothing in the contract.
    function check_aBuyOrderEscrowCoversAnySplit(uint256 first) public {
        vm.assume(first > 0 && first < AMOUNT && first * PRICE >= 1e18 && (AMOUNT - first) * PRICE >= 1e18);
        vm.prank(maker);
        uint256 id = board.createOrder(OtcBoard.Side.Buy, PRICE, AMOUNT, 0, EXPIRY, address(0));

        vm.startPrank(taker);
        board.fill(id, first);
        board.fill(id, AMOUNT - first);
        vm.stopPrank();

        assert(usdc.balanceOf(address(board)) == 0);
        assert(board.getOrder(id).maker == address(0));
    }
}
