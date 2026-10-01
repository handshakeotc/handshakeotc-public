// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Stand-in for DIME (18 decimals) and USDC (6 decimals) in unit tests.
contract MockToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory symbol, uint8 decimals_) ERC20(symbol, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Keeps 1% of every transfer. The board must refuse to escrow it rather than record more than it holds.
contract FeeOnTransferToken is MockToken {
    constructor() MockToken("FOT", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 cut = value / 100;
            super._update(from, address(0xdead), cut);
            value -= cut;
        }
        super._update(from, to, value);
    }
}

/// Behaves like Tether's USDT: transfer/transferFrom/approve return nothing, approve refuses to change a
/// non-zero allowance, and the issuer can switch on a fee that the recipient bears.
contract UsdtLikeToken {
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;
    uint256 public basisPointsRate;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFee(uint256 bps) external {
        basisPointsRate = bps;
    }

    function approve(address spender, uint256 amount) external {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "USDT: reset to 0 first");
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 fee = amount * basisPointsRate / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
    }
}
