# Threat model

What can go wrong, who could do it, and what stops them. Written 2026-09-26 for the contracts in `src/` and the
site at handshakeotc.com, updated 2026-09-29 (ownerless factories on Ethereum, Arbitrum, Base and HyperEVM; any token), before
an independent audit. Findings and tools are in `docs/DESIGN.md` (pre-audit).

## What is worth stealing

- **Escrow**: every open order's coins sit in its board. This is the prize.
- **Allowances**: a wallet that approved a board more than it needed. The site approves exact amounts only.
- **Users' attention**: a fake site or a fake token can take more than any contract bug.

## Who could attack, and what they can do

| Actor | Can | Cannot | Why not |
|---|---|---|---|
| **Taker** | fill any public order at its price, partially down to `minFill` | pay less, take more, fill a private offer that is not theirs | exact-amount fills, rounding favours the resting side, `NotYourOffer`; fuzzed, invariant-tested, Halmos-proven for private offers |
| **Maker** | cancel any time, even after expiry | change price or size of a live order, take back more than is left | orders are immutable; a "new price" is a new id, so a taker's fill can never land on terms they did not see |
| **Reentrant token / contract** | call back during a transfer | reach a second state change | `nonReentrant` on every state-changing function, state written before transfers |
| **Anyone creating boards** | create the one board for any pair, with any token on either side | change how a board works, touch another board | every board runs the same code with its own escrow; a hostile token only reaches those who trade against it, and the site shows only boards it lists |
| **Deployer** (the project wallet) | nothing after the deploy | set a fee, delist, pause, touch escrow | the factory has no owner and no such functions (tested) |
| **Token issuer** (Circle for USDC; a 2-of-3 Safe for DIME, which holds pause, mint and upgrade) | pause, blacklist, upgrade the token | - | nothing a board can do: it holds their token. See below |
| **Miner / validator** | reorder, front-run, shift `block.timestamp` by seconds | profit from ordering beyond what a firm quote already offers | offers are firm and single-price: front-running a fill only means someone else took the same deal; expiry drift is seconds on offers that last days |
| **Site operator / account thief** (Cloudflare, GitHub, domain) | ship JavaScript that asks wallets to sign something else (another board, an unlimited approval, a transfer) | change the contracts | see "The site" below: this is the most likely real-world loss |
| **Phisher** | clone the site on a look-alike domain, deploy a fake "DIME" | - | users must check the domain and the board address; the site lists boards by address, logos by token address |
| **Scam-token issuer** | paste-able: anyone can open a market for any contract, e.g. a fake "USDC" or a token with a hidden owner switch | appear in the search or look listed | only listed tokens are searchable; a pasted contract opens with a warning to check its address and a link to it |

## Tokens: what their issuers can do to a board

DIME and USDC (the first market) are upgradeable proxies with a pause switch, as are many listed tokens. The board
cannot defend against its own tokens, so the rule is: **coins are never lost, but they can wait on the issuer**. The
same holds on Arbitrum, Base and HyperEVM, where most tokens are bridged: their bridge is one more issuer to trust
(DIME on HyperEVM is Paradex's own withdrawal route).

| Event | Effect | Pinned by |
|---|---|---|
| DIME paused | no fills; sell orders (escrow in DIME) cannot be cancelled until unpause; buy orders can (refund in USDC); all resumes after | `test_whileDimeIsPausedOnlyBuyOrdersCanBeCancelledAndEverythingResumesAfter` (fork, pranking the real Safe) |
| USDC paused | the mirror image: no fills; buy orders wait, sell orders can be cancelled | same mechanism |
| Maker blacklisted by Circle | fills paying them revert; they can cancel a sell order; a buy order's USDC waits on Circle | `test_aFillPayingABlacklistedMakerRevertsAndTheMakerCanStillCancel` (fork) |
| Token starts taking a cut (USDT's fee switch, or a DIME upgrade) | fills revert with `TransferShortfall` instead of shorting anyone; cancels of the other side still work | unit + fork tests |
| Token upgraded to something hostile | anything: an upgraded token can move balances itself | out of scope; only list tokens whose admin you would trust with the escrow |
| New DIME minted | price effect only; escrow untouched | - |

## The site

The contracts are small and tested; the page that asks wallets to sign is the softer target.

- **What protects it now:** a strict CSP (scripts only from the site, network only to named RPCs, Paradex and
  Lighter; a test keeps it equal to the hosts the code calls), no third-party scripts or fonts, exact approvals,
  factories pinned in `src/deployments/*.json` (a linked board opens only if its network's factory made it), HSTS,
  HTTPS-only redirects, workers.dev disabled, WHOIS redacted, DNSSEC, deploys only from `main` after tests pass.
  Cloudflare may inject its own inline bot-detection script; the CSP blocks it (harmless, visible in the console).
- **What an attacker needs:** push access to `main`, the Cloudflare account, or the domain. Each should be
  behind 2FA. Done 2026-09-26 with authenticator codes (OTP) on GitHub and Cloudflare (which is also the
  registrar); passkeys or a hardware key would also stop a phishing page from relaying the code. GitHub: protect
  `main` (no force-push) once others contribute.
- **What users should check:** the domain, and that the contract the wallet shows is a board of the factory
  `@HandshakeOTC` pins for that network (Ethereum, Arbitrum, Base, HyperEVM), as the site links it on the explorer.

## Keys

| Key | Holds | If stolen |
|---|---|---|
| Deployer: the project wallet `0x61C1…1CF8` (`mainnet-deployer` keystore, also in MetaMask) | nothing: no factory on any network has an owner (the retired mainnet one was renounced 2026-09-28; the retired Sepolia ones are test money) | nothing on chain; the tip address's funds, and the name on the project |
| Etherscan API key (`.env`) | verification, `add-market` lookups | quota abuse only |

## Accepted risks

- Offers are public on chain, including private ones (reserved, not hidden).
- A maker's cancel and a taker's fill can race; whichever is mined first wins, and the other reverts.
- Rounding: at most one atom per fill in the resting side's favour, returned to buy-order makers at the end.
- `block.timestamp` drift on expiry (Slither, accepted).
- Aderyn's "reentrancy: state after external call" (see `docs/DESIGN.md`): the only call is `decimals()`, a `view`
  read compiled to STATICCALL, so it cannot re-enter.
- No pause and no delisting: a bug cannot be stopped on chain. The site stops showing the board; makers cancel.

## Still to do

- ~~Owner on a hardware wallet~~ (no owner any more). ~~Renounce the retired mainnet factory~~ (done 2026-09-28).
- ~~2FA on GitHub and Cloudflare~~ (done, OTP).
- An independent review of `src/` (CodeHawks First Flight or similar), with this file as its starting point.
- Re-read the token section for every token added to a list: who can pause, mint, upgrade or blacklist it.
