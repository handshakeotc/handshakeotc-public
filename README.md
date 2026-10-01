# Handshake OTC - contracts

*Agree in DMs. Settle on-chain.*

Firm, escrowed OTC offers for any token, on Ethereum, Arbitrum, Base and HyperEVM. A maker's tokens sit in the contract until
the offer is taken (fully or in parts) or cancelled; settlement is atomic. There is no owner and no fee: anyone can
create the board for a pair, and a taker pays exactly the order.

This repository holds the contracts, their tests and the deploy script. The site that uses them is
https://handshakeotc.com.

- Factories: Ethereum `0x8308a7c85287b1a0ba6c249b743273e0880244f4`, Arbitrum `0xfbbc5dfb448aab524d98688fbd76ae54dfd7cc59`,
  Base and HyperEVM `0xb4b2debbbf362ce795ad993688587bf30cb9f826` (all verified, no owner)
- Contracts: [`src/OtcFactory.sol`](src/OtcFactory.sol) (creates and remembers boards) and [`src/OtcBoard.sol`](src/OtcBoard.sol) (one market)
- Design, edge cases, trade-offs, pre-audit: [`docs/DESIGN.md`](docs/DESIGN.md). Threat model: [`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md)
- Deploy: [`script/Deploy.s.sol`](script/Deploy.s.sol); the deployer keeps no power once it is mined.

```bash
git clone --recurse-submodules https://github.com/handshakeotc/handshakeotc-public.git
forge test                                           # unit, fuzz, invariant; fork tests when MAINNET_RPC_URL is set (.env)
FOUNDRY_PROFILE=halmos halmos --contract OtcBoardSymbolicTest   # symbolic proofs (pip install halmos)
```

**Unaudited.** A pre-audit is done (Slither, a manual review with its findings fixed, Halmos proofs; see
`docs/DESIGN.md`), but an independent audit is still required. Do not put other people's money in it.

MIT licensed (`LICENSE`).
