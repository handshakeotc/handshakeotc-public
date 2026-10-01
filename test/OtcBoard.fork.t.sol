// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OtcBoard} from "../src/OtcBoard.sol";
import {OtcFactory} from "../src/OtcFactory.sol";

/// Against the real tokens on a mainnet fork: DIME and Circle's USDC (a proxy with a blacklist), which mocks
/// cannot stand in for. Skipped unless MAINNET_RPC_URL is set.
contract OtcBoardForkTest is Test {
    IERC20 constant DIME = IERC20(0xb32E10022FFBeDfE10bc818a1C7e67D9d87e0fa7);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    /// a 2-of-3 Safe holding every DIME role: pause, mint and upgrade
    address constant DIME_ADMIN = 0xF1f82188E7D3B54b8872986869D4207F8A78A4F1;

    OtcFactory factory;
    OtcBoard board;
    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    bool live;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;
        factory = new OtcFactory();
        board = factory.createBoard(DIME, USDC);
        deal(address(DIME), maker, 100_000e18);
        deal(address(USDC), taker, 10_000e6);
        vm.prank(maker);
        DIME.approve(address(board), type(uint256).max);
        vm.prank(taker);
        USDC.approve(address(board), type(uint256).max);
    }

    function test_aRealDimeBlockSellsForRealUsdc() public {
        if (!live) return vm.skip(true);
        vm.prank(maker);
        uint256 id = board.createOrder(
            OtcBoard.Side.Sell, 52_000, 50_000e18, 10_000e18, uint64(block.timestamp + 1 days), address(0)
        );

        vm.prank(taker);
        board.fill(id, 50_000e18);

        assertEq(DIME.balanceOf(taker), 50_000e18);
        assertEq(USDC.balanceOf(maker), 2_600e6); // 50,000 x 0.052
        assertEq(USDC.balanceOf(taker), 7_400e6, "the taker paid exactly the order");
        assertEq(DIME.balanceOf(address(board)), 0);
    }

    function test_aFillPayingABlacklistedMakerRevertsAndTheMakerCanStillCancel() public {
        if (!live) return vm.skip(true);
        vm.prank(maker);
        uint256 id =
            board.createOrder(OtcBoard.Side.Sell, 52_000, 1_000e18, 0, uint64(block.timestamp + 1 days), address(0));

        // Circle's blacklister freezes the maker: USDC can no longer be sent to them
        (bool ok, bytes memory who) = address(USDC).staticcall(abi.encodeWithSignature("blacklister()"));
        require(ok, "blacklister()");
        vm.prank(abi.decode(who, (address)));
        (ok,) = address(USDC).call(abi.encodeWithSignature("blacklist(address)", maker));
        require(ok, "blacklist");

        vm.prank(taker);
        vm.expectRevert();
        board.fill(id, 1_000e18);

        vm.prank(maker);
        board.cancel(id); // their DIME is not stuck
        assertEq(DIME.balanceOf(maker), 100_000e18);
    }

    function test_realUsdtAndWethBoardsSettle() public {
        if (!live) return vm.skip(true);
        OtcBoard usdtBoard = factory.createBoard(DIME, USDT);
        OtcBoard wethBoard = factory.createBoard(DIME, WETH);
        deal(address(USDT), taker, 1_000e6);
        deal(address(WETH), taker, 1e18);
        vm.startPrank(maker);
        DIME.approve(address(usdtBoard), type(uint256).max);
        DIME.approve(address(wethBoard), type(uint256).max);
        uint64 later = uint64(block.timestamp + 1 days);
        uint256 a = usdtBoard.createOrder(OtcBoard.Side.Sell, 50_000, 10_000e18, 0, later, address(0));
        uint256 b = wethBoard.createOrder(OtcBoard.Side.Sell, 11_500_000_000_000, 10_000e18, 0, later, address(0));
        vm.stopPrank();

        vm.startPrank(taker);
        (bool ok,) = address(USDT).call(abi.encodeWithSignature("approve(address,uint256)", address(usdtBoard), 500e6));
        require(ok, "usdt approve");
        usdtBoard.fill(a, 10_000e18);
        WETH.approve(address(wethBoard), 1e18);
        wethBoard.fill(b, 10_000e18);
        vm.stopPrank();

        assertEq(USDT.balanceOf(maker), 500e6);
        assertEq(WETH.balanceOf(maker), 0.115e18);
    }

    function test_whileDimeIsPausedOnlyBuyOrdersCanBeCancelledAndEverythingResumesAfter() public {
        // DIME's admin Safe can pause every transfer: coins in escrow wait, nothing is lost
        if (!live) return vm.skip(true);
        deal(address(USDC), maker, 1_000e6);
        uint64 later = uint64(block.timestamp + 1 days);
        vm.startPrank(maker);
        USDC.approve(address(board), type(uint256).max);
        uint256 selling = board.createOrder(OtcBoard.Side.Sell, 52_000, 1_000e18, 0, later, address(0));
        uint256 buying = board.createOrder(OtcBoard.Side.Buy, 50_000, 1_000e18, 0, later, address(0));
        vm.stopPrank();
        deal(address(DIME), taker, 1_000e18);
        vm.prank(taker);
        DIME.approve(address(board), type(uint256).max);

        vm.prank(DIME_ADMIN);
        (bool ok,) = address(DIME).call(abi.encodeWithSignature("pause()"));
        require(ok, "pause");

        vm.prank(taker);
        vm.expectRevert();
        board.fill(selling, 1_000e18);
        vm.prank(taker);
        vm.expectRevert();
        board.fill(buying, 1_000e18);
        vm.prank(maker);
        vm.expectRevert();
        board.cancel(selling); // the escrowed DIME cannot move until the Safe unpauses
        vm.prank(maker);
        board.cancel(buying); // the refund is USDC, which is not paused
        assertEq(USDC.balanceOf(maker), 1_000e6);

        vm.prank(DIME_ADMIN);
        (ok,) = address(DIME).call(abi.encodeWithSignature("unpause()"));
        require(ok, "unpause");
        vm.prank(taker);
        board.fill(selling, 1_000e18);
        assertEq(DIME.balanceOf(taker), 2_000e18);
    }
}
