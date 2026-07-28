# wstgbp-pendle

Pendle Standardized Yield ([EIP-5115](https://eips.ethereum.org/EIPS/eip-5115)) wrapper for
**wsgem** tokens — wrapped staked currencies such as wstGBP ("Wren Staked tGBP") or wstCAD —
enabling PT/YT markets on [Pendle](https://pendle.finance).

A wsgem is a non-rebasing wrapper of an underlying currency token (the "gem", e.g. tGBP)
whose gem value is an oracle-set NAV (`navprice()`, quoted in gem native units per whole
wsgem) that accrues upward over time under normal operation. That shape is well
suited to Pendle's SY standard (cf. `PendleWstEthSY`):

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
| Deploy script (wstGBP, fully pinned) | `script/DeployPendleWstGbpSY.s.sol` |
| Deploy script (generic pattern, env-driven) | `script/DeployPendleWsgemSY.s.sol` |

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
- **Token compatibility assumptions**: wsgem must follow the Maseer wsgem interface,
  use 18 decimals, and transfer exact requested amounts. The gem may use any decimals,
  but it must also transfer exact requested amounts. Fee-on-transfer and rebasing token
  implementations are unsupported; otherwise the base contract's requested deposit
  amount can differ from the amount actually received or passed to `wsgem.mint()`.
- **Privileged smelt is an explicit trust assumption.** wsgem issuers can forcibly burn
  wsgem from any holder (`smelt(address,uint256)`) — including the SY, which would leave
  shares outstanding with less than 1 wsgem of backing each. The SY surfaces this via
  `deficit()` (shares beyond backing; wire it into monitoring/alerting) and **fails
  closed on deposits** (`SYInsolvent`, preview-parity included) while a deficit persists.
  Redemptions stay live but first-come, and `previewRedeem` is balance-aware: it quotes
  exactly up to the held wsgem and reverts `SYInsolvent` on the unbacked tail instead of
  overquoting. The SY owner can `pause()` to intervene.
- **SY administration** has two operational powers: `pause()` / `unpause()` controls SY
  share minting, burning, and transfers, while `sweep(token, receiver)` recovers stray ETH
  or tokens sent to the SY directly. The wsgem itself can never be swept, so backing and
  any donated surplus stay untouchable by the owner. The owner can also transfer or
  renounce ownership through the inherited ownership interface; production ownership
  should live with an ops multisig. There is no other privileged operational surface.

## Development

```shell
make test        # offline dev loop: unit + fuzz + invariant + deploy-script + decimals suites
make test-fork   # deterministic fork suite (pinned block; archive-capable RPC)
make test-smoke  # latest-block live-parameter smoke checks
make test-all    # everything the configured RPC allows
make coverage    # summary coverage of the src/ surface
make gen-report  # HTML coverage report -> docs/coverage-report/ (view via make serve-report)
```

Copy `.env.example` to `.env` for configuration. RPC precedence everywhere (make targets
and direct `forge test` alike): explicit `ETH_RPC_URL`, else an endpoint composed from
`ALCHEMY_API_KEY`, else — for the deploy/check targets only — a public fallback.
`make test` and `make coverage` strip the RPC vars so the dev loop stays deterministic
even with an RPC configured.

Fork suites run only when an explicit RPC is configured (`ETH_RPC_URL`, or
`ALCHEMY_API_KEY` to compose one) and **skip otherwise**, so plain offline `forge test`
stays green. The fork suite pins a block for determinism (override with `FORK_BLOCK`;
historical state needs an archive-capable RPC — any Alchemy/Infura endpoint qualifies).
The smoke suite intentionally forks latest: it asserts current governable parameters
(fees, cooldown, open market, compliance), so a failure there means live config moved,
not a code regression.

### Deploy

```shell
make deploy-dry       # keyless simulation against live mainnet state — run first
make deploy           # keystore-signed broadcast + inline Etherscan verify
make check SY=0x...   # re-run the sanity battery against the mined instance (keyless)
make verify           # resume-verify a broadcast whose inline verification hiccuped
```

`make deploy` signs from an encrypted keystore (`ETH_FROM` + `ETH_KEYSTORE`; forge
prompts for the password — no raw private key anywhere) and needs `ETHERSCAN_API_KEY`
for verification.

There are two deploy scripts, one behaviour:

- **`script/DeployPendleWstGbpSY.s.sol`** — the wstGBP deployment, with the wsgem
  address, the gem to cross-check, the SY name/symbol, and the ops multisig
  (`0xa73c94969dE90Edb159D29922C42fF24beDFA085`) all pinned in code. Needs no
  configuration; it is what the `make` targets above drive. A `WSGEM`, `EXPECTED_GEM`,
  `SY_NAME`, or `SY_SYMBOL` left exported for a different instance is **refused**, not
  silently ignored.
- **`script/DeployPendleWsgemSY.s.sol`** — the generic pattern for any other wsgem, and
  the deploy/check machinery both share. It defaults **nothing**: `WSGEM`, `SY_NAME`,
  `SY_SYMBOL`, and `EXPECTED_GEM` must all be set, because a wrong name, symbol, or
  unchecked underlying is permanent on an immutable contract. Drive it with
  `make deploy-dry SCRIPT=script/DeployPendleWsgemSY.s.sol` (same for `deploy` / `check`
  / `verify`). For a recurring instance, subclass it as the wstGBP script does —
  override `target()` and `naming()` and everything else comes along.

Ownership moves in **two steps**: the script parks the transfer and the new owner must
call `claimOwnership()` from its own address to complete it, so a mistyped-but-valid
address cannot strand pause rights. The wstGBP script targets its pinned ops multisig —
**the multisig must claim before it holds anything**, and until then the deployer is still
owner. The generic script transfers only if `SY_OWNER` is set, and `SY_OWNER` also
overrides the pinned value for one run. To skip the transfer, spell the zero address in
full — `SY_OWNER=0x0000000000000000000000000000000000000000`; a malformed or truncated
value aborts the script rather than falling back to the pinned owner.

The script asserts the full post-deploy state (metadata, previews, token lists,
compliance pass, `deficit() == 0`) before reporting the address; the gem-route preview
check needs the wsgem mint window open and is skipped with a warning otherwise. Re-run
the same battery against the mined instance — or any time later as a health check —
with the command below. It takes the expected wsgem, gem, and owner from the script's own
pinned or env-supplied configuration rather than trusting the SY under check (otherwise
any healthy SY would pass, including one bound to the wrong wsgem), and additionally
requires the SY unpaused and the pending-owner slot empty — the only tolerated pending
state is a transfer parked toward a declared `SY_OWNER` that has not yet claimed:

```shell
forge script script/DeployPendleWstGbpSY.s.sol --sig "check(address)" <SY_ADDR> --rpc-url mainnet -vvv
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
