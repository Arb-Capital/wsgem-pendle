# wstgbp-pendle

Pendle Standardized Yield ([EIP-5115](https://eips.ethereum.org/EIPS/eip-5115)) wrapper for
**wsgem** tokens — wrapped staked currencies such as wstGBP ("Wren Staked tGBP") or wstCAD —
enabling PT/YT markets on [Pendle](https://pendle.finance).

A wsgem is a non-rebasing wrapper of an underlying currency token (the "gem", e.g. tGBP)
whose gem value is an oracle-set NAV (`navprice()`, quoted in gem native units per whole
wsgem) that is poked upward over time. That is exactly the shape Pendle's SY standard
models best (cf. `PendleWstEthSY`):

- **1 SY share = 1 wsgem** — the SY holds the wsgem and mints shares 1:1.
- **`exchangeRate()` = `wsgem.navprice()`** — gem per share.
- **Asset = gem** (`assetInfo` → `(TOKEN, gem, gem.decimals())`) — PT is denominated in
  the gem. The SY is agnostic to gem decimals (they live inside the oracle price scaling).

One `PendleWsgemSY` deployment serves one wsgem instance; deploy another for each new
currency.

## Flows

```
deposit gem    ──► SY pulls gem ──► wsgem.mint()  ──► SY holds wsgem, shares = minted amount
                                    (fee = bpsin; min ~1 gem)

deposit wsgem  ──► SY pulls wsgem ────────────────► shares 1:1

redeem shares  ──► wsgem out 1:1 (only exit path)
```

The gem is intentionally **not** a `tokenOut`: `wsgem.redeem()` carries a `bpsout` fee, a
one-wsgem minimum, and a governable cooldown that can make redemption non-atomic with
partial fills. Holders unwrap wsgem → gem through the wsgem contract (or its Uniswap v4
backstop pool) directly.

## Contracts

| Contract | Path |
|---|---|
| `PendleWsgemSY` | `src/PendleWsgemSY.sol` |
| `IWsgem` (minimal interface, mirrored errors) | `src/interfaces/IWsgem.sol` |
| Deploy script | `script/DeployPendleWsgemSY.s.sol` |

Built on Pendle's immutable [`SYBaseV2`](https://github.com/pendle-finance/Pendle-SY-Public)
(pinned submodule) with OpenZeppelin 4.9.3.

### Live wsgem instances (Ethereum mainnet)

| Instance | wsgem | gem | Current params |
|---|---|---|---|
| wstGBP | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` | tGBP `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` | `bpsin` 0, `bpsout` 25, `cooldown` 0, capacity unlimited, NAV poked ~weekly |

All market parameters are governable per instance.

## Behavior notes for integrators

- **Previews match execution exactly for every market state.** `previewDeposit(gem, ·)`
  replicates `wsgem.mint()` math (ceil-adjusted `mintcost()`, floor share division) and
  reverts with the same custom-error selectors (`MarketClosed`, `InvalidPrice`,
  `DustThreshold`, `ExceedsCap`) whenever the deposit would revert. One deliberate
  exception: previews are caller-independent, so per-address compliance screening is
  *not* replicated — a deny-listed caller's deposit can revert (`NotAuthorized`) where
  the preview succeeded.
- **`previewRedeem` is balance-aware**: it quotes exactly up to the SY's held wsgem and
  reverts `SYInsolvent` past it. While solvent the balance covers every outstanding
  share, so a reverting quote exceeds total supply and corresponds to no redemption
  anyone could execute; integrators quoting hypothetical sizes should cap them at
  `totalSupply()`.
- **`exchangeRate()` reverts (`InvalidPrice`) while the NAV oracle is paused** instead of
  returning 0 — a raw 0 would flow into quoting as "SY is worthless". Pendle market
  operations freeze for exactly the window in which the wsgem's own mint/redeem is frozen.
  SY → wsgem redemption never reads the oracle and stays live throughout.
- **Gem deposit route has a dust floor** of `mintcost()` (~1 gem). Router zaps below
  that revert; the wsgem route has no minimum.
- **Compliance screening**: every wsgem transfer screens all involved addresses against
  the gem's deny list — including the SY contract itself. A banned user cannot deposit or
  receive wsgem through the SY. If the SY contract itself is ever deny-listed, wsgem
  deposits **and redemptions** through the SY freeze (`NotAuthorized`) until it is
  un-listed. SY shares themselves are plain (Pendle) ERC20 and are not gated.
- **NAV is permissioned and non-monotonic**: the oracle can be poked down or paused to 0.
  Pendle's PYIndex clamps at its historical max, so a NAV drawdown parks YT accounting at
  the prior peak until the NAV recovers. NAV moves are also discrete steps:
  `exchangeRate()` jumps at each poke, so PT/YT market repricing around a poke is
  sandwichable in principle — inherent to any discretely-updated NAV oracle, and worth
  weighing in market parameters.
- **Gem decimals only quantize, never break, the math.** navprice/mintcost are quoted in
  gem native units per whole wsgem, so the share math is decimals-agnostic (tested at 2,
  6, 8, and 18); low-decimal gems simply round values to their coarser smallest unit
  (at most one gem unit of rounding per operation).
- **Privileged smelt is an explicit trust assumption.** wsgem issuers can forcibly burn
  wsgem from any holder (`smelt(address,uint256)`) — including the SY, which would leave
  shares outstanding with less than 1 wsgem of backing each. The SY surfaces this via
  `deficit()` (shares beyond backing; wire it into monitoring/alerting) and **fails
  closed on deposits** (`SYInsolvent`, preview-parity included) while a deficit persists.
  Redemptions stay live but first-come, and `previewRedeem` is balance-aware: it quotes
  exactly up to the held wsgem and reverts `SYInsolvent` on the unbacked tail instead of
  overquoting. The SY owner can `pause()` to intervene.
- **SY owner** holds exactly two privileges: `pause()` (freezes SY share
  mint/burn/transfer) and `sweep(token, receiver)` (recovers stray ETH or tokens sent
  to the SY directly — the wsgem itself can never be swept, so backing and any donated
  surplus stay untouchable by the owner). Ownership is two-step transferable and should
  live with an ops multisig. No other privileged surface.

## Development

```shell
forge build
forge test                              # unit + fuzz + invariant (fork suites skip offline)
forge test --match-contract ForkTest    # deterministic fork suite (pinned block)
forge test --match-contract SmokeTest   # latest-block live-parameter smoke checks
```

Fork suites run only when an explicit RPC is configured (`ETH_RPC_URL`, or
`ALCHEMY_API_KEY` to compose one) and **skip otherwise**, so plain offline `forge test`
stays green. The fork suite pins a block for determinism (override with `FORK_BLOCK`;
historical state needs an archive-capable RPC — any Alchemy/Infura endpoint qualifies).
The smoke suite intentionally forks latest: it asserts current governable parameters
(fees, cooldown, open market, compliance), so a failure there means live config moved,
not a code regression.

### Deploy

```shell
forge script script/DeployPendleWsgemSY.s.sol --rpc-url mainnet -vvv               # dry run
forge script script/DeployPendleWsgemSY.s.sol --rpc-url mainnet --broadcast --verify -vvv
```

Defaults deploy for wstGBP. For another instance, `WSGEM`, `SY_NAME`, `SY_SYMBOL`, and
`EXPECTED_GEM` must **all** be set explicitly — the script refuses to fall back to the
wstGBP branding or skip the gem cross-check for an unfamiliar wsgem address. Set
`SY_OWNER` to begin a **two-step** ownership transfer: the script leaves the transfer
pending, and the new owner must call `claimOwnership()` from its own address to
complete it (a mistyped-but-valid address therefore cannot strand pause rights).

The script asserts the full post-deploy state (metadata, previews, token lists,
compliance pass, `deficit() == 0`) before reporting the address; the gem-route preview
check needs the wsgem mint window open and is skipped with a warning otherwise. Re-run
the same battery against the mined instance — or any time later as a health check —
with the command below. It reads the same `WSGEM` / `EXPECTED_GEM` / `SY_OWNER` env
vars (and wstGBP defaults) rather than trusting the SY under check, and additionally
requires the SY unpaused and the pending-owner slot empty — the only tolerated pending
state is a transfer parked toward a declared `SY_OWNER` that has not yet claimed:

```shell
forge script script/DeployPendleWsgemSY.s.sol --sig "check(address)" <SY_ADDR> --rpc-url mainnet -vvv
```

### Dependencies (pinned submodules)

| Lib | Rev |
|---|---|
| `Pendle-SY-Public` | `73676d9` |
| `openzeppelin-contracts` / `-upgradeable` | `v4.9.3` |
| `maseer-one` (wsgem framework source, **test-only**, BUSL-1.1) | `07eb992` |
| `forge-std` | forge-managed |

## License

[GPL-3.0-or-later](LICENSE). The `maseer-one` submodule is BUSL-1.1 and is a test-only
dependency; nothing in `src/` links against it.
