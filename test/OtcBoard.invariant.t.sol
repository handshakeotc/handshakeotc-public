// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {OtcBoard} from "../src/OtcBoard.sol";
import {OtcFactory} from "../src/OtcFactory.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// Drives the board with random creates, fills, cancels and time jumps from several actors.
contract Handler is Test {
    OtcBoard public board;
    MockToken public dime;
    MockToken public usdc;
    address[] public actors;

    constructor(OtcBoard board_, MockToken dime_, MockToken usdc_) {
        board = board_;
        dime = dime_;
        usdc = usdc_;
        for (uint256 i; i < 4; i++) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            dime.mint(a, 10_000_000e18);
            usdc.mint(a, 10_000_000e6);
            vm.startPrank(a);
            dime.approve(address(board), type(uint256).max);
            usdc.approve(address(board), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function create(
        uint256 who,
        bool isSell,
        uint256 price,
        uint256 amount,
        uint256 minFill,
        uint256 life,
        uint256 only
    ) external {
        price = bound(price, 1, 1e8);
        amount = bound(amount, 1e18, 1_000_000e18);
        minFill = bound(minFill, 0, amount);
        life = bound(life, 1, 30 days);
        if (!isSell && amount * price < 1e18) return;
        vm.prank(_actor(who));
        board.createOrder(
            isSell ? OtcBoard.Side.Sell : OtcBoard.Side.Buy,
            price,
            amount,
            minFill,
            uint64(block.timestamp + life),
            only % 3 == 0 ? _actor(only / 3) : address(0)
        );
    }

    function fill(uint256 who, uint256 idSeed, uint256 amount) external {
        uint256 next = board.nextId();
        if (next == 1) return;
        uint256 id = 1 + idSeed % (next - 1);
        OtcBoard.Order memory o = board.getOrder(id);
        if (o.maker == address(0) || block.timestamp >= o.expiry) return;
        amount = bound(amount, o.minFill == 0 ? 1 : o.minFill, o.remaining);
        if (amount < o.minFill && amount != o.remaining) return;
        if (amount * o.price < 1e18) return;
        address taker = _actor(who);
        if (o.taker != address(0) && taker != o.taker) {
            // someone else trying a private offer must be refused and change nothing
            vm.prank(taker);
            vm.expectRevert(OtcBoard.NotYourOffer.selector);
            board.fill(id, amount);
            return;
        }
        vm.prank(taker);
        board.fill(id, amount);
    }

    function cancel(uint256 idSeed) external {
        uint256 next = board.nextId();
        if (next == 1) return;
        uint256 id = 1 + idSeed % (next - 1);
        OtcBoard.Order memory o = board.getOrder(id);
        if (o.maker == address(0)) return;
        vm.prank(o.maker);
        board.cancel(id);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 7 days));
    }
}

contract OtcBoardInvariantTest is Test {
    OtcFactory factory;
    OtcBoard board;
    MockToken dime;
    MockToken usdc;
    Handler handler;

    function setUp() public {
        dime = new MockToken("DIME", 18);
        usdc = new MockToken("USDC", 6);
        factory = new OtcFactory();
        board = factory.createBoard(dime, usdc);
        handler = new Handler(board, dime, usdc);
        targetContract(address(handler));
    }

    /// The contract holds exactly what its open orders say: every escrowed coin is owed to a maker, and
    /// nothing is stranded (filled and cancelled orders leave zero behind, including rounding dust).
    function invariant_escrowMatchesOpenOrders() public view {
        uint256 dimeOwed;
        uint256 usdcOwed;
        for (uint256 id = 1; id < board.nextId(); id++) {
            OtcBoard.Order memory o = board.getOrder(id);
            if (o.maker == address(0)) continue;
            if (o.side == OtcBoard.Side.Sell) {
                assertEq(o.escrow, o.remaining, "a sell order escrows exactly what is left");
                dimeOwed += o.escrow;
            } else {
                assertGe(
                    o.escrow * 1e18,
                    o.remaining * o.price - (o.remaining * o.price) % 1e18,
                    "a buy order can always pay for what is left"
                );
                usdcOwed += o.escrow;
            }
        }
        assertEq(dime.balanceOf(address(board)), dimeOwed);
        assertEq(usdc.balanceOf(address(board)), usdcOwed);
    }
}
