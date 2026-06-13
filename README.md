# AquaLab

A composed **1inch SwapVM** strategy shipped into the live **Aqua** shared-liquidity
deployment, plus an instruction-trace visualizer. ETHGlobal NY 2026 — "Build an
Aqua App" bounty.

> This README currently documents the **happy path** (the critical-path
> foundation). Strategy composition (concentrated liquidity / fees / decay) and
> the visualizer are layered on top by later stages.

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

## Layout

```
src/XYCStrategyBuilder.sol     Builds the XYCSwap program + maker Order (extension point)
src/vendor/ProgramBuilder.sol  SwapVM program encoder ([opcode][len][args] frames)
test/XYCSwapAquaFork.t.sol     Mainnet-fork ship + WETH/USDC swap + dock tests
test/AquaLabTaker.sol          Minimal taker (useTransferFromAndAquaPush mode)
lib/swap-vm, lib/aqua          Vendored 1inch protocol sources (ground truth)
docs/notes.md                  Protocol discoveries for downstream work
```

## Reproduce

Requirements: Foundry (`forge`), Node + npm, and a mainnet RPC URL.

```bash
# 1. install solidity deps (npm registry + github both reachable)
npm install

# 2. provide a mainnet RPC URL (foundry auto-loads .env)
cp .env.example .env && $EDITOR .env   # set MAINNET_RPC_URL=...

# 3. run the fork tests
forge test --match-contract XYCSwapAquaForkTest -vv
```

Expected: 3 passing tests; the WETH→USDC test logs the USDC received
(~2970.297 USDC for 1 WETH at the pinned fork block 25,300,000).
