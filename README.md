# AquaLab

A composed **1inch SwapVM** strategy shipped into the live **Aqua** shared-liquidity
deployment, plus an instruction-trace visualizer. ETHGlobal NY 2026 — "Build an
Aqua App" bounty.

Three parts, all working end-to-end on a mainnet fork:

1. **A composed SwapVM strategy** — concentrated liquidity (or constant-product
   fallback) wrapped with a fee instruction and a time-decay MEV-protection
   instruction, shipped into the **live Aqua deployment** and swapped against
   with real WETH/USDC transfers ([the strategy](#the-composed-strategy-the-sophisticated-position)).
2. **Foundry fork tests** proving the on-chain token transfers, plus fork-free
   curve-invariant property tests ([tests](#curve-invariant-property-tests)).
3. **An instruction-trace visualizer** that renders the real per-opcode execution
   — the instruction pipeline, balance deltas, and AMM curve state — step by step
   ([visualizer](#trace-visualizer)).

## What works today

A maker ships a stock **XYCSwap** (constant-product, `x*y=k`) SwapVM strategy into
the **live Aqua deployment** (`0x499943E74FB0cE105688beeE8Ef2ABec5D936d31`) on a
mainnet fork, and a taker executes real **WETH ⇄ USDC** swaps through an
`AquaSwapVMRouter`, with visible ERC-20 balance changes on both sides.

```
maker.approve(Aqua)
        │
        ▼
aqua.ship(router, abi.encode(order), [WETH,USDC], [reserves])  ──►  strategyHash == router.hash(order)
        │
        ▼
taker.swap(order, tokenIn, tokenOut, amount, takerTraits)
        │
        ▼
   AquaSwapVMRouter.swap
        ├─ AQUA.safeBalances ........ seed (balanceIn, balanceOut)
        ├─ run program ───────────────────────────────────────────┐
        │     [ XYCSwap._xycSwapXD ]   x*y=k pricing               │  instruction
        │     [ Controls._salt    ]   unique strategy hash (no-op) │  pipeline
        ├─ AQUA.pull tokenOut → taker  (from maker wallet) ◄───────┘
        └─ transferFrom tokenIn ← taker, AQUA.push → maker wallet
```

### Instructions used (and why)

| Opcode | Why it's in the program |
|---|---|
| `XYCSwap._xycSwapXD` | The constant-product AMM primitive — prices the trade off the Aqua-backed reserves so `balanceIn*balanceOut` never decreases. The minimal, stock AMM curve. |
| `Controls._salt` | Pricing no-op. Perturbs the order hash so two otherwise-identical pools ship as distinct, immutable Aqua strategies. Carries no economic meaning. |

The strategy runs in **Aqua-backed mode** (`useAquaInsteadOfSignature`): reserves
are sourced and settled through Aqua against the maker's own wallet (Aqua is
non-custodial), instead of via an EIP-712 maker signature.

See [`docs/notes.md`](docs/notes.md) for the full protocol reference (real ABI
signatures, program byte layout, the Aqua opcode table, and trace hooks).

## The composed strategy (the "sophisticated position")

[`src/ComposedStrategyBuilder.sol`](src/ComposedStrategyBuilder.sol) layers a
**fee** instruction and a **time-decay (MEV-protection)** instruction around an
AMM pricing primitive that is either **concentrated liquidity** (primary) or
plain **constant product** (documented fallback). The program is a stream of
`[opcode][len][args]` frames in **outermost-wrapper-first** byte order:

```
maker ships ComposedStrategyBuilder.buildComposedOrder(maker, params)
        │
        ▼
   AquaSwapVMRouter.swap
        ├─ AQUA.safeBalances ........ seed (balanceIn, balanceOut)
        ├─ run program ─────────────────────────────────────────────────────┐
        │   [ Controls._salt ]          uniqueness no-op (hash perturbation)  │
        │   [ Decay._decayXD ]          ── outermost wrapper ──┐              │  instruction
        │   [ Fee._flatFeeAmountInXD ]  ── inner wrapper ──┐   │              │  pipeline
        │   [ <AMM primitive> ]         ── leaf ──┐        │   │              │  (nested:
        │       XYCConcentrate._xycConcentrateGrowLiquidity2D  (primary)      │   Decay(
        │       └─ OR XYCSwap._xycSwapXD                       (fallback)     │     Fee(
        ├─ AQUA.pull tokenOut → taker  (from maker wallet) ◄─────────────────┘     Swap)))
        └─ transferFrom tokenIn ← taker, AQUA.push → maker wallet
```

### Why this is *nested*, not a flat list (ordering is security-critical)

`Fee` and `Decay` are **wrapper** instructions: each mutates the swap registers,
then calls `ctx.runLoop()` to execute *everything after its own frame*, and finally
post-processes on the way back out. The AMM primitive is a **leaf**: it sets the
missing amount and returns without recursing. So the byte order directly encodes
the nesting `Decay( Fee( Swap ) )`.

Both `Fee` and `Decay` assert `amountIn == 0 || amountOut == 0` (the
`…ShouldBeApplied/CalledBeforeSwapAmountsComputation` guard) — they MUST run
before the swap has priced anything. Putting the swap first would trip that guard
and revert. Decay wraps fee wraps swap so that: decay shapes the (virtual)
reserves the curve prices against and records the realized trade's offset; fee
shapes the input the curve sees; the curve runs last and innermost.

### The instructions and their math

| Opcode | Curve / formula | Parameters | Why it's here |
|---|---|---|---|
| `XYCConcentrate._xycConcentrateGrowLiquidity2D` | Concentrated CPMM. Computes liquidity `L` from real balances + a sqrt-price band, forms **virtual** reserves `x_v = x + L/√P_max`, `y_v = y + L·√P_min`, then prices `out = Δin·y_v/(x_v+Δin)`. Real `x·y` still grows; fees auto-reinvest as growing real balances raise `L`. | `sqrtPriceMin`, `sqrtPriceMax` — `√P` in 1e18 fp, `P = tokenGt/tokenLt` in **raw** token units. | Primary AMM. Concentrating liquidity into `[P_min,P_max]` deepens the book: same real reserves return more output near spot than plain `x·y=k`. |
| `XYCSwap._xycSwapXD` | Constant product. `out = Δin·y/(x+Δin)` (floor) so `x·y` never decreases. | none | Documented fallback AMM — a composed `swap+fee+decay` position still qualifies. Selected via `PoolParams.curve`. |
| `Fee._flatFeeAmountInXD` | Flat fee on input. Exact-in: `netIn = Δin − ⌈Δin·feeBps/1e9⌉`; the curve prices `netIn`; the taker still pays the full `Δin`, so the fee accrues to the maker (pool keeps full input, pays out less → `k` grows extra). | `feeBps` — fee in SwapVM bps (`1e9 = 100%`). | Liquidity-provider fee. Wraps the swap so it can shrink the amount the curve sees. |
| `Decay._decayXD` | Mooniswap-style virtual-balance decay. A trade leaves an offset that linearly decays to zero over `period`: `offset(t) = offset₀·(expiry−t)/period`. While it persists it virtually shrinks `balanceOut` / grows `balanceIn`, worsening the price of a same-direction follow-up trade. | `period` — decay window in seconds (`uint16`). | MEV / sandwich protection: front-running a victim costs the attacker the decay penalty on the second leg. |
| `Controls._salt` | no-op | `salt` (`uint64`) | Perturbs the order hash so identical pools ship as distinct immutable Aqua strategies. |

### "Progressive fee" — an honest course-correction

The original plan named `_progressiveFeeInXD`. **That opcode is not in the Aqua
opcode table** (`AquaOpcodes`); it lives only in the experimental generic
`Opcodes` set. The Aqua-reachable fee opcodes (`_flatFeeAmountInXD`,
`_protocolFeeAmountInXD`, `_aquaProtocolFeeAmountInXD`, dynamic variants) all
charge a *flat* rate, and the Aqua `Controls` set has **no amount-based jump**, so
a single program cannot branch its fee rate by trade size with stock opcodes.

We realize progressive *behavior* two documented ways:

1. **Per-strategy fee tiering.** `ComposedStrategyBuilder.progressiveFeeBps(size, …)`
   maps a trade size to a monotonically non-decreasing fee rate (small/mid/large
   tiers). A size-aware taker or router selects the pool shipped at the matching
   tier — how real venues implement tiered fees. The fee-monotonicity property
   test targets this function.
2. **Decay-as-progressive.** `_decayXD` already makes the *effective* cost grow
   with trade size and frequency: a big trade leaves a big offset that worsens the
   next trade until it decays away. This is the in-program progressive beat shown
   by the small→large two-swap fork test.

### Curve-invariant property tests

[`test/CurveInvariants.t.sol`](test/CurveInvariants.t.sol) — 256-run fork-free
fuzz tests mirroring the vendored formulas:

- constant-product `k` non-decreasing across an exact-in swap,
- a flat fee never increases output,
- `progressiveFeeBps` monotonically non-decreasing in size,
- the decay offset non-increasing in time and zero at expiry,
- the concentrated curve's implied spot price stays inside `[P_min, P_max]`.

[`test/ComposedStrategyFork.t.sol`](test/ComposedStrategyFork.t.sol) proves the
composed strategy ships + swaps through the **live Aqua** deployment with real
WETH/USDC transfers, including the two-swap progressive-cost scenario.

## Trace visualizer

The [`viz/`](viz/) app is a static Vite/TypeScript UI that renders a **real**
execution trace of the composed strategy — no backend, no wallet, no chain access
at view time. It steps through the instruction pipeline one opcode at a time,
showing the decoded params, the maker/taker balance deltas, and the AMM price
curve (constant-product hyperbola with the concentrated range highlighted, the
swap point moving along it) mutating per step.

The traces it renders are not hand-drawn — they are exported from the fork tests.
[`test/TraceExporter.t.sol`](test/TraceExporter.t.sol) runs the real composed swap
and, for each step, derives the intermediate VM state from the **same** decay → fee
→ AMM math the contracts use; it `assertEq`s the trace's final output against the
on-chain measured `taker.swap(...)` output, so the visualization cannot silently
drift from reality. The exporter writes JSON validated against
[`viz/fixtures/trace.schema.json`](viz/fixtures/trace.schema.json).

```bash
# regenerate both traces from a live fork run, then validate them
forge test --match-contract TraceExporter \
  && node viz/scripts/copy-traces.mjs \
  && (cd viz && npm run validate)

# run the visualizer
cd viz && npm install && npm run dev      # http://localhost:5173
```

The dropdown switches between the small swap (1 WETH, constant-product + fee +
decay → 2961.47 USDC) and the large swap (5 WETH, concentrated + fee + decay →
14954.22 USDC), both at the pinned fork block.

## Layout

```
src/XYCStrategyBuilder.sol       Builds the XYCSwap program + maker Order (extension point)
src/ComposedStrategyBuilder.sol  Composed strategy: salt→decay→fee→AMM (concentrated/fallback)
src/vendor/ProgramBuilder.sol    SwapVM program encoder ([opcode][len][args] frames)
test/XYCSwapAquaFork.t.sol       Mainnet-fork ship + WETH/USDC swap + dock tests (happy path)
test/ComposedStrategyFork.t.sol  Fork tests: composed fee+decay+AMM + two-swap progressive scenario
test/CurveInvariants.t.sol       Fork-free fuzz property tests on curve/fee/decay math
test/TraceExporter.t.sol         Runs real swaps, exports per-opcode JSON traces
test/AquaLabTaker.sol            Minimal taker (useTransferFromAndAquaPush mode)
viz/                             Static trace visualizer (Vite/TS); renders real traces
viz/fixtures/trace.schema.json   JSON Schema for execution traces (validated in CI loop)
viz/scripts/copy-traces.mjs      Promotes forge-exported traces into viz fixtures
lib/swap-vm, lib/aqua            Vendored 1inch protocol sources (ground truth)
docs/notes.md                    Protocol discoveries for downstream work
```

## Reproduce

Requirements: Foundry (`forge`), Node + npm, and a mainnet RPC URL.

```bash
# 1. install solidity deps (npm registry + github both reachable)
npm install

# 2. provide a mainnet RPC URL (foundry auto-loads .env)
cp .env.example .env && $EDITOR .env   # set MAINNET_RPC_URL=...

# 3. run the full suite (happy path + composed fork tests + invariants)
forge test -vv

# ...or just one layer:
forge test --match-contract XYCSwapAquaForkTest -vv     # happy path
forge test --match-contract ComposedStrategyForkTest -vv # composed fee+decay+AMM
forge test --match-contract CurveInvariantsTest -vv      # fork-free property tests
```

Expected: **12 passing tests**. The happy-path WETH→USDC test logs ~2970.297 USDC
for 1 WETH at the pinned fork block 25,300,000; the composed concentrated test
returns ~2996.67 USDC (deeper band) vs ~2961.47 for plain `x·y=k` with the same
fee. See [Trace visualizer](#trace-visualizer) to export those runs as a trace and
step through them in the UI.
