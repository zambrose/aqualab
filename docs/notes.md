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
