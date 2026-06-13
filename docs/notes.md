# AquaLab — Protocol Notes (ground truth for Agents 2 & 3)

Discoveries from reading the real `swap-vm` / `aqua` Solidity sources and from a
passing mainnet-fork ship+swap test. **These supersede prose docs.** File
references below are to the vendored sources under `lib/swap-vm/` and
`lib/aqua/`.

---

## 0. TL;DR for the next agents

- We target the **direct-SwapVM / Aqua-backed** path (scores higher in judging),
  NOT the plain `AquaApp` example in `lib/aqua/examples/apps/XYCSwap.sol`.
- A strategy = an `ISwapVM.Order` whose `data` carries a **program** (a byte
  stream of `[opcode][len][args]` instruction frames). The taker calls
  `router.swap(order, tokenIn, tokenOut, amount, takerTraitsAndData)`.
- Build programs with `src/XYCStrategyBuilder.sol`. Agent 2 extends it by
  overriding `_swapProgram()` / composing more instruction frames. The opcode
  table and frame layout are documented below so you can compose freely.
- Trace exporter (Agent 3): the per-step VM state lives in `Context.swap`
  (`balanceIn/balanceOut/amountIn/amountOut/amountNetPulled`). The instruction
  pipeline is the program byte stream decoded against the opcode table in §4.
  Use the `AquaSwapVMRouterDebug` / `AquaOpcodesDebug` console-log opcodes
  (indices 0..4) to dump registers between steps — see §7.

---

## 1. Addresses / environment

| Thing | Value |
|---|---|
| Live Aqua (multi-chain, same addr) | `0x499943E74FB0cE105688beeE8Ef2ABec5D936d31` (checksummed; lowercase literal fails solc checksum) |
| WETH (mainnet) | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| USDC (mainnet) | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Pinned fork block | `25_300_000` (head was ~25,306,200) |
| RPC | env `MAINNET_RPC_URL` (foundry auto-loads `.env`); `rpc_endpoints.mainnet` in `foundry.toml` |

`AquaSwapVMRouter` is **NOT** deployed at a known mainnet address — we deploy a
fresh one in-test pointing at the live Aqua + real WETH. The router constructor:
`new AquaSwapVMRouter(aqua, weth, owner, name, version)` where `owner` is only a
fund-rescue admin and `name/version` are the EIP-712 domain (we use
`"SwapVM","1.0.0"` to match upstream tests).

## 2. Toolchain / build

- solc **0.8.30**, `via_ir = true`, optimizer on. via_ir is REQUIRED — the
  ProgramBuilder compares internal function pointers (emits a benign warning;
  works under via_ir).
- Deps: `@1inch/solidity-utils@6.9.7`, `@openzeppelin/contracts@5.4.0`,
  `forge-std@v1.11.0`, installed via **npm** into `node_modules/` (npm registry
  + raw github.com both reachable; `api.github.com` is blocked so `foundryup` /
  `forge install`-via-API do NOT work).
- `swap-vm` + `aqua` SOURCES are **vendored** into `lib/` (tracked in git via a
  `.gitignore` exception) because they can't be re-fetched through the blocked
  API. Their own `foundry.toml`/`remappings.txt` were deleted so the root config
  governs resolution. Remappings (root `remappings.txt`):
  ```
  @1inch/swap-vm/=lib/swap-vm/
  @1inch/aqua/=lib/aqua/
  @1inch/solidity-utils/=node_modules/@1inch/solidity-utils/
  @openzeppelin/contracts/=node_modules/@openzeppelin/contracts/
  forge-std/=node_modules/forge-std/src/
  ```

## 3. Aqua API (real signatures, from `lib/aqua/src/interfaces/IAqua.sol`)

```solidity
function ship(address app, bytes calldata strategy, address[] calldata tokens, uint256[] calldata amounts) external returns (bytes32 strategyHash);
function dock(address app, bytes32 strategyHash, address[] calldata tokens) external;
function safeBalances(address maker, address app, bytes32 strategyHash, address token0, address token1) external view returns (uint256 balance0, uint256 balance1);
function rawBalances(address maker, address app, bytes32 strategyHash, address token) external view returns (uint248 balance, uint8 tokensCount);
function pull(address maker, bytes32 strategyHash, address token, uint256 amount, address to) external;   // app-only
function push(address maker, address app, bytes32 strategyHash, address token, uint256 amount) external;
```

Critical facts:
- **`app` = the router address** (`address(router)`), and the **shipped
  `strategyHash` returned by `ship` MUST equal `router.hash(order)`.** This is
  the binding that lets `SwapVM.swap` find reserves via
  `AQUA.safeBalances(maker, address(this), orderHash, tokenIn, tokenOut)`. If the
  program (hence order hash) and the shipped strategy disagree, the swap can't
  locate the pool. (Upstream test even does `vm.assume(strategyHash==orderHash)`.)
- **Aqua is NON-CUSTODIAL.** Balances are on-demand *allowances* against the
  **maker's own wallet** (the maker must `approve(aqua, ...)`), not escrow. On a
  swap, tokenIn is pushed INTO the maker's wallet and tokenOut is pulled FROM the
  maker's wallet. So assert maker *raw-wallet* deltas, not an Aqua escrow balance.
- `safeBalances` REVERTS for a token not in an active strategy (e.g. after
  `dock`). `rawBalances` does not revert (returns 0). Aqua amounts are `uint248`.
- Strategies are immutable + unique by hash: re-shipping the same hash reverts
  (`StrategiesMustBeImmutable`). Vary `Controls._salt` to ship "the same" pool
  twice. `dock` must close ALL the strategy's tokens or it reverts.

## 4. SwapVM order, program encoding, opcode table

### Order (`lib/swap-vm/src/interfaces/ISwapVM.sol`)
```solidity
struct Order { address maker; MakerTraits traits; bytes data; }
```
Built via `MakerTraitsLib.build(Args)` (`lib/swap-vm/src/libs/MakerTraits.sol`).
The `program` bytes go into `Args.program`; hooks/receiver/flags are packed into
`traits` + `data`. For Aqua mode set `useAquaInsteadOfSignature: true`. With that
flag SwapVM requires `receiver == maker` and forbids `shouldUnwrapWeth`
(reverts `MakerTraitsCustomReceiverIsIncompatibleWithAqua` /
`...UnwrapIsIncompatibleWithAqua`). We pass `receiver: address(0)` which resolves
to the maker.

### Program byte layout (`ProgramBuilder`, vendored to `src/vendor/ProgramBuilder.sol`)
Each instruction is one frame: `abi.encodePacked(uint8 opcode, uint8 argsLength, args)`.
`opcode` = the instruction function-pointer's **index** in the router's
`_opcodes()` table. Concatenate frames with `bytes.concat(...)`.
`ProgramBuilder.init(_opcodes())` + `p.build(Instruction._fn[, argsBytes])`.

To build programs a contract must expose `_opcodes()` — inherit
`AquaOpcodesDebug` (what `src/XYCStrategyBuilder.sol` does). The debug variant
only fills reserved no-op slots 0..4, so program bytes are **identical** to what
the production `AquaSwapVMRouter` (plain `AquaOpcodes`) executes.

### Aqua opcode table — indices (from `lib/swap-vm/src/opcodes/AquaOpcodes.sol`)
This is the table the `AquaSwapVMRouter` runs. Indices are STABLE (append-only).
```
0..4   debug no-ops (console logs in AquaOpcodesDebug; plain no-ops in prod)
5..10  reserved no-ops
11 Controls._jump
12 Controls._jumpIfTokenIn
13 Controls._jumpIfTokenOut
14 Controls._deadline
15 Controls._onlyTakerTokenBalanceNonZero
16 Controls._onlyTakerTokenBalanceGte
17 Controls._onlyTakerTokenSupplyShareGte
18 XYCSwap._xycSwapXD                         <-- our AMM primitive
19 XYCConcentrate._xycConcentrateGrowLiquidity2D   <-- agent 2 (concentrated)
20 Decay._decayXD                             <-- agent 2 (MEV decay)
21 Controls._salt
22 Fee._flatFeeAmountInXD                      <-- agent 2 (flat fee)
23..27 reserved no-ops
28 Fee._protocolFeeAmountInXD
29 Fee._aquaProtocolFeeAmountInXD
30 Fee._dynamicProtocolFeeAmountInXD
31 Fee._aquaDynamicProtocolFeeAmountInXD
32 PeggedSwap._peggedSwapGrowPriceRange2D
33 Extruction._extruction
```
> NOTE: indices are resolved at runtime by `ProgramBuilder.findOpcode`, so you
> never hardcode them — just reference the function (`XYCSwap._xycSwapXD`). The
> table above is for the trace exporter to *decode* program bytes back to names.
> CAUTION: the `_progressiveFeeInXD` / `_decayXD` combo from CLAUDE.md — note
> `AquaOpcodes` does NOT expose `_progressiveFeeInXD` (that lives in
> `FeeExperimental`, only in the generic `Opcodes` table, index differs). For
> Aqua-backed strategies use `Fee._flatFeeAmountInXD` (22) /
> `Fee._aquaProtocolFeeAmountInXD` (29) and `Decay._decayXD` (20). If agent 2
> needs progressive fees it must either use a non-Aqua router or confirm the
> instruction is reachable in `AquaOpcodes`. **Flagged for the orchestrator.**

### The XYCSwap primitive (`lib/swap-vm/src/instructions/XYCSwap.sol`)
`_xycSwapXD` reads `ctx.swap.balanceIn/balanceOut` (seeded from Aqua) and:
- exact-in:  `amountOut = amountIn*balanceOut / (balanceIn+amountIn)` (floor)
- exact-out: `amountIn  = ceil(amountOut*balanceIn / (balanceOut-amountOut))`
Reverts if either balance is 0 (`XYCSwapRequiresBothBalancesNonZero`) or if a
register is recomputed (`XYCSwapRecomputeDetected`). No fee in the bare
primitive — fees are separate instructions composed around it.

## 5. Taker side (`lib/swap-vm/src/libs/TakerTraits.sol`)

`router.swap(order, tokenIn, tokenOut, amount, takerTraitsAndData)`. Build
`takerTraitsAndData` with `TakerTraitsLib.build(Args)`. `amount` is amountIn if
`isExactIn` else amountOut. Key Args we use (see `test/XYCSwapAquaFork.t.sol`):
- `isExactIn`: direction of the exact constraint.
- `useTransferFromAndAquaPush: true`: simplest mode — router does
  `transferFrom(taker, router)` then `AQUA.push` to the maker. Taker only needs
  to hold tokenIn and `approve(router)`. **No taker callback contract required.**
  (Alternative: `hasPreTransferInCallback: true` + implement `ITakerCallbacks`
  and push yourself — see `lib/swap-vm/test/mocks/MockTaker.sol`.)
- `to`: output recipient (we set it to the taker). `address(0)` -> `msg.sender`.
- `threshold`: min-out / max-in slippage guard; empty = none.
- `isFirstTransferFromTaker`: ordering of in/out transfers.

`router.quote(...)` is the static-call preview (same args), returns
`(amountIn, amountOut, orderHash)`.

## 6. SwapVM.swap execution order (`lib/swap-vm/src/SwapVM.sol`)
1. `orderHash = hash(order)`; reentrancy lock.
2. parse taker traits; seed `ctx.swap.amountIn/Out` from `amount`.
3. if Aqua: `(balanceIn,balanceOut) = AQUA.safeBalances(maker, router, orderHash, tokenIn, tokenOut)`; else verify maker signature.
4. `ctx.runLoop()` — executes the program; instructions mutate `ctx.swap`.
5. `order.traits.validate(...)` + `takerTraits.validate(...)` (slippage/deadline).
6. transferIn/transferOut (order depends on `isFirstTransferFromTaker`); emits
   `Swapped(orderHash, maker, taker, tokenIn, tokenOut, amountIn, amountOut)`.

## 7. For the trace exporter (Agent 3)
- The visible economic state per instruction is `Context.swap` (a
  `SwapRegisters`: `balanceIn, balanceOut, amountIn, amountOut, amountNetPulled`)
  and `Context.query` (`SwapQuery`: orderHash, maker, taker, tokenIn, tokenOut,
  isExactIn). Defs in `lib/swap-vm/src/libs/VM.sol`.
- Easiest structured trace: deploy `AquaSwapVMRouterDebug`
  (`lib/swap-vm/src/routers/AquaSwapVMRouterDebug.sol`) and insert the debug
  opcodes (`Debug._printSwapRegisters` = idx 0, `_printContext` = idx 2, etc.)
  between real instructions; they `console.log` register state at each step.
  Capture via `forge test -vvv` or `vm.recordLogs`. The `Swapped` event gives
  the final deltas. Decode the program bytes against the §4 table for the
  instruction-pipeline view.

## 8. Open questions / deviations for the orchestrator
- `_progressiveFeeInXD` is NOT in the `AquaOpcodes` table (only the generic
  `Opcodes`). Agent 2's planned fee layer should use `Fee._flatFeeAmountInXD` or
  `Fee._aquaProtocolFeeAmountInXD`, or we switch routers. See §4 CAUTION.
- We deploy our own `AquaSwapVMRouter` per test run (no canonical mainnet router
  address surfaced in the sources). If a canonical router address exists on the
  fork, swapping to it is a one-line change in `setUp`.
- `Controls._salt` value: we expose `buildOrder(maker, salt)` taking a `uint64`
  salt so callers vary pools deterministically.
```

---

## 9. Agent 2 discoveries — composed strategy (fee + decay + AMM)

### 9.1 Fee & Decay are WRAPPER instructions (recursion via `ctx.runLoop()`)

`Fee._flatFeeAmountInXD` and `Decay._decayXD` are **not** flat leaf steps. Each
one mutates the swap registers and then calls `ctx.runLoop()`, which executes the
rest of the program **from the current `nextPC` to the end** (`VM.sol` runLoop).
When that inner loop returns, the wrapper post-processes, and the outer loop —
already at program end — stops. Net effect: a wrapper runs everything after its
own frame **exactly once**, nested. So the program byte order *is* the nesting:

```
[salt][decay][fee][swap]   ==>   salt;  Decay( Fee( Swap ) )
```

The AMM primitives (`_xycSwapXD`, `_xycConcentrateGrowLiquidity2D`) are **leaves**
— they set the missing amount and return without recursing.

**Ordering is forced, not stylistic.** Both Fee and Decay `require(amountIn == 0
|| amountOut == 0)` — they must run before the swap has priced. The swap must be
LAST/innermost; putting it earlier reverts
(`FeeShouldBeAppliedBeforeSwapAmountsComputation` /
`DecayShouldBeCalledBeforeSwapAmountsComputation`). Outermost→innermost we chose
**Decay → Fee → Swap**: decay shapes the virtual reserves + records the realized
offset; fee shrinks the curve's input; the curve prices last. `salt` is a pure
no-op placed first (it doesn't recurse).

### 9.2 Real opcode names + arg encodings used (all in `AquaOpcodes`)

| Instruction | ArgsBuilder call | Arg bytes |
|---|---|---|
| `Controls._salt` | `ControlsArgsBuilder.buildSalt(uint64)` | 8 |
| `Decay._decayXD` | `DecayArgsBuilder.build(uint16 period)` | 2 |
| `Fee._flatFeeAmountInXD` | `FeeArgsBuilder.buildFlatFee(uint32 feeBps)` | 4 (1e9 = 100%) |
| `XYCSwap._xycSwapXD` | — | 0 |
| `XYCConcentrate._xycConcentrateGrowLiquidity2D` | `XYCConcentrateArgsBuilder.build2D(uint256 sqrtPmin, uint256 sqrtPmax)` | 64 |

### 9.3 AMM primitive used: CONCENTRATED (primary, no fallback needed)

`_xycConcentrateGrowLiquidity2D` ships + swaps fine through live Aqua. Gotcha:
the sqrt-price band `P = tokenGt/tokenLt` is in **RAW token units**, so for
WETH(18dp)/USDC(6dp) the implied `√P·1e18 ≈ 1.8e22`, NOT ~1e16. If the band's
implied spot is inconsistent with the seeded reserves, the curve computes an
`amountOut` larger than the maker can pay and the **revert surfaces inside
`AQUA.pull`** (underflow), not in the curve math — confusing to debug. Derive the
band from the seed reserves: `√P_spot = sqrt(balanceGt·1e36/balanceLt)`, then
e.g. ±5%. `XYCConcentrateArgsBuilder.computeLiquidityAndPrice(bLt,bGt,√min,√max)`
is the public helper to check the implied spot lands in-band.

### 9.4 "Progressive fee" — NOT an opcode (confirmed §4/§8 caution)

No single Aqua opcode does size-progressive fees and there's no amount-based
`Controls` jump. We realize it as (a) `progressiveFeeBps()` size→bps tiering for
per-strategy fee ladders, and (b) `_decayXD` (effective cost grows with
size/frequency). Documented in `ComposedStrategyBuilder` NatSpec + README.

### 9.5 For Agent 3 (trace exporter) — the composed instruction sequence

A composed program decodes (against the §4 table) to this frame sequence:

```
salt(8B) | decay(2B) | flatFee(4B) | [xycSwap(0B) | OR | concentrate(64B)]
```

The **execution** is nested, so a flat PC-ordered step list is NOT the economic
nesting. For the visualizer, the meaningful per-step deltas are: after `decay`,
`ctx.swap.balanceIn/balanceOut` are the *virtual* (offset-adjusted) reserves;
after `fee`, `ctx.swap.amountIn` is the *net* input the curve sees (the
taker-defined input is restored after the inner runLoop returns); the AMM leaf
sets `amountOut` (exact-in). `decayPeriod==0` and `feeBps==0` omit those frames
entirely, so the trace exporter must decode whatever frames are actually present
rather than assume all four. The builder is
`src/ComposedStrategyBuilder.sol::buildComposedProgram(PoolParams)`.

---

## 10. Agent 3 — Trace exporter implementation

### 10.1 Trace generation mechanism

Two real traces are exported by `test/TraceExporter.t.sol::test_ExportTraces`:

- **Small swap**: 1 WETH → USDC on a constant-product (`_xycSwapXD`) pool with fee+decay.
- **Large swap**: 5 WETH → USDC on a concentrated-liquidity (`_xycConcentrateGrowLiquidity2D`) pool with fee+decay.

Both are FIRST swaps on fresh pools. The traces faithfully show:
- Both `_decayXD` steps with `elapsedSeconds=0` and `currentOffsetIn/Out=0` (honest: no prior state).
- `_flatFeeAmountInXD` with a higher ABSOLUTE fee on the large swap (0.015 WETH vs 0.003 WETH).
- The AMM leaf computes the same formula but the large swap shows concentrated-liquidity amplification.

The final step's `params.amountOut` is asserted to equal the real on-chain measured `swapAmountOut` via `assertEq` in the test, ensuring the trace cannot drift from reality.

### 10.2 Decay offsets — why both first-swap traces show offset=0

`Decay._decayXD` stores offsets per `(orderHash, token, buyOrSell)` direction. For a WETH→USDC swap:
- **Reads** (for virtual reserve adjustment): `_offsets[hash][WETH][true]` and `_offsets[hash][USDC][false]`
- **Writes** (after inner loop): `_offsets[hash][WETH][false]` and `_offsets[hash][USDC][true]`

This is Mooniswap-style MEV protection: the written offsets only activate for the **reverse** direction (USDC→WETH). A second WETH→USDC same-direction swap does NOT see the offsets from the first (it reads different keys). Decay therefore primarily protects against sandwich attacks and reverse-direction follow-up trades.

### 10.3 Regen command (one command to regenerate ALL THREE traces from scratch)

```bash
export PATH="$HOME/.foundry/bin:$PATH"
set -a; source .env; set +a
forge test --match-contract TraceExporter && node viz/scripts/copy-traces.mjs && cd viz && npm run validate
```

This runs the fork tests (`test_ExportTraces` + `test_ExportTwoSwapDecay`), copies `./traces/*.json` to
`viz/fixtures/*.fixture.json`, and validates all three fixtures against `trace.schema.json`.

### 10.5 Third trace: two-swap decay demo (Agent 3b)

**Why same-direction swaps don't see each other's offsets.** `Decay._decayXD` keys offsets on
`(orderHash, token, swapDirection)` where `swapDirection` is the `bool buyOrSell` flag. For WETH→USDC:

- **Writes**: `_offsets[hash][WETH][false]`, `_offsets[hash][USDC][true]`
- **Reads** of the NEXT WETH→USDC swap: `_offsets[hash][WETH][true]`, `_offsets[hash][USDC][false]`

The read/write keys are COMPLEMENTARY (`true` vs `false`). A same-direction follow-up swap reads the
OPPOSITE direction's offsets — which are zero on a fresh pool. So two consecutive WETH→USDC trades on the
same pool show offset=0 for the second one just as for the first. This is by design: the decay offset
creates a "virtual depth" that punishes REVERSE direction trades (e.g. sandwich bots), not same-direction
traders.

**How to get a non-zero offset on the traced swap.** The approach is:
1. Execute a FIRST swap (WETH→USDC). This writes `_offsets[hash][WETH][false]` and `_offsets[hash][USDC][true]`.
2. Advance time by `T < decayPeriod` via `vm.warp(block.timestamp + T)`.
3. Execute the SECOND (traced) swap in the REVERSE direction (USDC→WETH). This reads exactly the offsets
   written in step 1:
   - `_offsets[hash][USDC][true]` → `offsetIn` (added to virtual USDC balance)
   - `_offsets[hash][WETH][false]` → `offsetOut` (subtracted from virtual WETH balance)
4. The decay factor is `(decayPeriod - T) / decayPeriod`, which is strictly between 0 and 1.

**Concrete values in `trace-two-swap-decay.fixture.json` (pool salt=903):**

| Field | Value |
|---|---|
| First swap | 5 WETH → 14,244,892,127 USDC (salt=903 pool) |
| Pool reserves after swap1 | 105 WETH, 285,755 USDC |
| Time advance (`vm.warp`) | +1200 seconds |
| `decayPeriod` | 3600 seconds |
| `elapsedSeconds` | 1200 |
| `decayFactor` | 2400/3600 = 0.6666... ≈ 66.66% |
| `currentOffsetIn` (USDC) | 9,496,594,751 (~9,497 USDC = out1 × 2/3) |
| `currentOffsetOut` (WETH) | 3,333,333,333,333,333,333 (~3.33 WETH = 5e18 × 2/3) |
| Second swap (traced) | 5,000 USDC → 1,688,029,241,275,115,947 WETH (~1.688 WETH) |
| `tracedOut == realOut` | `assertEq` passes (both = 1688029241275115947) |

The virtual reserves seen by the second swap's AMM (after decay adjustment):
- Virtual USDC (tokenIn) = 285,755 + 9,497 = **295,252 USDC** (deeper → cheaper WETH)
- Virtual WETH (tokenOut) = 105 − 3.33 = **101.67 WETH** (shallower → more expensive WETH)

Net effect: the MEV protection makes WETH appear MORE expensive to the second buyer by reducing effective
virtual WETH supply. The spot price shifts from ~2721 to ~2904 USDC/WETH in the virtual view.

### 10.4 Opcode name changes (schema + types + stepPanel)

Reconciled from the real `AquaOpcodes` table (§4 of these notes):

| Old aspirational name (placeholder) | Real opcode name | AquaOpcodes index |
|---|---|---|
| `BALANCE_SETUP` | `_salt` | 21 |
| `_progressiveFeeInXD` | `_flatFeeAmountInXD` | 22 |
| `_xycConcentrateGrowLiquidityXD` | `_xycConcentrateGrowLiquidity2D` | 19 |
| (new) | `_xycSwapXD` | 18 |
| `_decayXD` | `_decayXD` | 20 (unchanged) |

Files updated: `viz/fixtures/trace.schema.json`, `viz/src/types.ts`, `viz/src/stepPanel.ts`.
The `BALANCE_SETUP` framing step was replaced with the real `_salt` instruction (no synthetic step needed).
`opcodeClass()` substring matching in stepPanel.ts still correctly routes all real opcode names to their CSS classes.

---

## 11. Correction pass (contracts) — RESOLVED via "hybrid + on-chain proof"

A correction pass shipped four fix groups (canonical-router linkage, quote==swap
round-trip, CoreInvariants inheritance, trace `registers`/`quoteEqualsSwap`). An
earlier pass flagged a hard discrepancy on the canonical router (§11.1/§11.2 below,
kept as ground truth); the orchestrator + user chose the **hybrid** resolution
(§11.3). The diagnostic facts are retained because they are still true and explain
*why* the hybrid is the honest choice.

### 11.1 The canonical deployed router is NOT byte-identical to vendored swap-vm 0.0.6

The orchestrator's premise was: the canonical SwapVM router deployed at
`0x8fDD04Dbf6111437B44bbca99C28882434e0958f` runs the production `AquaOpcodes`
table, *byte-identical* to the `AquaOpcodesDebug` table our builders encode against,
so the same program bytes execute unchanged. **This is false against the deployed
bytecode at fork block 25,300,000.** Measured facts:

- `AQUA()` on the deployed router = `0x499943…D936d31` ✓ (the same Aqua we ship into).
- Deployed router runtime code size = **22,640 bytes**.
- Our vendored `AquaSwapVMRouter` (swap-vm 0.0.6) compiles to **18,142 bytes**.
  → 4,498-byte difference; different bytecode, hence a different opcode table.
- The fresh-deploy router (vendored) executes our programs fine (the 13-test baseline
  passes). The deployed router *rejects the identical program bytes*:
  - Happy-path `[xycSwap][salt]` (bytes `0x110014080000000000000001`) →
    `panic 0x11 (arithmetic underflow)` inside the instruction at byte 17.
  - USDC→WETH same program → `DecayShouldBeCalledBeforeSwapAmountsComputation(10, 3e9)`.
  - Composed program's curve byte → custom error `0xec286c06`.

### 11.2 Probed opcode map of the DEPLOYED router (via per-byte ship+swap revert selectors)

Shipping a single-frame program at each opcode byte and reading the revert selector
maps the deployed router's table — and proves it is a **newer, shifted** version:

| byte | deployed revert selector | instruction family (decoded) |
|---|---|---|
| 14–16 | `ControlsMissingTokenArg` (`0x6cac7aec`) | Controls.* token-jumps |
| 17 | `panic 0x11` underflow (`0x4e487b71`) | an AMM/swap leaf |
| 18 | `0xfd7d16b0` | XYC-family |
| 19 | `0xec286c06` | XYCConcentrate-family |
| 20 | `DecayMissingPeriodArg` (`0x9d584cd8`) | **Decay._decayXD** |
| 21 | `MakerTraitsZeroAmountInNotAllowed` (`0x2087efa1`) | salt/fall-through |
| 22–23 | `FeeMissingFeeBPS` (`0xa73c6824`) | **Fee.*** |
| 24 | `ProgressiveFeeMissingFeeBPS` (`0x4f5033b3`) | **ProgressiveFee** |

The decisive tell is byte 24 = `ProgressiveFeeMissingFeeBPS`: a `_progressiveFeeInXD`
opcode that does **not exist anywhere in vendored swap-vm 0.0.6** (`AquaOpcodes` 0.0.6
stops at `Extruction` and never exposes progressive fee — see §4 CAUTION / §8 / §9.4).
So the deployed router is a LATER build with progressive-fee added and the opcode
indices shifted. Our builder emits XYCSwap at byte 17, which on the deployed router
is a different leaf — hence the underflow.

> Side note this also resolves the long-standing §8 open question: `_progressiveFeeInXD`
> IS reachable on the *deployed* Aqua router (byte 24), just not in our vendored 0.0.6
> sources. A future pass that re-vendors the matching router version could use it
> directly instead of the tiering/decay stand-ins.

### 11.3 The chosen resolution: HYBRID execution + on-chain linkage proof

The orchestrator + user picked **option 3 (hybrid)**: keep executing swaps on the
fresh-deployed 0.0.6 `AquaSwapVMRouter` (the pinned, reproducible stateless engine)
and ship liquidity into the SAME live Aqua singleton the canonical router uses, then
ADD a read-only on-chain test that proves the linkage honestly. Why hybrid (not
re-vendoring): 0.0.6 is the only published tag and `main`'s AquaOpcodes table is
byte-identical to it — the deployed build is unpublished, so there is no obtainable
source whose program bytes execute on the deployed router. Re-vendoring would mean
guessing/reconstructing unpublished bytecode; the hybrid keeps everything pinned and
reproducible while still anchoring on the real live deployment.

**What is shared vs self-deployed.** The *liquidity layer* is the real canonical Aqua
(`0x499943E7…6d31`) — the exact singleton the deployed router's `AQUA()` returns — so
our `ship`/`safeBalances`/`dock` already touch the live deployment. Only the
*stateless execution engine* (the SwapVM router that decodes program bytes and prices
the trade) is self-deployed from pinned 0.0.6.

**On-chain proof — `test/CanonicalRouterLinkage.t.sol`** asserts, on the fork at block
25,300,000:
1. `extcodesize(0x8fDD04…0958f) > 0` — the canonical router is real (measured 22,640).
2. `IRouterAqua(canonical).AQUA() == 0x499943E7…6d31` — the deployed router uses the
   SAME Aqua we ship into (the load-bearing linkage).
3. A fresh 0.0.6 `AquaSwapVMRouter` self-deploy has codesize **18,142** ≠ the deployed
   **22,640** — proving they are different builds (the dev-preview version skew) — and
   that fresh router's `AQUA()` also equals `0x499943E7…6d31`, so the ONLY difference
   between the two execution surfaces is the build, not the liquidity layer.

This captures the "uses the live deployment" narrative without running unverifiable
re-encoded bytes through the deployed router.

### 11.4 With A resolved, B/C/D proceed on the hybrid surface

- **B (quote==swap round-trip):** the happy-path WETH→USDC fork test and a composed
  fork test now call `router.quote(...)` before the real `swap(...)` with identical
  taker data and `assertEq` the `(amountIn, amountOut)` pair. `AquaLabTaker` got a
  `quote()` passthrough. Runs on the fresh-deploy router + live Aqua.
- **C (CoreInvariants):** `test/invariants/CoreInvariants.t.sol` +
  `ExactInOutSymmetry.t.sol` vendored from 0.0.6 into `lib/swap-vm/test/invariants/`;
  `test/ComposedInvariants.t.sol` inherits `CoreInvariants` and runs
  `assertAllInvariantsWithConfig(...)` against the composed strategy on the
  fresh-deploy router + live Aqua. **Additivity is configured OFF**
  (`skipAdditivity = true`) with justification: under `_decayXD` the price is
  path-dependent by design — a single swap(A+B) and a split swap(A)+swap(B) leave
  different decay offsets, so additivity (single ≥ split) is not an invariant for a
  decay-protected pool. Every other invariant (symmetry, quote/swap consistency,
  monotonicity, rounding-favors-maker, balance-sufficiency) runs and passes.
- **D (trace `registers` + `metadata.quoteEqualsSwap`):** the schema + TraceExporter
  now emit the 5 `SwapRegisters` after each instruction and a top-level
  `metadata.quoteEqualsSwap` boolean (from a real quote==swap check inside the
  exporter). All three fixtures regenerated via the §10.3 command and validate.

No tolerances were loosened and no pass was faked. Baseline + new tests all green.
