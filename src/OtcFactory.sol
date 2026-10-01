// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OtcBoard} from "./OtcBoard.sol";

/// @title OtcFactory - creates one OtcBoard per token pair and remembers where it is
/// @notice Nobody owns it. Anyone can create the board for a pair that has none yet; every board runs the same
///         code, so who created it makes no difference. There is no fee, no listing and nothing to pause.
///         Which markets are worth showing is left to whoever builds a front end.
/// @dev    One board per pair keeps each market's escrow separate, so a problem token can only affect its own
///         pair, and keeps a pair's orders in one place.
contract OtcFactory {
    mapping(address base => mapping(address quote => address)) public boardFor;
    mapping(address board => bool) public isBoard;
    address[] public boards;

    event BoardCreated(address indexed board, address indexed base, address indexed quote);

    error BoardExists();
    error BadPair();

    function createBoard(IERC20 base, IERC20 quote) external returns (OtcBoard board) {
        if (address(base) == address(0) || address(quote) == address(0) || base == quote) revert BadPair();
        if (boardFor[address(base)][address(quote)] != address(0)) revert BoardExists();
        board = new OtcBoard(base, quote);
        boardFor[address(base)][address(quote)] = address(board);
        isBoard[address(board)] = true;
        boards.push(address(board));
        emit BoardCreated(address(board), address(base), address(quote));
    }

    function boardCount() external view returns (uint256) {
        return boards.length;
    }
}
