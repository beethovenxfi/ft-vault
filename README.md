# FtLendVault — ERC-4626 wrapper over Flying Tulip Lend for Balancer v3 boosted pools

`FtLendVault` turns a Flying Tulip Lend (FT Lend) supply position into an ERC-4626 token that Balancer v3 / Beets
can use as a boosted-pool token (Vault ERC4626 buffers). Target deployment: Sonic, native USDC first; the contract is
asset-agnostic.

## Assumptions

- **No compounding.** FT rewards are harvested out to a Beets-controlled `rewardRecipient` and distributed
  off-vault (gauge). The vault never sells or re-deposits FT, so the wrapper rate starts at `1e18` and only
  moves if someone donates `asset` to the vault (e.g. `PM.depositFor(vault, …)`), which raises it.
- **Beets deploys and owns the wrapper.** `owner` = Beets multisig; its only power is `setRewardRecipient`.
  `harvest()` is permissionless. Beets handles pool creation, buffer init, Balancer review and gauge setup.
- **Unaudited FT Lend core is accepted** (user decision). The wrapper itself is unaudited; its surface is small
  (OZ v5 `ERC4626` + `Ownable2Step` + ~60 lines of FT Lend glue).
- **First asset is native USDC** `0x29219dd400f2Bf60E5a23d13Be72B486D4038894`. Name/symbol placeholders
  "Beets FT Lend USDC" / "bftUSDC". Same bytecode works for wS or any other PM-listed asset.
- **FT Lend behaviour as verified on 2026-10-13** (PM impl `0x89b6f917…dc53`). PM is upgradeable; every fact
  below can change under a 3/5 Safe with no timelock.

## Constraints and risks

| | what | consequence for the pool |
|---|---|---|
| **Oracle on every withdrawal** | PM `enforcePostHF` prices all `collateral=true` assets via Chainlink; USDC feed heartbeat 88200s, no stale fallback | stale feed ⇒ all unwraps revert `StalePrice()` until the feed updates; deposits unaffected |
| **Shared circuit breaker** | ftYieldWrapper limits outflows to 35% of TVL per 4h (+2h elastic), shared by every PM user incl. borrowers | large unwraps revert; `maxWithdraw` reports the live cap, Balancer Vault ignores it, size buffers accordingly |
| **Utilization / pauses / caps** | withdraw bounded by PM `cash` and `withdrawPaused`; deposit by `depositPaused`, `supplyCap`, asset `enabled` | temporary wrap/unwrap failures, reflected in `maxDeposit`/`maxWithdraw` |
| **Yield = FT emissions only** | suppliers earn no in-kind interest; FT credited per admin-triggered epoch (~4/day on USDC, ≈3.8% APR at snapshot) | if emissions stop the pool earns nothing; APR is discretionary |
| **Admin trust (FT Lend)** | UUPS proxy, admin = 3/5 Safe, no timelock, no published audit, closed source (explorer-verified only); admin can `setTokenizer`/`setEngine` to a contract that moves any supplier's `avail` | principal risk equal to FT Lend itself; monitor `admin()`, impl slot, tokenizer/engine events |
| **Donation** | anyone can `PM.depositFor(vault, …)` | share price only goes up; harmless to holders, mitigated by seed deposit |
| **Wrapper owner key** | can only redirect FT rewards | no path to principal |

## Why a wrapper, and why it looks like this

FT Lend supply positions are **not tokenized**. They live in `PositionsManager` (PM) as
`collateral[user][asset].avail`, one unit per unit of asset. Two verified properties of PM shape the design
(impl `0x89b6f9179671C0B471734B897E31F8760a94dc53`, source via Sourcify, chain 146):

1. **Suppliers earn no in-kind interest.** `_accrue` routes 100% of borrow interest to protocol reserves
   (`s.borrows += interestUnits; s.reserves += interestUnits;`). `avail` only changes on deposit/withdraw.
2. **Supplier yield is FT only.** The FT admin calls `settleEpoch(asset, ftAmount)`; each supplier's share is
   credited to their *FT position inside PM* (`_settleUser`). `checkpointSupply(user, asset)` is permissionless
   and PM also checkpoints on every deposit/withdraw. Only the position owner can `withdraw(FT, …)`.

A **1:1 passthrough** vault. `totalAssets()` is the PM `avail` balance, previews are exact,
the Balancer rate is `1e18` absent donations (a donation via `PM.depositFor(vault, …)` grows `avail` without
minting shares, so the rate can only rise), and FT is **not compounded**: `harvest()` (permissionless) pulls all
credited FT to `rewardRecipient`, from where Beets distributes it (e.g. via a gauge). The owner (Beets multisig)
can only change `rewardRecipient`; it has no path to principal. Immutable, no pause, no fees.

## Contracts

| file | purpose |
|---|---|
| `src/FtLendVault.sol` | the ERC-4626 wrapper (OZ v5 `ERC4626` + `Ownable2Step`) |
| `src/interfaces/IERC4626RateProviderFactory.sol` | Balancer's canonical factory (Sonic `0xc9A0E686…e487`); the deploy script calls `create(vault)` |
| `src/interfaces/IFtLend.sol` | hand-written subsets of PM / ConfigRegistry / ftYieldWrapper / LendingLens |
| `script/Deploy.s.sol` | deploy + seed (+ rate provider via factory) |

### Behaviour summary

| ERC-4626 function | implementation |
|---|---|
| `totalAssets` | `PM.getBalance(vault, asset).avail` |
| `deposit/mint` | `PM.deposit(asset, amt)`; shares 1:1 (until a donation) |
| `withdraw/redeem` | `PM.withdraw(vault, asset, amt, receiver)` (goes straight to receiver) |
| `maxDeposit/maxMint` | 0 if `depositPaused` or asset disabled; else `supplyCap - (cash + borrows)` (cap 0 = unlimited) |
| `maxWithdraw/maxRedeem` | min(owner balance, PM `cash`, ftYieldWrapper `maxAbleToWithdraw`, CircuitBreaker `withdrawalCapacity`); 0 if `withdrawPaused` |
| `harvest()` | `checkpointSupply` then `withdraw(FT)` to `rewardRecipient`; returns amount |

Donations: anyone can `PM.depositFor(vault, asset, x)`. That raises the share price (never lowers it); previews
stay consistent and later depositors never extract more than they put in (tested). First-depositor inflation is
mitigated by the seed deposit in the deploy script.

## Verified FT Lend facts that matter operationally (Sonic, 2026-10-13)

- **Withdrawals run `enforcePostHF`** → `AccountValuesRouter.accountValues` → Chainlink `OracleRouter.priceUSD`
  for every collateral asset with `AssetCfg.collateral = true` (USDC, wS; **not** FT). The USDC feed has
  `heartbeat = 88200s` and **no stale fallback**. If the feed is stale, *every* withdrawal (and therefore every
  Balancer buffer unwrap that falls through to the wrapper) reverts `StalePrice()` until the feed updates.
  Deposits keep working. Covered by `test_withdrawRevertsWhenOracleStale_documentsDependency`.
- FT is `collateral = false`, so holding FT in the vault's position between harvests does **not** add an oracle
  dependency. Covered by `test_withdrawAndHarvestWorkWhileVaultHoldsFT`.
- Withdrawals are also bounded by PM `cash` (utilization 53% at snapshot), `withdrawPaused`, and the shared
  ftYieldWrapper **circuit breaker** `0x9676E697…18e0`: for USDC `maxDrawRateWad = 35%` of TVL per 4h main
  window plus a 2h elastic window; recent inflows are credited back. Capacity at snapshot ≈ 172.7k USDC on 493k
  TVL, shared by *all* PM users (borrows consume it too). The ftYieldWrapper's `canWithdraw`/`maxAbleToWithdraw`
  do **not** include the breaker, so the vault queries `CircuitBreaker.withdrawalCapacity(asset, capital())`
  directly; `test_maxWithdrawBoundedByCircuitBreaker` proves `maxWithdraw` equals the live limit (withdraw at max
  succeeds, max+1 reverts `ftYieldWrapperRateLimitExceeded`). The Balancer Vault ignores `maxWithdraw`; an unwrap
  beyond liquidity simply reverts. Size buffers accordingly.
- Snapshot of FT rewards (one epoch each, FT = $0.153): USDC ≈ 3.8% APR, wS ≈ 2.7%, ftUSD ≈ 6.5%. Epochs
  are **discretionary** (admin-triggered, ~4/day on USDC). If emissions stop, the pool earns nothing.
- PM is a UUPS proxy. `admin()` → `PMWrapper` → 3/5 Safe `0x1118e1c0…70Cb`. **No timelock.** No published
  audit of Lend (Sherlock bounty up to 1M USDC covers it). GitHub source is not public; explorer-verified only.
- **Tokenizer.** PM has `tokenizerForAsset[asset]`: one allowlisted engine per asset that may call
  `engineTransferAvail(from, to, asset, amt)` without a per-user `engineDebitAllowance`. For USDC it is `FtToken`
  (`ftUSDC`, `0xE91DAA84Df38A30D609249C6830cDf7465800841`): a plain ERC-20 (+permit, EIP-3009) whose `balanceOf(u)`
  *is* `PM.getBalance(u, USDC).avail` and whose `transfer` moves PM `avail` (verified on-chain: balances equal,
  `totalSupply == astate.totalSupplied`; FtToken holds no PM position). It is not ERC-4626 and not upgradeable
  (no proxy slot), source unverified. The vault's position therefore also appears as its `ftUSDC` balance. The
  vault never approves, permits or signs for `ftUSDC`, so nothing can move it through FtToken as deployed. The
  residual risk is `setTokenizer` (PM admin): a new tokenizer could move any user's `avail`. Admin-trust, documented.

## Tests

```
cp .env.example .env   # or export SONIC_RPC_URL
forge build
forge test --match-path "test/FtLendVault.fork.t.sol" -vv       # 17 wrapper tests on a Sonic fork
forge test --match-path "test/BalancerCompat.fork.t.sol" -vv    # Balancer's 17-test ERC4626 buffer suite
```

`test/vendor/ERC4626WrapperBase.t.sol` is Balancer's official harness
(`balancer/balancer-v3-erc4626-tests`, GPL-3.0-or-later), vendored verbatim. `BalancerCompat.fork.t.sol` deploys
the wrapper inside the fork and sets `skipTime = 10 minutes` (the harness default of 1 day would trip the FT Lend
oracle heartbeat, which is an FT Lend property, not a wrapper one). To re-run against the live deployment, point
`s.wrapper` at the deployed address and drop the `new FtLendVault(...)`.

## Deploy

```
forge script script/Deploy.s.sol --rpc-url sonic --broadcast --verify
```
Env: see `.env.example`. `SEED_AMOUNT` is deposited by the broadcaster and the shares go to `OWNER`.

## Beets runbook (after deploy)

1. Create the StablePool with `bftUSDC` (+ partner token). Register `bftUSDC` as `WITH_RATE` using the rate
   provider created by Balancer's `ERC4626RateProviderFactory` (`0xc9A0E686C02AfFB176E06F0b344cab182250e487`,
   `create(vault)`; reads `1e18` until any donation). Factory-made providers are accepted by the Balancer review by default.
2. Initialise the buffer via BufferRouter `0x532dA919D3EB5606b5867A6f505969c57F3A721b`
   (`initializeBuffer(wrapper, underlyingIn, wrappedIn, minShares)`). Keep it well below FT Lend `cash`.
3. Request the Balancer review: `balancer/code-review` erc4626 folder + `registry.json` entry
   (`canUseBufferForSwaps: true`), attach the passing `BalancerCompat` run; add a "Flying Tulip" group in
   `balancer/metadata/erc4626/index.json`.
4. Whitelist FT as a gauge reward token. Call `harvest()` on a schedule (keeper or manual) → `rewardRecipient`
   → gauge.
5. Monitor: pending FT = `PM.getBalance(vault, FT).avail` + `LendingLens.previewFTClaimFor(vault, asset)`
   (two eth_calls; the vault deliberately has no on-chain view for this), `maxWithdraw(vault)` vs buffer size, USDC Chainlink feed freshness, `PM.admin()` and the PM
   implementation slot (upgrades), `supplyCap`/pause flags, epoch cadence (`astate(asset).epoch`).

## Addresses (Sonic)

| | |
|---|---|
| PositionsManager (proxy) | `0xbe4050a73a7Fb384c65E885a15C33461A4B20055` |
| LendingLens (proxy) | `0x3682168023E6bA8D1F995FdA1D920827C5A8A43E` |
| ConfigRegistry | `0xA8777c3D446fa7F0b0FC97a80C1Ea1d37F1ca33E` |
| OracleRouterChainlink | `0xe4372dB43D2814750a19b93950157AD81D93674A` |
| FT | `0x5DD1A7A369e8273371d2DBf9d83356057088082c` |
| USDC (native) | `0x29219dd400f2Bf60E5a23d13Be72B486D4038894` |
| USDC ftYieldWrapper | `0x7a2FD34E4Cc4C8B1023576a3f3D1f7aA36CF8b47` |
| CircuitBreaker (v1) | `0x9676E697399581AB288844cDE5F73d0887eC18e0` |
| Balancer v3 Vault | `0xbA1333333333a1BA1108E8412f11850A5C319bA9` |
| BufferRouter | `0x532dA919D3EB5606b5867A6f505969c57F3A721b` |
| ERC4626RateProviderFactory | `0xc9A0E686C02AfFB176E06F0b344cab182250e487` |
