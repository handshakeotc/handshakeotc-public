# Handshake OTC - design and pre-audit

Firm, escrowed OTC offers for any token pair on Ethereum, Arbitrum, Base and HyperEVM: the contracts, the edge cases
the tests pin, the design decisions, known trade-offs, and the pre-audit. Risks and trust assumptions are in
[`THREAT-MODEL.md`](THREAT-MODEL.md); deployed addresses are in the [README](../README.md).

## Contracts

- `src/OtcFactory.sol` - **no owner.** Anyone can create the one board for a pair that has none yet; the
  factory remembers it (`boardFor`, `isBoard`, `boards`). No listing, no fee, no quote allowlist, nothing to pause.
- `src/OtcBoard.sol` - one pair per board, no owner. Makers escrow, takers fill all or part, settlement is
  atomic. **The taker pays exactly the order: there is no fee.** Prices are per whole base token, whatever its
  decimals (`BASE_UNIT`).
- **Why no allowlist**: every board runs the same code and keeps its own escrow, so a strange quote token can only
  hurt the people who choose to trade against it. Which markets are worth showing is the site's decision
  (`src/deployments/*.json`), the way Uniswap's contracts accept any pair and its front end curates a token list.
- **What was given up**: delisting and stopping new orders. If a bug is found, the site stops showing the board and
  warns; resting orders can always be cancelled by their makers. That makes the audit matter more.
- **Why a factory with separate boards** rather than one contract with a token list: each market's escrow is
  kept apart, so a problem token or an accounting bug can only reach its own pair.
- **Quote tokens on the site at launch: USDC only.** A DIME/USDT or DIME/WETH board is one `createBoard` call
  away, by anyone. WETH
  rather than native ETH: ETH would need payable paths, refunds, and pull-payments so a maker contract that
  refuses ETH cannot block fills of its own order; the site can wrap ETH for users instead.
- Tests, all written before the contract (`forge test`):
  - unit: every rule and edge case below
  - fuzz: conservation of funds and rounding bounds for any size and price
  - invariant: under random creates, fills, cancels and time jumps from several actors, the
    contract holds exactly what its open orders say - nothing more (stranded dust) and nothing less
  - fork (run when `MAINNET_RPC_URL` is set, e.g. in `.env`): real DIME, Circle USDC, USDT and WETH, including a
    blacklisted maker and a DIME pause
  - symbolic (Halmos): see the pre-audit section
- `script/Deploy.s.sol` - Sepolia (mintable tDIME + Circle's Sepolia USDC) and mainnet; the deployer keeps no
  power once it is mined. `script/DeployLocal.s.sol` - a local Anvil chain with
  funded test accounts and seeded offers (one of them private).

### Edge cases pinned by tests

| Case | Behaviour |
|---|---|
| price, amount 0; minFill > amount; expiry now or past | refused |
| order or fill worth less than one unit of the quote token | refused (dust fills could otherwise take coins for nothing) |
| token that delivers less than sent (fee-on-transfer) | refused at escrow |
| same token on both sides, zero address | refused at board creation |
| price not dividing evenly | resting side gets the rounding: buyer pays up, seller is paid down |
| partial fill below minFill | refused, unless it takes everything that is left |
| rounding dust in a buy order | returned to the maker with the last fill; nothing stays behind |
| expiry | fillable while `timestamp < expiry`; cancellable forever after, so coins never get stuck |
| maker fills own order | allowed (how you test alone) - but see points below |
| admin | there is none: the factory has no owner, and the old owner functions are gone, not locked (tested) |
| anyone creates a board | allowed, once per pair; any token may be the quote side |
| private offer (`taker` set) | only that address can fill; the maker can still cancel; visible on chain (reserved, not hidden); off the public book on the site, shown to the named taker, shared by link |
| Circle blacklists a maker | fills paying them revert; a frozen maker's *buy* order cannot refund its USDC (the issuer's freeze, deliberately not routed around) |
| a token takes a cut on transfer (USDT's fee switch) | every transfer is checked for exact delivery, so the fill reverts instead of shorting anyone |
| USDT returns nothing from `transfer` | handled by SafeERC20; mock and mainnet fork tests |
| base token with 8 or 6 decimals, or absurd (> 36) | priced per whole coin; absurd decimals refused |
| same pair twice, zero address | refused by the factory |
| a fill | every quote atom goes from one side to the other; nothing reaches a third party (tested, fuzzed) |

## Design questions

**Can offers be seen on chain?** Yes - that is why this design escrows instead of using signed orders.
Every order is contract state (`getOrder(id)`) and every change is an event (`OrderCreated`, `OrderFilled`,
`OrderCancelled`). Anyone can rebuild the whole book from the chain, and every order shown is backed by coins
already in the contract, so there are no fake or unfunded offers. The price: creating and cancelling costs gas
(a few dollars at current gas), which is fine for block-sized OTC orders.

**Frontend only, no backend?** Yes, at this size. There is no matching engine: a taker picks an order and
fills it. The page reads events from the deploy block through a public RPC, and the wallet signs. It can be a
static site (Vite + React + wagmi/viem), hosted anywhere, even IPFS. The chain is the database.

**Show an order book?** Yes, as an exchange-style book: asks and bids sorted by price with depth bars, each with
size left, total, minimum fill and expiry, plus **the premium or discount to the market** (Paradex mid and the
Uniswap pool price, for DIME). That last column is what an OTC buyer actually decides on. Private offers stay off
the public book; a trade tape lists every fill with links to the transactions.

**Partial fills?** Supported, with a maker-set minimum fill so nobody can nibble an order into dust. A fill
takes an exact amount or reverts, so a taker is never surprised; if someone fills first, the transaction
fails instead of filling less.

**A general OTC market?** Built in:
- **Factory**: one `OtcBoard` per pair. Each board stays simple and isolated; a bug in one pair cannot touch
  another. Anyone creates pairs; nobody can delist them.
- **Curated on the site, not in the contracts**: only boards the factory created are shown (`npm run add-market`), logos are
  matched by token address, and every number is scaled by the market's own decimals. Rebasing tokens break escrow
  accounting and must never be listed.

**Would that need a backend?** The core never does. A backend appears for *convenience*, and it is always a
read-only cache the chain can rebuild:
1. an **indexer** (Ponder, Envio or The Graph) once scanning logs on every page load gets slow;
2. **notifications** (your order filled, a block above X appeared) - Discord or Telegram;
3. **signed gasless orders** (an optional v2, 0x/AirSwap style) - these need a relay to publish signatures;
4. a **points programme** (below).

**Points programme?** Computed off-chain from `OrderFilled` events: volume per address per epoch, maker vs
taker weights. It needs the indexer plus a small service and an API. Rules to decide before launch:
- **wash trading** is the whole game - self-fills are allowed in the contract (useful for testing), so points
  must exclude them, and two wallets trading with each other are hard to exclude. With no fee, farming points
  costs only gas.
- **publish the formula** so anyone can recompute their points from the chain.
- **legal**: points that are expected to convert into a token or a share of revenue raise the same questions
  as a fee - lawyer first.

## Known trade-offs

- **Escrow vs signed orders**: escrow gives an honest on-chain book with no backend, at the cost of gas per
  order and the contract holding funds (hence the invariant tests and, later, an audit).
- **No price improvement / auto-matching**: a bid above an ask is simply an arbitrage anyone can take.
- **Front-running**: a fill can be beaten by another taker; it then reverts, costing only gas. Prices cannot be
  sandwiched because they are fixed per order.
- **Linter findings reviewed**: timestamp comparisons (second-level expiry, acceptable), events after calls
  (false positives: events precede transfers, every entry point is `nonReentrant`, and the only calls before
  events are a token's `decimals`, a `view` call), strict balance equality (intended: exact delivery or refuse).
  To re-run on the ownerless contracts.
- **Curating on the site** still makes the operator choose what is shown. It is the part of the project closest to
  "operating a trading platform", which is why the site takes no money for it.

## Pre-audit, 2026-09-26

*Done on the owned factory with a fee. The fee findings below no longer apply: that code is gone.*

Not an audit: the author reviewing their own code, plus free tools. An independent audit is still required
before anyone else's money is in the contracts.

- **Slither 0.11.6**: 81 detectors, 2 low findings, both `block.timestamp` comparisons for expiry (seconds of
  validator drift on offers that last days; accepted).
- **Aderyn 0.6.8**: 88 detectors. One "high", a false positive: "state change after external call" at the
  factory reads in `createOrder` and `decimals()` in the constructor. All are `view` calls, which compile to
  STATICCALL and cannot re-enter (and `createOrder` is `nonReentrant`). Two lows: owner powers (by design, see
  `docs/THREAT-MODEL.md`) and `10_000` instead of `1e4` (kept: clearer as basis points).
- **Threat model**: `docs/THREAT-MODEL.md`. It found DIME is an upgradeable, pausable, mintable token whose
  roles sit with one 2-of-3 Safe; a fork test now pins what a pause does (coins wait, nothing is lost).
- **Manual review** (reentrancy, rounding, overflow, token quirks, owner powers, denial of service):
  1. *Medium, fixed.* The fee recipient was read at fill time, so the owner (or a stolen owner key) could point
     it at an address the quote token refuses and freeze every fill of orders carrying a fee. Orders now record
     their recipient at creation (`feeTo`).
  2. *Low, fixed.* A board could be set as fee recipient, stranding fees. `setFee` now refuses it.
  3. *Low, documented.* A USDC-blacklisted maker cannot be paid or refunded in USDC: the issuer's freeze.
- **Halmos 0.3.3** (symbolic, `test/OtcBoard.halmos.t.sol`, run with `FOUNDRY_PROFILE=halmos halmos --contract
  OtcBoardSymbolicTest`), proven for every input:
  - only the named taker can fill a private offer (anyone else, even funded, gets `NotYourOffer`);
  - a buy order's escrow covers any split into two fills and closing it leaves nothing behind;
  *Not proven:* "a sell fill pays the maker exactly the rounded-up price" timed out at 10 minutes, with no
  counterexample: SMT solvers struggle with OpenZeppelin's 512-bit `mulDiv`. It remains covered by the fuzz
  test (1,000 runs of random size and price) and the invariant test.
