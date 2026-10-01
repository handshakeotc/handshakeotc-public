// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OtcBoard - firm, escrowed OTC orders for one token pair, created by an OtcFactory
/// @notice A maker posts an order and its coins move into this contract; any taker may fill all or part of it
///         at the posted price. Settlement is atomic, so neither side has to trust the other or anyone else.
/// @dev    Rules, each pinned by a test:
///         - the maker receives exactly the order's terms and the taker pays exactly them: there is no fee
///         - rounding favours the resting side
///         - every transfer must deliver exactly what was sent, or the call reverts (USDT can switch a fee on)
///         - a private order names its only taker; "private" means reserved, not hidden - it is on chain
///         - nobody can pause, upgrade, delist or withdraw from a board. It has no owner.
///         Prices are quote atoms per whole base token (BASE_UNIT atoms), whatever the base token's decimals.
///         Known limit: a maker the quote token blacklists (USDC can freeze addresses) cannot be paid, so their fills
///         revert, and a frozen maker's buy order cannot refund its USDC escrow either. That is the issuer's freeze
///         of that address, not something this contract can or should route around.
contract OtcBoard is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Side {
        Sell, // the maker sells base for quote; base is escrowed
        Buy // the maker buys base with quote; quote is escrowed
    }

    struct Order {
        address maker;
        Side side;
        uint64 expiry; // unix seconds; fillable while block.timestamp < expiry
        uint256 price; // quote atoms per BASE_UNIT base atoms, i.e. per whole base token
        uint256 remaining; // base atoms still available
        uint256 minFill; // smallest fill accepted, unless it takes everything that is left
        uint256 escrow; // atoms held for this order: base for a sell, quote for a buy
        address taker; // the only address that may fill it, or address(0) for anyone
    }

    address public immutable factory; // where the board came from; the factory has no say over it
    IERC20 public immutable base;
    IERC20 public immutable quote;
    uint256 public immutable BASE_UNIT; // 10 ** base decimals: 1e18 for DIME, 1e8 for WBTC

    uint256 public nextId = 1; // 0 is never an order id

    mapping(uint256 id => Order) private _orders;

    event OrderCreated(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        Side side,
        uint256 price,
        uint256 amount,
        uint256 minFill,
        uint64 expiry
    );
    event OrderFilled(
        uint256 indexed id, address indexed taker, uint256 amount, uint256 quoteAmount, uint256 remaining
    );
    event OrderCancelled(uint256 indexed id, uint256 refund);

    error BadDecimals();
    error ZeroPrice();
    error ZeroAmount();
    error ZeroQuote();
    error MinFillAboveAmount();
    error AlreadyExpired();
    error TransferShortfall();
    error NoSuchOrder();
    error Expired();
    error AboveRemaining();
    error BelowMinFill();
    error NotMaker();
    error NotYourOffer();

    /// @dev Called by the factory, which has already checked the pair.
    constructor(IERC20 base_, IERC20 quote_) {
        uint8 decimals = IERC20Metadata(address(base_)).decimals();
        if (decimals > 36) revert BadDecimals(); // keeps amount x price far from overflow in mulDiv
        factory = msg.sender;
        base = base_;
        quote = quote_;
        BASE_UNIT = 10 ** decimals;
    }

    // --- makers --------------------------------------------------------------------------------------

    /// @param taker the only address allowed to fill it (a deal agreed elsewhere), or address(0) for anyone
    function createOrder(Side side, uint256 price, uint256 amount, uint256 minFill, uint64 expiry, address taker)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (price == 0) revert ZeroPrice();
        if (amount == 0) revert ZeroAmount();
        if (minFill > amount) revert MinFillAboveAmount();
        if (expiry <= block.timestamp) revert AlreadyExpired();
        uint256 worth = Math.mulDiv(amount, price, BASE_UNIT);
        if (worth == 0) revert ZeroQuote();

        (IERC20 token, uint256 escrow) = side == Side.Sell ? (base, amount) : (quote, worth);
        id = nextId++;
        _orders[id] = Order({
            maker: msg.sender,
            side: side,
            expiry: expiry,
            price: price,
            remaining: amount,
            minFill: minFill,
            escrow: escrow,
            taker: taker
        });
        emit OrderCreated(id, msg.sender, taker, side, price, amount, minFill, expiry);

        _pay(token, msg.sender, address(this), escrow);
    }

    /// @notice Returns what is left of the order to its maker. Works after expiry too, so coins never get stuck.
    function cancel(uint256 id) external nonReentrant {
        Order memory o = _orders[id];
        if (o.maker == address(0)) revert NoSuchOrder();
        if (o.maker != msg.sender) revert NotMaker();
        delete _orders[id];
        emit OrderCancelled(id, o.escrow);
        _pay(o.side == Side.Sell ? base : quote, address(this), o.maker, o.escrow);
    }

    // --- takers --------------------------------------------------------------------------------------

    /// @param amount base atoms to take; exactly this much or the call reverts, so a taker is never surprised
    function fill(uint256 id, uint256 amount) external nonReentrant {
        Order storage o = _orders[id];
        address maker = o.maker;
        if (maker == address(0)) revert NoSuchOrder();
        if (o.taker != address(0) && o.taker != msg.sender) revert NotYourOffer();
        if (block.timestamp >= o.expiry) revert Expired();
        if (amount == 0) revert ZeroAmount();
        if (amount > o.remaining) revert AboveRemaining();
        if (amount < o.minFill && amount != o.remaining) revert BelowMinFill();
        if (Math.mulDiv(amount, o.price, BASE_UNIT) == 0) revert ZeroQuote();

        Side side = o.side;
        // the resting side gets the rounding: a buyer pays rounded up, a seller is paid rounded down
        uint256 quoteAmount =
            Math.mulDiv(amount, o.price, BASE_UNIT, side == Side.Sell ? Math.Rounding.Ceil : Math.Rounding.Floor);

        uint256 remaining = o.remaining - amount;
        uint256 dust = 0;
        if (side == Side.Sell) {
            o.escrow -= amount;
        } else {
            o.escrow -= quoteAmount;
        }
        if (remaining == 0) {
            dust = o.escrow; // a buy order's rounding leftovers go home with the last fill
            delete _orders[id];
        } else {
            o.remaining = remaining;
        }
        emit OrderFilled(id, msg.sender, amount, quoteAmount, remaining);

        if (side == Side.Sell) {
            _pay(quote, msg.sender, maker, quoteAmount);
            _pay(base, address(this), msg.sender, amount);
        } else {
            _pay(base, msg.sender, maker, amount);
            _pay(quote, address(this), msg.sender, quoteAmount);
            _pay(quote, address(this), maker, dust);
        }
    }

    /// @dev Moves tokens and checks the recipient got exactly `amount`: a token that takes a cut (USDT can switch
    ///      a fee on) makes the call revert instead of shorting someone. A move to oneself nets to zero and is
    ///      not checked, which is what lets a maker fill their own order.
    function _pay(IERC20 token, address from, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 before = token.balanceOf(to);
        if (from == address(this)) token.safeTransfer(to, amount);
        else token.safeTransferFrom(from, to, amount);
        if (from != to && token.balanceOf(to) - before != amount) revert TransferShortfall();
    }

    // --- views ---------------------------------------------------------------------------------------

    function getOrder(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }
}
