// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OtcFactory} from "../src/OtcFactory.sol";
import {OtcBoard} from "../src/OtcBoard.sol";
import {MockToken} from "../test/mocks/MockToken.sol";

/// The factory has no owner, so the deployer keeps no power over it once the transaction is mined.
/// The signer comes from `--account` (an encrypted Foundry keystore), never from a private key in an env file.
///   forge script script/Deploy.s.sol:DeployMainnet --rpc-url mainnet --account mainnet-deployer --broadcast --verify
contract DeployMainnet is Script {
    IERC20 constant DIME = IERC20(0xb32E10022FFBeDfE10bc818a1C7e67D9d87e0fa7);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Any other pair, such as DIME/USDT or DIME/WETH, is one createBoard call away, by anyone.

    function run() external returns (OtcFactory factory, OtcBoard board) {
        vm.startBroadcast();
        factory = new OtcFactory();
        board = factory.createBoard(DIME, IERC20(USDC));
        vm.stopBroadcast();
        console.log("OtcFactory", address(factory));
        console.log("DIME/USDC board", address(board));
    }
}

/// Only the factory, for a network whose markets come from the site's token list (Arbitrum, Base, HyperEVM): anyone creates a
/// board when they post the first offer on a pair, so none is needed up front.
///   forge script script/Deploy.s.sol:DeployFactory --rpc-url arbitrum --account mainnet-deployer --broadcast --slow --verify
///   forge script script/Deploy.s.sol:DeployFactory --rpc-url base --account mainnet-deployer --broadcast --slow --verify
///   forge script script/Deploy.s.sol:DeployFactory --rpc-url hyperevm --account mainnet-deployer --broadcast --slow --verify
contract DeployFactory is Script {
    function run() external returns (OtcFactory factory) {
        vm.startBroadcast();
        factory = new OtcFactory();
        vm.stopBroadcast();
        console.log("OtcFactory", address(factory));
    }
}

/// A mintable stand-in for DIME, a million of it minted to the deployer, against Circle's Sepolia USDC
/// (free from faucet.circle.com).
///   forge script script/Deploy.s.sol:DeploySepolia --rpc-url sepolia --account deployer --broadcast --verify
contract DeploySepolia is Script {
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    function run() external returns (OtcFactory factory, OtcBoard board, MockToken dime) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers(); // inside a script msg.sender is not the signer
        dime = new MockToken("tDIME", 18);
        dime.mint(deployer, 1_000_000e18);
        factory = new OtcFactory();
        board = factory.createBoard(IERC20(address(dime)), IERC20(USDC));
        vm.stopBroadcast();
        console.log("tDIME", address(dime));
        console.log("OtcFactory", address(factory));
        console.log("tDIME/USDC board", address(board));
    }
}
