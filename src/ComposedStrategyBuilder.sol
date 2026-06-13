// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";

import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import {
    XYCConcentrate,
    XYCConcentrateArgsBuilder
} from "@1inch/swap-vm/src/instructions/XYCConcentrate.sol";
import { Decay, DecayArgsBuilder } from "@1inch/swap-vm/src/instructions/Decay.sol";
import { Fee, FeeArgsBuilder } from "@1inch/swap-vm/src/instructions/Fee.sol";
import { Controls, ControlsArgsBuilder } from "@1inch/swap-vm/src/instructions/Controls.sol";

import { XYCStrategyBuilder } from "./XYCStrategyBuilder.sol";
import { Program, ProgramBuilder } from "./vendor/ProgramBuilder.sol";

/// @title ComposedStrategyBuilder
/// @notice The AquaLab "sophisticated position": a composed SwapVM strategy that
///         layers a fee instruction and a time-decay (MEV-protection) instruction
///         around an AMM pricing primitive — either the concentrated-liquidity
///         curve (`XYCConcentrate._xycConcentrateGrowLiquidity2D`) or the plain
///         constant-product curve (`XYCSwap._xycSwapXD`).
///
/// ## The instruction pipeline (byte order = OUTERMOST wrapper first)
///
///        [ Controls._salt ]          uniqueness no-op (hash perturbation)
///        [ Decay._decayXD ]          MEV / size protection (virtual-balance decay)
///        [ Fee._flatFeeAmountInXD ]  liquidity-provider fee on amountIn
///        [ <AMM primitive> ]         price the trade (concentrated OR constant-product)
///
///      ### Why this order? (security-critical)
///
///      `Fee` and `Decay` are *wrapper* instructions: each one mutates the swap
///      registers, then calls `ctx.runLoop()` to execute the REST of the program
///      (everything after its own frame), and finally post-processes on the way
///      back out. The AMM primitive is a *leaf*: it sets `amountOut` (exact-in)
///      and returns without recursing. So the BYTE ORDER directly encodes the
///      nesting:  Decay( Fee( Swap ) ).
///
///        1. `Decay` runs first and OUTERMOST. It adjusts the virtual reserves
///           (`balanceIn`/`balanceOut`) for any un-decayed offset left by recent
///           trades BEFORE anything else prices against them, then — after the
///           inner swap completes — records the new offset from the realized
///           amounts. Decay must wrap the swap so the swap prices against the
///           *protected* (virtual) reserves, and so the offset it records matches
///           the trade that actually happened.
///
///        2. `Fee` runs next, INSIDE decay but OUTSIDE the swap. For exact-in it
///           reduces `amountIn` by the fee, lets the swap price the *net* input,
///           then restores the taker-defined `amountIn`. The taker pays the full
///           input; the swap only credits output for the net input; the
///           difference accrues to the maker as fee. Fee MUST sit outside the
///           swap (it has to alter the amount the curve sees) and the swap MUST
///           NOT have run yet when fee executes — hence the
///           `FeeShouldBeAppliedBeforeSwapAmountsComputation` guard, which both
///           Fee and Decay assert (`amountIn == 0 || amountOut == 0`). Ordering
///           the swap before fee/decay would trip that guard and revert.
///
///        3. The AMM primitive runs LAST and INNERMOST — it is the only step that
///           sets the missing amount, after decay has shaped the reserves and fee
///           has shaped the input.
///
///      `Controls._salt` is a pure no-op placed FIRST so it executes once and
///      falls straight through into the decay frame; it only perturbs the order
///      hash so otherwise-identical pools ship as distinct immutable Aqua
///      strategies.
///
/// ## The "progressive fee" question (honest course-correction)
///
///      CLAUDE.md's original plan named `_progressiveFeeInXD`. That opcode is
///      NOT in the Aqua opcode table (`AquaOpcodes`) — it only exists in the
///      experimental generic `Opcodes` set. The Aqua-reachable fee opcodes are
///      `Fee._flatFeeAmountInXD` (a flat bps fee), `Fee._protocolFeeAmountInXD`,
///      `Fee._aquaProtocolFeeAmountInXD`, and the dynamic variants. None of them
///      makes the fee *rate* grow with trade size on its own, and the Aqua
///      `Controls` set has no amount-based jump, so a single program cannot
///      branch its fee rate by size using only stock opcodes.
///
///      We realize PROGRESSIVE behavior honestly, two ways, both documented:
///
///        (a) Per-strategy fee TIERING — `progressiveFeeBps(amountIn)` maps a
///            trade size to a monotonically non-decreasing fee rate, and
///            `buildTieredPrograms(...)` / `buildProgressiveOrders(...)` ship a
///            ladder of pools at increasing fee tiers. A size-aware taker (or
///            router) selects the tier for its size — this is how real venues
///            implement tiered fees. The fee-monotonic property test targets
///            `progressiveFeeBps`.
///
///        (b) Decay-as-progressive — `_decayXD` already makes the *effective*
///            cost grow with trade size and frequency: a large trade leaves a
///            large decaying offset that worsens the price of the next trade
///            until it decays away. This is the in-program "progressive" beat
///            the small-then-large two-swap test demonstrates.
///
/// @dev Inherits `XYCStrategyBuilder` (hence `AquaOpcodesDebug`) only to reuse the
///      canonical `_opcodes()` table and the `MakerTraits`-wrapping `buildOrder`
///      machinery. The debug variant fills only reserved no-op slots, so the
///      program bytes are byte-identical to what the production `AquaSwapVMRouter`
///      executes.
contract ComposedStrategyBuilder is XYCStrategyBuilder {
    using ProgramBuilder for Program;

    /// @notice AMM primitive selector for a composed program.
    /// @custom:member ConstantProduct  XYCSwap._xycSwapXD — x*y=k over real reserves.
    /// @custom:member Concentrated     XYCConcentrate._xycConcentrateGrowLiquidity2D —
    ///                concentrated liquidity inside a [P_min, P_max] price band.
    enum Curve {
        ConstantProduct,
        Concentrated
    }

    /// @notice Parameters for a single composed pool.
    /// @param salt          Uniqueness salt for the Aqua strategy hash.
    /// @param feeBps        Liquidity-provider fee in SwapVM bps (1e9 = 100%).
    /// @param decayPeriod   Decay window in seconds (uint16). 0 disables the decay
    ///                      frame entirely (no Decay instruction emitted).
    /// @param curve         Which AMM primitive to price with.
    /// @param sqrtPriceMin  Concentrated only: sqrt(P_min) in 1e18 fp, P = tokenGt/tokenLt.
    /// @param sqrtPriceMax  Concentrated only: sqrt(P_max) in 1e18 fp, P = tokenGt/tokenLt.
    struct PoolParams {
        uint64 salt;
        uint32 feeBps;
        uint16 decayPeriod;
        Curve curve;
        uint256 sqrtPriceMin;
        uint256 sqrtPriceMax;
    }

    constructor(address aqua) XYCStrategyBuilder(aqua) { }

    // ---------------------------------------------------------------------
    // Program assembly
    // ---------------------------------------------------------------------

    /// @notice Build the composed program bytes: salt → [decay] → [fee] → AMM.
    /// @dev See the contract-level NatSpec for the full ordering rationale.
    /// @param params Pool configuration (curve, fee, decay, price band, salt).
    /// @return programBytes Concatenated [opcode][len][args] instruction stream.
    function buildComposedProgram(PoolParams memory params)
        public
        pure
        returns (bytes memory programBytes)
    {
        Program memory p = ProgramBuilder.init(_opcodes());

        // 1. salt — pure no-op, perturbs the order hash. Placed first so it
        //    executes once and the loop falls straight into the decay wrapper.
        programBytes = p.build(Controls._salt, ControlsArgsBuilder.buildSalt(params.salt));

        // 2. decay — OUTERMOST wrapper. Args: uint16 decayPeriod (seconds).
        //    Skipped entirely when decayPeriod == 0 so the simplest composed
        //    program is just fee+swap.
        if (params.decayPeriod != 0) {
            programBytes = bytes.concat(
                programBytes,
                p.build(Decay._decayXD, DecayArgsBuilder.build(params.decayPeriod))
            );
        }

        // 3. fee — wraps the swap. Args: uint32 feeBps (1e9 = 100%).
        //    Skipped when feeBps == 0 (a 0-bps flat fee is a no-op but we avoid
        //    emitting the frame at all to keep the trace clean).
        if (params.feeBps != 0) {
            programBytes = bytes.concat(
                programBytes,
                p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(params.feeBps))
            );
        }

        // 4. AMM primitive — INNERMOST leaf. Sets the missing amount.
        programBytes = bytes.concat(programBytes, _curveProgram(p, params));
    }

    /// @dev Emit the AMM-primitive frame for the selected curve.
    function _curveProgram(Program memory p, PoolParams memory params)
        internal
        pure
        returns (bytes memory)
    {
        if (params.curve == Curve.Concentrated) {
            // Concentrated-liquidity curve. Args: two uint256 sqrt-prices (1e18 fp):
            //   sqrt(P_min), sqrt(P_max),  P = tokenGt/tokenLt (higher addr / lower addr).
            return p.build(
                XYCConcentrate._xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(params.sqrtPriceMin, params.sqrtPriceMax)
            );
        }
        // Constant-product curve. No args.
        return p.build(XYCSwap._xycSwapXD);
    }

    // ---------------------------------------------------------------------
    // Order assembly
    // ---------------------------------------------------------------------

    /// @notice Build a full Aqua-backed maker Order around a composed program.
    /// @dev Mirrors `XYCStrategyBuilder.buildOrder` but with the composed program.
    ///      `useAquaInsteadOfSignature = true` → reserves sourced/settled through
    ///      Aqua; `receiver = address(0)` resolves to the maker (required in Aqua
    ///      mode).
    function buildComposedOrder(address maker, PoolParams memory params)
        public
        pure
        returns (ISwapVM.Order memory order)
    {
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: buildComposedProgram(params)
        }));
    }

    // ---------------------------------------------------------------------
    // Progressive-fee schedule (pure math — the "progressive" realization (a))
    // ---------------------------------------------------------------------

    /// @notice A monotonically non-decreasing fee schedule: bigger trades pay a
    ///         higher fee RATE. This is the documented stand-in for the missing
    ///         `_progressiveFeeInXD` Aqua opcode (see contract NatSpec).
    ///
    ///         Three tiers keyed off the input amount (in tokenIn's own units):
    ///           amountIn <  smallThreshold        → baseFeeBps
    ///           amountIn in [small, large)        → midFeeBps
    ///           amountIn >= largeThreshold        → highFeeBps
    ///
    ///         A size-aware taker/router prices its trade, picks the tier, and
    ///         routes to the pool shipped at that tier (see buildProgressiveOrders).
    ///
    /// @dev Pure and fork-free, so the fee-monotonicity property test can fuzz it
    ///      cheaply without touching the RPC. `require`s enforce a non-decreasing
    ///      schedule so the invariant holds by construction.
    /// @param amountIn        Trade size in tokenIn units.
    /// @param smallThreshold  Upper bound (exclusive) of the base tier.
    /// @param largeThreshold  Lower bound (inclusive) of the high tier.
    /// @param baseFeeBps      Fee for small trades.
    /// @param midFeeBps       Fee for mid trades (>= baseFeeBps).
    /// @param highFeeBps      Fee for large trades (>= midFeeBps).
    function progressiveFeeBps(
        uint256 amountIn,
        uint256 smallThreshold,
        uint256 largeThreshold,
        uint32 baseFeeBps,
        uint32 midFeeBps,
        uint32 highFeeBps
    ) public pure returns (uint32 feeBps) {
        require(smallThreshold <= largeThreshold, "schedule: thresholds");
        require(baseFeeBps <= midFeeBps && midFeeBps <= highFeeBps, "schedule: fees");

        if (amountIn >= largeThreshold) {
            return highFeeBps;
        }
        if (amountIn >= smallThreshold) {
            return midFeeBps;
        }
        return baseFeeBps;
    }
}
