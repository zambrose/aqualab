# AquaLab — 1inch Aqua/SwapVM Strategy + Instruction-Trace Visualizer

ETHGlobal NY 2026 entry targeting the **1inch "Build an Aqua App" bounty
($5,000)**. Direct SwapVM usage scores higher in judging.

## What we're building

1. **A composed SwapVM strategy** (Solidity + Foundry) using the standard
   opcode set, shipped into the live Aqua deployment on a mainnet fork:
   - balance setup → AMM primary (`_xycConcentrateGrowLiquidityXD`
     concentrated ranges, fallback `_xycSwapXD` constant product)
   - → `_progressiveFeeInXD` (fee)
   - → `_decayXD` (MEV protection)
   - Stretch only if ahead of schedule: one custom opcode.
2. **Foundry fork tests** proving real token transfers through the strategy
   (qualification requirement; local forks explicitly allowed).
3. **Trace visualizer**: instrumented execution → JSON trace → small static
   web UI (Vite/Next.js + canvas/p5.js) rendering the instruction sequence,
   balance deltas, and AMM curve state step-by-step.

OUT of scope: mainnet/testnet deployment, production trader frontend,
multiple strategies, Aqua liquidity UI, audits.

## Key protocol facts

- Aqua protocol deployed multi-chain at
  `0x499943e74fb0ce105688beee8ef2abec5d936d31` — fork mainnet and use the
  live deployment; do NOT redeploy Aqua.
- Flow primitives: `aqua.ship(app, abi.encode(strategy), tokens, amounts)`
  → strategyHash; `aqua.safeBalances(...)`; `aqua.dock(...)` to unwind.
- Routers: `SwapVMRouter` / `AquaSwapVMRouter` from
  https://github.com/1inch/swap-vm (instruction library incl. XYCSwap,
  XYCConcentrate, Decay, Fee, PeggedSwap).
- SDK: `@1inch/swap-vm` (npm) for building/encoding strategy programs.
- Template starter: https://github.com/1inch/swap-vm-template
- Docs: whitepapers live in the `aqua` and `swap-vm` repos. Read the SwapVM
  whitepaper before strategy work; the protocol is dev-preview and docs are
  thin — if the template is broken, scaffold from swap-vm's own test suite.

## Environment

- Fork tests REQUIRE a mainnet RPC URL in env var **`MAINNET_RPC_URL`**.
  If it is missing, stop and ask the user — never mock around it.
- Foundry (`forge`/`cast`/`anvil`) must be installed (via `foundryup`).

## Acceptance criteria (= bounty qualification requirements)

- [ ] On-chain execution of token transfers in the demo (local fork OK):
      a scripted swap routed through the strategy with visible balance
      changes.
- [ ] Strategy demonstrated through tests, scripts, AND UI.
- [ ] SwapVM used directly; README documents which opcodes and why.
- [ ] Proper git commit history — explicitly scored; no single-commit dumps.
- [ ] Public repo, README with instruction-pipeline diagram.

## Orchestration & model routing

The main loop (Fable 5) does ALL planning, integration decisions, and
review. Implementation is farmed out to the subagents in `.claude/agents/`:

| Agent | Model | Mission |
|---|---|---|
| agent-1-happy-path | opus | Fork env + first passing ship/swap test (critical path) |
| agent-2-strategy | opus | Compose concentrate/fee/decay; curve invariant property tests |
| agent-3-trace-exporter | sonnet | Foundry test → structured JSON trace |
| agent-4-visualizer | sonnet | Web UI rendering trace JSON + curve animation |

Rules:
- Never use `model: inherit`.
- Orchestrator reviews every subagent diff before merge.
- If a sonnet agent fails the same task twice, escalate that agent to opus
  rather than retrying a third time.
- Critical path: 1 → 2 → 3; agent 4 runs in parallel against a hand-written
  fixture trace from hour one.
- Fallback: if `_xycConcentrateGrowLiquidityXD` fights back, ship
  `_xycSwapXD` + fee + decay — still a composed position.

## Process: git checkpoints (mandatory — judged!)

Commit after: fork setup, first passing ship+swap test, each instruction
layer, trace export, viz fixture render, integration. Branch-per-agent,
merge via PRs, conventional commits, no squashing.
