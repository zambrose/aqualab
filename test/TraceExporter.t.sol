// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// solhint-disable no-console

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { ComposedStrategyBuilder } from "../src/ComposedStrategyBuilder.sol";
import { AquaLabTaker } from "./AquaLabTaker.sol";

/// @title TraceExporter
/// @notice Runs REAL composed-strategy swaps on the mainnet fork and writes structured
///         JSON traces to ./traces/. Two swaps are traced:
///           1. Small swap  — 1 WETH → USDC (constant-product + fee + decay)
///           2. Large swap  — 5 WETH → USDC (concentrated + fee + decay)
///
///         Each trace captures the real on-chain amountOut, then derives the per-step
///         intermediate state (virtualReserves, netAmountIn to AMM, etc.) from the
///         exact same math the contracts use. A final assertion confirms the traced
///         output equals the real measured swap output, so the trace cannot silently
///         drift from reality.
///
///         Run:  forge test --match-contract TraceExporter -v
///         Output: ./traces/trace-small-swap.json and ./traces/trace-large-swap.json
contract TraceExporter is Test {
    using stdJson for string;

    // ---------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------

    uint256 internal constant BPS = 1e9;

    address internal constant AQUA_ADDR = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 internal constant FORK_BLOCK = 25_300_000;

    uint256 internal constant RESERVE_WETH = 100 ether;
    uint256 internal constant RESERVE_USDC = 300_000 * 1e6;

    uint32 internal constant FEE_BPS = 3_000_000; // 0.30% (3e6 in 1e9 scale)
    uint16 internal constant DECAY_PERIOD = 3_600;  // 1-hour window

    // Concentrated band sqrtPrices (from ComposedStrategyFork.t.sol)
    uint256 internal constant SQRT_MIN = 17_344_547_654_330_260_259_470;
    uint256 internal constant SQRT_MAX = 19_170_289_512_680_813_970_993;

    IAqua internal aqua;
    AquaSwapVMRouter internal router;
    ComposedStrategyBuilder internal builder;
    AquaLabTaker internal taker;

    address internal maker = makeAddr("traceMaker");

    // ---------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);

        aqua = IAqua(AQUA_ADDR);
        router = new AquaSwapVMRouter(AQUA_ADDR, WETH, address(this), "SwapVM", "1.0.0");
        builder = new ComposedStrategyBuilder(AQUA_ADDR);
        taker = new AquaLabTaker(router.asView());
    }

    // ---------------------------------------------------------------------------
    // Entry points
    // ---------------------------------------------------------------------------

    /// @notice Export both traces. Run with `forge test --match-test test_ExportTraces -v`
    function test_ExportTraces() public {
        _exportSmallSwap();
        _exportLargeSwap();
    }

    /// @notice Export the two-swap decay trace (decay-affected reverse swap).
    ///         Run with `forge test --match-test test_ExportTwoSwapDecay -v`
    function test_ExportTwoSwapDecay() public {
        _exportTwoSwapDecay();
    }

    // ---------------------------------------------------------------------------
    // Small swap: 1 WETH → USDC, constant-product + flat fee + decay
    // ---------------------------------------------------------------------------

    function _exportSmallSwap() internal {
        uint256 amountIn = 1 ether;
        uint64 salt = 901;

        ComposedStrategyBuilder.PoolParams memory params = ComposedStrategyBuilder.PoolParams({
            salt: salt,
            feeBps: FEE_BPS,
            decayPeriod: DECAY_PERIOD,
            curve: ComposedStrategyBuilder.Curve.ConstantProduct,
            sqrtPriceMin: 0,
            sqrtPriceMax: 0
        });

        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipPool(params);

        // Fund taker and execute real swap
        deal(WETH, address(taker), amountIn);
        taker.approveRouter(WETH, amountIn);

        uint256 takerWethBefore = IERC20(WETH).balanceOf(address(taker));
        uint256 takerUsdcBefore = IERC20(USDC).balanceOf(address(taker));
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        (, uint256 realOut) = taker.swap(order, WETH, USDC, amountIn, _takerData());

        uint256 takerWethAfter = IERC20(WETH).balanceOf(address(taker));
        uint256 takerUsdcAfter = IERC20(USDC).balanceOf(address(taker));
        uint256 makerWethAfter = IERC20(WETH).balanceOf(maker);
        uint256 makerUsdcAfter = IERC20(USDC).balanceOf(maker);

        console.log("SMALL SWAP: amountIn=%d, realOut=%d", amountIn, realOut);

        // -----------------------------------------------------------------------
        // Derive per-step state using the SAME math as the contracts
        //
        // Program execution: salt -> decay -> fee -> xycSwap (nested)
        //   Decay is OUTERMOST: adjusts virtual balances, calls inner loop
        //   Fee is inside Decay: adjusts amountIn, calls inner loop
        //   xycSwap is innermost leaf: computes amountOut
        //
        // For the FIRST swap after shipping, decay offsets are ZERO (storage empty).
        // So virtual reserves == real reserves at the start of this swap.
        // -----------------------------------------------------------------------

        // Real pool reserves before swap
        uint256 rIn0 = RESERVE_WETH;  // real balanceIn (WETH)
        uint256 rOut0 = RESERVE_USDC; // real balanceOut (USDC)

        // Decay step: with no prior offsets, virtual reserves = real reserves
        // (decay adds offsetIn to balanceIn and subtracts offsetOut from balanceOut;
        //  both are 0 on first swap)
        uint256 vIn_decay = rIn0;    // virtual balanceIn after decay
        uint256 vOut_decay = rOut0;  // virtual balanceOut after decay

        // Fee step: reduce amountIn by fee (ceiling division per Fee.sol)
        uint256 feeAmount = Math.ceilDiv(amountIn * FEE_BPS, BPS);
        uint256 netAmountIn = amountIn - feeAmount; // amountIn that the AMM sees

        // xycSwap step (constant-product, exact-in):
        //   amountOut = netAmountIn * vOut / (vIn + netAmountIn)
        uint256 tracedOut = netAmountIn * vOut_decay / (vIn_decay + netAmountIn);

        // Assert traced output matches real measured output
        assertEq(tracedOut, realOut,
            "SMALL: traced amountOut must equal real on-chain measured amountOut");

        // -----------------------------------------------------------------------
        // Real pool reserves AFTER swap (for post-swap curveState in last step)
        // -----------------------------------------------------------------------
        (uint256 poolWethAfter, uint256 poolUsdcAfter) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);

        // Spot price = USDC per WETH = rOut/rIn (in human-readable units, adjusted for decimals)
        // P = balanceOut / balanceIn * (1e18/1e6) = balanceOut/balanceIn * 1e12
        // but since we want USDC_per_WETH: spot = (rOut_human) / (rIn_human)
        //   = (rOut / 1e6) / (rIn / 1e18) = rOut * 1e12 / rIn
        // For the virtual (=real on first swap), same formula
        uint256 spotBefore_raw = rOut0 * 1e12 / rIn0;   // USDC per WETH before swap
        uint256 spotAfter_raw  = poolUsdcAfter * 1e12 / poolWethAfter; // after swap

        // Decay state: for first swap with period=3600, no prior timestamp:
        //   offset = 0 before; after = amountIn (for tokenIn direction) and amountOut (for tokenOut)
        // But we record what the decay instruction SEES, not the stored offset.
        // Before decay executes: offsets are zero. After decay: inner loop ran, new offsets stored.

        // swapPointX: normalized position of the swap on the curve. For x*y=k:
        //   x-axis goes from 0 to 1 where 0 = empty balanceIn, 1 = infinite balanceIn
        //   Approximate: amountIn / (amountIn + rIn0) normalized
        uint256 poolSpotXnum = (rIn0 + amountIn) * 1000 / (rIn0 * 2 + amountIn); // ~0-1 scaled *1000

        // Build JSON trace
        string memory trace = _buildTrace(
            unicode"Small Swap — 1 WETH via CC+fee+decay",
            strategyHash,
            FORK_BLOCK,
            amountIn,
            realOut,
            _buildSmallSwapSteps(
                amountIn,
                realOut,
                feeAmount,
                netAmountIn,
                rIn0, rOut0,
                vIn_decay, vOut_decay,
                poolWethAfter, poolUsdcAfter,
                spotBefore_raw,
                spotAfter_raw,
                poolSpotXnum,
                takerWethBefore, takerUsdcBefore,
                takerWethAfter, takerUsdcAfter,
                makerWethBefore, makerUsdcBefore,
                makerWethAfter, makerUsdcAfter
            )
        );

        vm.writeFile("./traces/trace-small-swap.json", trace);
        console.log("Written: ./traces/trace-small-swap.json");
    }

    // ---------------------------------------------------------------------------
    // Large swap: 5 WETH → USDC, concentrated-liquidity + flat fee + decay
    // ---------------------------------------------------------------------------

    function _exportLargeSwap() internal {
        uint256 amountIn = 5 ether;
        uint64 salt = 902;

        ComposedStrategyBuilder.PoolParams memory params = ComposedStrategyBuilder.PoolParams({
            salt: salt,
            feeBps: FEE_BPS,
            decayPeriod: DECAY_PERIOD,
            curve: ComposedStrategyBuilder.Curve.Concentrated,
            sqrtPriceMin: SQRT_MIN,
            sqrtPriceMax: SQRT_MAX
        });

        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipPool(params);

        // Fund taker and execute real swap
        deal(WETH, address(taker), amountIn);
        taker.approveRouter(WETH, amountIn);

        uint256 takerWethBefore = IERC20(WETH).balanceOf(address(taker));
        uint256 takerUsdcBefore = IERC20(USDC).balanceOf(address(taker));
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        (, uint256 realOut) = taker.swap(order, WETH, USDC, amountIn, _takerData());

        uint256 takerWethAfter = IERC20(WETH).balanceOf(address(taker));
        uint256 takerUsdcAfter = IERC20(USDC).balanceOf(address(taker));
        uint256 makerWethAfter = IERC20(WETH).balanceOf(maker);
        uint256 makerUsdcAfter = IERC20(USDC).balanceOf(maker);

        console.log("LARGE SWAP: amountIn=%d, realOut=%d", amountIn, realOut);

        // -----------------------------------------------------------------------
        // Derive per-step state for concentrated-liquidity
        //
        // Concentrated AMM: virtual balances = real + L-based extension
        //   isTokenInLt = (tokenIn < tokenOut) = (WETH < USDC) = false (WETH > USDC addr)
        //   So: tokenIn=WETH is tokenGt, tokenOut=USDC is tokenLt
        //   bLt = balanceOut (USDC), bGt = balanceIn (WETH)
        //   L = _computeL(bLt, bGt, sqrtMin, sqrtMax)
        //   virtualBalanceIn  = balanceIn  + mulDiv(L, sqrtPriceMin, 1e18, ceil)
        //   virtualBalanceOut = balanceOut + mulDiv(L, 1e18, sqrtPriceMax)
        // -----------------------------------------------------------------------

        uint256 rIn0 = RESERVE_WETH;
        uint256 rOut0 = RESERVE_USDC;
        uint256 ONE = 1e18;

        // For concentrated, first swap: no decay offsets, virtual == real for decay step
        uint256 vIn_decay = rIn0;
        uint256 vOut_decay = rOut0;

        // Fee step
        uint256 feeAmount = Math.ceilDiv(amountIn * FEE_BPS, BPS);
        uint256 netAmountIn = amountIn - feeAmount;

        // XYCConcentrate: compute L and virtual reserves from real balances
        // WETH addr > USDC addr => tokenIn(WETH) is tokenGt, tokenOut(USDC) is tokenLt
        uint256 bLt = vOut_decay; // USDC = tokenLt
        uint256 bGt = vIn_decay;  // WETH = tokenGt
        uint256 L = _computeL(bLt, bGt, SQRT_MIN, SQRT_MAX);

        // isTokenInLt = false (WETH > USDC address)
        // virtualBalanceIn  = balanceIn  + mulDiv(L, sqrtPriceMin, 1e18, ceil)
        // virtualBalanceOut = balanceOut + mulDiv(L, 1e18, sqrtPriceMax)
        uint256 vIn_conc = vIn_decay + Math.mulDiv(L, SQRT_MIN, ONE, Math.Rounding.Ceil);
        uint256 vOut_conc = vOut_decay + Math.mulDiv(L, ONE, SQRT_MAX);

        // Exact-in AMM output
        uint256 tracedOut = netAmountIn * vOut_conc / (vIn_conc + netAmountIn);

        // Assert traced output matches real measured output
        assertEq(tracedOut, realOut,
            "LARGE: traced amountOut must equal real on-chain measured amountOut");

        // Post-swap reserves
        (uint256 poolWethAfter, uint256 poolUsdcAfter) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);

        uint256 spotBefore_raw = rOut0 * 1e12 / rIn0;
        // After concentrated swap, virtual spot from post-swap balances
        uint256 L2 = _computeL(poolUsdcAfter, poolWethAfter, SQRT_MIN, SQRT_MAX);
        uint256 vIn2  = poolWethAfter + Math.mulDiv(L2, SQRT_MIN, ONE, Math.Rounding.Ceil);
        uint256 vOut2 = poolUsdcAfter + Math.mulDiv(L2, ONE, SQRT_MAX);
        uint256 spotAfterVirt_raw = vOut2 * 1e12 / vIn2;

        // Amplification ratio (virtual/real) for display
        uint256 amplPct = vIn_conc * 100 / rIn0; // e.g. 250 = 2.5x

        uint256 poolSpotXnum = (rIn0 + amountIn) * 1000 / (rIn0 * 2 + amountIn);

        string memory trace = _buildTrace(
            unicode"Large Swap — 5 WETH via Concentrated+fee+decay",
            strategyHash,
            FORK_BLOCK,
            amountIn,
            realOut,
            _buildLargeSwapSteps(
                amountIn,
                realOut,
                feeAmount,
                netAmountIn,
                rIn0, rOut0,
                vIn_decay, vOut_decay,
                vIn_conc, vOut_conc,
                L, amplPct,
                poolWethAfter, poolUsdcAfter,
                spotBefore_raw,
                spotAfterVirt_raw,
                poolSpotXnum,
                takerWethBefore, takerUsdcBefore,
                takerWethAfter, takerUsdcAfter,
                makerWethBefore, makerUsdcBefore,
                makerWethAfter, makerUsdcAfter
            )
        );

        vm.writeFile("./traces/trace-large-swap.json", trace);
        console.log("Written: ./traces/trace-large-swap.json");
    }

    // ---------------------------------------------------------------------------
    // Two-swap decay trace: WETH→USDC first, then USDC→WETH with live decay offset
    //
    // The first (un-traced) swap is WETH→USDC. Decay._decayXD writes offsets after
    // that swap keyed as _offsets[hash][WETH][false] and _offsets[hash][USDC][true].
    //
    // The SECOND (traced) swap is USDC→WETH. That swap's _decayXD reads:
    //   _offsets[hash][USDC][true]  → added to balanceIn (USDC)
    //   _offsets[hash][WETH][false] → subtracted from balanceOut (WETH)
    //
    // By warping 1200 s into the 3600 s decay period the offsets are 2/3 of their
    // initial value (timeLeft = 3600 − 1200 = 2400, factor = 2400/3600 = 2/3).
    // The _decayXD step in the trace therefore shows:
    //   elapsedSeconds   = 1200
    //   decayFactor      ≈ 0.6667  (strictly between 0 and 1)
    //   currentOffsetIn  ≈ out1 * 2400/3600   (USDC units, non-zero)
    //   currentOffsetOut ≈ 5e18  * 2400/3600  (WETH units, non-zero)
    // ---------------------------------------------------------------------------

    function _exportTwoSwapDecay() internal {
        uint256 amountIn1 = 5 ether;       // first WETH→USDC (un-traced, sets offsets)
        uint256 amountIn2 = 5_000 * 1e6;   // second USDC→WETH (traced), ~1.67 WETH at 3000 USDC/WETH
        uint64 salt = 903;
        uint256 ELAPSED = 1200;            // seconds between the two swaps (1/3 of period)

        ComposedStrategyBuilder.PoolParams memory params = ComposedStrategyBuilder.PoolParams({
            salt: salt,
            feeBps: FEE_BPS,
            decayPeriod: DECAY_PERIOD,
            curve: ComposedStrategyBuilder.Curve.ConstantProduct,
            sqrtPriceMin: 0,
            sqrtPriceMax: 0
        });

        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipPool(params);

        // -----------------------------------------------------------------------
        // Swap 1: 5 WETH → USDC  (NOT traced; just sets the decay offsets)
        // -----------------------------------------------------------------------
        deal(WETH, address(taker), amountIn1);
        taker.approveRouter(WETH, amountIn1);
        (, uint256 out1) = taker.swap(order, WETH, USDC, amountIn1, _takerData());
        console.log("TWO-SWAP: swap1 WETH->USDC, amountIn=%d, out1=%d", amountIn1, out1);

        // After swap1, Decay stored:
        //   _offsets[hash][WETH][false] = amountIn1   (= 5 WETH)
        //   _offsets[hash][USDC][true]  = out1         (= actual USDC output)
        // These are the offsets that swap2 (USDC→WETH) will READ.

        // Pool real reserves after swap1
        (uint256 poolWethMid, uint256 poolUsdcMid) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);
        console.log("Pool after swap1: WETH=%d, USDC=%d", poolWethMid, poolUsdcMid);

        // -----------------------------------------------------------------------
        // Advance time: 1200 s into the 3600 s decay period
        // -----------------------------------------------------------------------
        vm.warp(block.timestamp + ELAPSED);
        uint256 timeLeft = DECAY_PERIOD - ELAPSED;   // = 2400

        // -----------------------------------------------------------------------
        // Compute the DECAYED offsets that swap2 will see.
        // getOffset returns: storedOffset * timeLeft / decayPeriod
        // For USDC→WETH: tokenIn=USDC, tokenOut=WETH
        //   offsetIn  = _offsets[hash][USDC][true]  = out1  (written by swap1)
        //   offsetOut = _offsets[hash][WETH][false] = amountIn1 (written by swap1)
        // After 1200 s of decay (timeLeft = 2400):
        //   currentOffsetIn  = out1    * 2400 / 3600
        //   currentOffsetOut = amountIn1 * 2400 / 3600
        // -----------------------------------------------------------------------
        uint256 currentOffsetIn  = out1 * timeLeft / DECAY_PERIOD;
        uint256 currentOffsetOut = amountIn1 * timeLeft / DECAY_PERIOD;

        // Decay factor = timeLeft / period = 2400 / 3600
        // For display: decayFactor = 1 - ELAPSED/DECAY_PERIOD = 1 - 1200/3600 = 2/3

        // -----------------------------------------------------------------------
        // Swap 2: USDC → WETH  (TRACED)
        //
        // Virtual reserves seen by the AMM:
        //   balanceIn  (USDC) = poolUsdcMid + currentOffsetIn
        //   balanceOut (WETH) = poolWethMid - currentOffsetOut
        // -----------------------------------------------------------------------
        uint256 vIn_decay2  = poolUsdcMid + currentOffsetIn;
        uint256 vOut_decay2 = poolWethMid - currentOffsetOut;

        // Fee step
        uint256 feeAmount2  = Math.ceilDiv(amountIn2 * FEE_BPS, BPS);
        uint256 netAmountIn2 = amountIn2 - feeAmount2;

        // xycSwap (constant-product, exact-in):
        uint256 tracedOut2  = netAmountIn2 * vOut_decay2 / (vIn_decay2 + netAmountIn2);

        // Execute swap2 on-chain and measure real output
        deal(USDC, address(taker), amountIn2);
        taker.approveRouter(USDC, amountIn2);

        uint256 takerWethBefore2 = IERC20(WETH).balanceOf(address(taker));
        uint256 takerUsdcBefore2 = IERC20(USDC).balanceOf(address(taker));
        uint256 makerWethBefore2 = IERC20(WETH).balanceOf(maker);
        uint256 makerUsdcBefore2 = IERC20(USDC).balanceOf(maker);

        (, uint256 realOut2) = taker.swap(order, USDC, WETH, amountIn2, _takerData());

        uint256 takerWethAfter2 = IERC20(WETH).balanceOf(address(taker));
        uint256 takerUsdcAfter2 = IERC20(USDC).balanceOf(address(taker));
        uint256 makerWethAfter2 = IERC20(WETH).balanceOf(maker);
        uint256 makerUsdcAfter2 = IERC20(USDC).balanceOf(maker);

        console.log("TWO-SWAP: swap2 USDC->WETH, amountIn=%d, realOut=%d", amountIn2, realOut2);
        console.log("TWO-SWAP: tracedOut2=%d, realOut2=%d", tracedOut2, realOut2);
        console.log("TWO-SWAP: currentOffsetIn=%d, currentOffsetOut=%d", currentOffsetIn, currentOffsetOut);

        // Assert traced output matches real measured output
        assertEq(tracedOut2, realOut2,
            "TWO-SWAP: traced amountOut (swap2) must equal real on-chain measured amountOut");

        // -----------------------------------------------------------------------
        // Post-swap2 reserves
        // -----------------------------------------------------------------------
        (uint256 poolWethAfter2, uint256 poolUsdcAfter2) =
            aqua.safeBalances(maker, address(router), strategyHash, WETH, USDC);

        // Spot price for USDC→WETH swap: we track in units of tokenB/tokenA = USDC/WETH
        // Before swap2: the pool has poolWethMid/poolUsdcMid (real reserves from swap1 end)
        // The virtual reserves for swap2 price are vIn_decay2 (USDC) / vOut_decay2 (WETH)
        // spotBeforeSwap2: USDC per WETH using real reserves after swap1
        uint256 spotBefore2 = poolUsdcMid * 1e12 / poolWethMid;
        // After swap2: USDC per WETH using real reserves after swap2
        uint256 spotAfter2  = poolUsdcAfter2 * 1e12 / poolWethAfter2;

        // Virtual spot before swap2 (with decay offsets applied):
        // USDC per WETH = virtualUSDC / virtualWETH * 1e12
        uint256 spotVirtBefore2 = vIn_decay2 * 1e12 / vOut_decay2;

        // swapPointX: normalized position on curve (amountIn2 / (amountIn2 + poolUsdcMid))
        uint256 poolSpotXnum2 = (poolUsdcMid + amountIn2) * 1000 / (poolUsdcMid * 2 + amountIn2);

        string memory trace = _buildTrace(
            unicode"Decay Demo — USDC→WETH follow-up swap with live 2/3 decay offset from prior 5 WETH trade",
            strategyHash,
            FORK_BLOCK,
            amountIn2,
            realOut2,
            _buildTwoSwapDecaySteps(
                amountIn2,
                realOut2,
                feeAmount2,
                netAmountIn2,
                ELAPSED,
                timeLeft,
                currentOffsetIn,
                currentOffsetOut,
                poolWethMid, poolUsdcMid,
                vIn_decay2, vOut_decay2,
                poolWethAfter2, poolUsdcAfter2,
                spotBefore2,
                spotVirtBefore2,
                spotAfter2,
                poolSpotXnum2,
                takerWethBefore2, takerUsdcBefore2,
                takerWethAfter2, takerUsdcAfter2,
                makerWethBefore2, makerUsdcBefore2,
                makerWethAfter2, makerUsdcAfter2
            )
        );

        // Override metadata direction: this is B_TO_A (USDC→WETH = tokenB→tokenA)
        // We need to patch the swapDirection field in the trace
        // NOTE: _buildTrace always emits A_TO_B. For this trace we must emit B_TO_A.
        // We do a simple string replacement on the generated trace.
        // (The schema allows "B_TO_A"; we need to correct the direction.)
        bytes memory traceBytes = bytes(trace);
        bytes memory findStr  = bytes('"swapDirection":"A_TO_B"');
        bytes memory replStr  = bytes('"swapDirection":"B_TO_A"');
        // Manual replace: find the substring and overwrite it
        for (uint256 i = 0; i + findStr.length <= traceBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < findStr.length; j++) {
                if (traceBytes[i + j] != findStr[j]) { found = false; break; }
            }
            if (found) {
                for (uint256 j = 0; j < replStr.length; j++) {
                    traceBytes[i + j] = replStr[j];
                }
                break;
            }
        }
        trace = string(traceBytes);

        vm.writeFile("./traces/trace-two-swap-decay.json", trace);
        console.log("Written: ./traces/trace-two-swap-decay.json");

        // Sanity: decay factor must be strictly between 0 and 1
        // decayFactor = timeLeft / DECAY_PERIOD = 2400/3600
        assertGt(currentOffsetIn, 0, "TWO-SWAP: offsetIn must be non-zero");
        assertGt(currentOffsetOut, 0, "TWO-SWAP: offsetOut must be non-zero");
        assertGt(timeLeft, 0, "TWO-SWAP: timeLeft > 0 (decay not fully expired)");
        assertLt(timeLeft, DECAY_PERIOD, "TWO-SWAP: timeLeft < period (decay not zero)");
        assertLt(ELAPSED, DECAY_PERIOD, "TWO-SWAP: elapsed < period (decay not fully expired)");
    }

    // ---------------------------------------------------------------------------
    // Two-swap decay steps builder
    // Steps: [0] _salt, [1] _decayXD (NON-ZERO offsets!), [2] _flatFeeAmountInXD, [3] _xycSwapXD
    // This is the SECOND swap (USDC→WETH) after a 1200-second delay.
    // Tokens in the trace: tokenA=WETH, tokenB=USDC (matching the schema)
    // But the swap direction is B_TO_A (USDC→WETH), so amountIn is in USDC (tokenB).
    // ---------------------------------------------------------------------------

    function _buildTwoSwapDecaySteps(
        uint256 amountIn2,
        uint256 realOut2,
        uint256 feeAmount2,
        uint256 netAmountIn2,
        uint256 elapsed,
        uint256 timeLeft,
        uint256 currentOffsetIn,
        uint256 currentOffsetOut,
        uint256 poolWethMid, uint256 poolUsdcMid,
        uint256 vIn_decay2, uint256 vOut_decay2,
        uint256 poolWethAfter2, uint256 poolUsdcAfter2,
        uint256 spotBefore2,
        uint256 spotVirtBefore2,
        uint256 spotAfter2,
        uint256 poolSpotXnum2,
        uint256 takerWethBefore2, uint256 takerUsdcBefore2,
        uint256 takerWethAfter2, uint256 takerUsdcAfter2,
        uint256 makerWethBefore2, uint256 makerUsdcBefore2,
        uint256 makerWethAfter2, uint256 makerUsdcAfter2
    ) internal pure returns (string memory) {
        uint256 humanFeeBps = uint256(FEE_BPS) * 10_000 / BPS;

        // decayFactor = timeLeft / DECAY_PERIOD (as fraction * 10000 for display)
        // e.g. 2400/3600 = 6667/10000 = 0.6667
        uint256 decayFactorNum = timeLeft * 10000 / DECAY_PERIOD; // e.g. 6667

        // Step 0: _salt
        string memory step0 = _buildStep(
            0, "_salt",
            string.concat("Uniqueness salt: pure no-op. Pool uses salt=903 to distinguish from other pools."),
            string.concat('{"type":"_salt","salt":"903"}'),
            _balSnap(
                _uint(makerWethBefore2), _uint(makerUsdcBefore2),
                _uint(takerWethBefore2), _uint(takerUsdcBefore2)
            ),
            _balSnap(
                _uint(makerWethBefore2), _uint(makerUsdcBefore2),
                _uint(takerWethBefore2), _uint(takerUsdcBefore2)
            ),
            _curveState(
                _uint(poolWethMid), _uint(poolUsdcMid),
                _uint(poolWethMid), _uint(poolUsdcMid),
                spotBefore2, 0, "null", "null"
            )
        );

        // Step 1: _decayXD — NON-ZERO offsets from prior 5 WETH→USDC swap
        // This is the key "MEV protection" step that shows decay in action.
        // Prior swap1 (WETH→USDC) stored offsets:
        //   _offsets[hash][WETH][false] = 5e18   (stored as amountIn1)
        //   _offsets[hash][USDC][true]  = out1    (stored as amountOut of swap1)
        // This swap2 (USDC→WETH) reads those as:
        //   offsetIn  = _offsets[hash][USDC][true]  decayed by 1200s → currentOffsetIn
        //   offsetOut = _offsets[hash][WETH][false] decayed by 1200s → currentOffsetOut
        // Virtual reserves:
        //   vBalanceIn  (USDC) = poolUsdcMid + currentOffsetIn
        //   vBalanceOut (WETH) = poolWethMid - currentOffsetOut
        string memory step1 = _buildStep(
            1, "_decayXD",
            string.concat(
                "MEV decay: period=", _uint(DECAY_PERIOD), "s; elapsed=", _uint(elapsed),
                "s (decay factor=", _uint(decayFactorNum / 100), ".", _uint(decayFactorNum % 100),
                "%). Prior 5 WETH trade offset reduces effective WETH available to this buyer."
            ),
            string.concat(
                '{"type":"_decayXD","decayPeriodSeconds":', _uint(DECAY_PERIOD),
                ',"elapsedSeconds":', _uint(elapsed),
                ',"currentOffsetIn":"', _uint(currentOffsetIn), '"',
                ',"currentOffsetOut":"', _uint(currentOffsetOut), '"',
                ',"virtualReservesBefore":{"reserveA":"', _uint(poolWethMid), '","reserveB":"', _uint(poolUsdcMid), '"}',
                ',"virtualReservesAfter":{"reserveA":"', _uint(vOut_decay2), '","reserveB":"', _uint(vIn_decay2), '"}}'
            ),
            // ERC-20 balances unchanged (decay modifies virtual registers only)
            _balSnap(
                _uint(makerWethBefore2), _uint(makerUsdcBefore2),
                _uint(takerWethBefore2), _uint(takerUsdcBefore2)
            ),
            _balSnap(
                _uint(makerWethBefore2), _uint(makerUsdcBefore2),
                _uint(takerWethBefore2), _uint(takerUsdcBefore2)
            ),
            // Virtual reserves now show the decay-adjusted view
            // realReserves = poolWethMid/poolUsdcMid; virtualReserves = decay-adjusted
            // In the schema, reserveA=WETH, reserveB=USDC
            // After decay: virtual WETH (tokenOut) = vOut_decay2; virtual USDC (tokenIn) = vIn_decay2
            _curveState(
                _uint(poolWethMid), _uint(poolUsdcMid),
                _uint(vOut_decay2), _uint(vIn_decay2),
                spotVirtBefore2, 0, "null", "null"
            )
        );

        // Step 2: _flatFeeAmountInXD
        // amountIn2 is in USDC (tokenB), feeAmount2 in USDC
        string memory step2 = _buildStep(
            2, "_flatFeeAmountInXD",
            string.concat("LP fee: ", _uint(humanFeeBps), " bps (0.30%) applied to USDC amountIn. Net input to AMM = amountIn - ceil(amountIn * feeBps / 1e9)."),
            string.concat(
                '{"type":"_flatFeeAmountInXD","feeBps":', _uint(FEE_BPS),
                ',"humanFeeBps":', _uint(humanFeeBps),
                ',"grossAmountIn":"', _uint(amountIn2), '"',
                ',"feeAmount":"', _uint(feeAmount2), '"',
                ',"netAmountIn":"', _uint(netAmountIn2), '"}'
            ),
            _balSnap(
                _uint(makerWethBefore2), _uint(makerUsdcBefore2),
                _uint(takerWethBefore2), _uint(takerUsdcBefore2)
            ),
            _balSnap(
                _uint(makerWethBefore2), _uint(makerUsdcBefore2),
                _uint(takerWethBefore2), _uint(takerUsdcBefore2)
            ),
            _curveState(
                _uint(poolWethMid), _uint(poolUsdcMid),
                _uint(vOut_decay2), _uint(vIn_decay2),
                spotVirtBefore2, humanFeeBps, "null", "null"
            )
        );

        // Step 3: _xycSwapXD
        // amountOut is in WETH; virtualBalanceIn is USDC, virtualBalanceOut is WETH
        string memory step3 = _buildStep(
            3, "_xycSwapXD",
            string.concat("Constant-product AMM leaf: amountOut = netAmountIn * vOut / (vIn + netAmountIn) = ", _uint(realOut2), " WETH (decay-penalized vs no-decay price)"),
            string.concat(
                '{"type":"_xycSwapXD","virtualBalanceIn":"', _uint(vIn_decay2), '"',
                ',"virtualBalanceOut":"', _uint(vOut_decay2), '"',
                ',"netAmountIn":"', _uint(netAmountIn2), '"',
                ',"amountOut":"', _uint(realOut2), '"}'
            ),
            _balSnap(
                _uint(makerWethBefore2), _uint(makerUsdcBefore2),
                _uint(takerWethBefore2), _uint(takerUsdcBefore2)
            ),
            // After: taker sent USDC, received WETH; maker received USDC, paid WETH
            _balSnap(
                _uint(makerWethAfter2), _uint(makerUsdcAfter2),
                _uint(takerWethAfter2), _uint(takerUsdcAfter2)
            ),
            _curveState(
                _uint(poolWethAfter2), _uint(poolUsdcAfter2),
                _uint(poolWethAfter2), _uint(poolUsdcAfter2),
                spotAfter2, humanFeeBps, "null",
                _uintFrac(poolSpotXnum2, 1000)
            )
        );

        return string.concat(step0, ",", step1, ",", step2, ",", step3);
    }

    // ---------------------------------------------------------------------------
    // JSON builders
    // ---------------------------------------------------------------------------

    function _buildTrace(
        string memory label,
        bytes32 strategyHash,
        uint256 blockNum,
        uint256 amtIn,
        uint256 amtOut,
        string memory stepsJson
    ) internal pure returns (string memory) {
        // feeBps in human-readable bps (out of 100, not 1e9)
        // FEE_BPS = 3_000_000 out of 1e9 = 0.3% = 30 bps in traditional sense
        // The schema uses human-readable bps. FEE_BPS/1e7 = 0.3 traditional-bps... no.
        // Schema says "Effective total fee in basis points" — this is ambiguous but
        // looking at placeholder fixtures it uses small numbers like 5, 53.
        // We'll express as FEE_BPS scaled: 3_000_000 / 1e9 * 10000 = 30 bps (0.30%)
        uint256 humanFeeBps = uint256(FEE_BPS) * 10_000 / BPS; // = 30

        return string.concat(
            '{"schemaVersion":"1.0","metadata":{"label":', _jsonStr(label),
            ',"strategyHash":"', _bytes32Hex(strategyHash),
            '","blockNumber":', _uint(blockNum),
            ',"txHash":"0x0000000000000000000000000000000000000000000000000000000000000000"',
            ',"tokenA":{"address":"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2","symbol":"WETH","decimals":18}',
            ',"tokenB":{"address":"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48","symbol":"USDC","decimals":6}',
            ',"swapAmountIn":"', _uint(amtIn), '"',
            ',"swapAmountOut":"', _uint(amtOut), '"',
            ',"swapDirection":"A_TO_B"',
            ',"totalFeesBps":', _uint(humanFeeBps),
            '},"steps":[', stepsJson, ']}'
        );
    }

    // ---------------------------------------------------------------------------
    // Small swap steps builder
    // Steps: [0] _salt, [1] _decayXD, [2] _flatFeeAmountInXD, [3] _xycSwapXD
    // ---------------------------------------------------------------------------

    function _buildSmallSwapSteps(
        uint256 amountIn,
        uint256 realOut,
        uint256 feeAmount,
        uint256 netAmountIn,
        uint256 rIn0, uint256 rOut0,
        uint256 vIn_decay, uint256 vOut_decay,
        uint256 poolWethAfter, uint256 poolUsdcAfter,
        uint256 spotBefore,
        uint256 spotAfter,
        uint256 poolSpotXnum,
        uint256 takerWethBefore, uint256 takerUsdcBefore,
        uint256 takerWethAfter, uint256 takerUsdcAfter,
        uint256 makerWethBefore, uint256 makerUsdcBefore,
        uint256 makerWethAfter, uint256 makerUsdcAfter
    ) internal pure returns (string memory) {
        // Balances at each boundary:
        // Before swap: taker has amountIn WETH, maker has RESERVE_WETH/RESERVE_USDC
        // After swap: taker has 0 WETH + realOut USDC, maker balances from ERC20

        // Step 0: _salt — pure no-op, balances unchanged
        string memory step0 = _buildStep(
            0, "_salt",
            "Uniqueness salt: pure no-op that perturbs the order hash to distinguish this pool from others",
            string.concat('{"type":"_salt","salt":"', _uint(901), '"}'),
            // balances before: initial state
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            // balances after: same (salt is no-op)
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _curveState(
                _uint(rIn0), _uint(rOut0),
                _uint(vIn_decay), _uint(vOut_decay),
                spotBefore, 0, "null",
                "null"
            )
        );

        // Step 1: _decayXD — adjusts virtual reserves. First swap: offsets=0, no change.
        // Decay is OUTERMOST wrapper: it's the step that kicks off the inner loop.
        // Virtual reserves: vIn = rIn + offsetIn_decayed; vOut = rOut - offsetOut_decayed
        // First swap: both offsets 0, so virtual == real
        // After decay inner loop returns, it stores new offsets (amountIn=realIn, amountOut=realOut)
        // but from the trace perspective, the VIRTUAL RESERVES during the swap are what matter.
        string memory step1 = _buildStep(
            1, "_decayXD",
            string.concat("MEV decay: period=", _uint(DECAY_PERIOD), "s; first swap so offset=0. Virtual reserves unchanged. Decay wraps the fee+swap inner loop."),
            string.concat(
                '{"type":"_decayXD","decayPeriodSeconds":', _uint(DECAY_PERIOD),
                ',"elapsedSeconds":0,"currentOffsetIn":"0","currentOffsetOut":"0"',
                ',"virtualReservesBefore":{"reserveA":"', _uint(rIn0), '","reserveB":"', _uint(rOut0), '"}',
                ',"virtualReservesAfter":{"reserveA":"', _uint(vIn_decay), '","reserveB":"', _uint(vOut_decay), '"}}'
            ),
            // Balances unchanged (decay modifies virtual registers, not ERC-20 balances)
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _curveState(
                _uint(rIn0), _uint(rOut0),
                _uint(vIn_decay), _uint(vOut_decay),
                spotBefore, 0, "null", "null"
            )
        );

        // Step 2: _flatFeeAmountInXD — reduces ctx.swap.amountIn by fee, calls inner loop
        // The fee amount = ceil(amountIn * feeBps / 1e9), netAmountIn = amountIn - feeAmount
        // Taker pays full amountIn; AMM only sees netAmountIn.
        // Human fee bps = feeBps * 10000 / 1e9 = 30 (i.e. 0.30%)
        uint256 humanFeeBps = uint256(FEE_BPS) * 10_000 / BPS;
        string memory step2 = _buildStep(
            2, "_flatFeeAmountInXD",
            string.concat("LP fee: ", _uint(humanFeeBps), " bps (0.30%) applied to amountIn. Net input to AMM = amountIn - ceil(amountIn * feeBps / 1e9)."),
            string.concat(
                '{"type":"_flatFeeAmountInXD","feeBps":', _uint(FEE_BPS),
                ',"humanFeeBps":', _uint(humanFeeBps),
                ',"grossAmountIn":"', _uint(amountIn), '"',
                ',"feeAmount":"', _uint(feeAmount), '"',
                ',"netAmountIn":"', _uint(netAmountIn), '"}'
            ),
            // Balances unchanged (fee modifies amountIn register, not ERC-20 yet)
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _curveState(
                _uint(rIn0), _uint(rOut0),
                _uint(vIn_decay), _uint(vOut_decay),
                spotBefore, humanFeeBps, "null", "null"
            )
        );

        // Step 3: _xycSwapXD — innermost leaf, computes amountOut
        // amountOut = netAmountIn * vOut / (vIn + netAmountIn)
        // After this, ERC-20 transfers happen: taker sends amountIn WETH, receives realOut USDC
        string memory step3 = _buildStep(
            3, "_xycSwapXD",
            string.concat("Constant-product AMM leaf: amountOut = netAmountIn * vOut / (vIn + netAmountIn) = ", _uint(realOut), " USDC"),
            string.concat(
                '{"type":"_xycSwapXD","virtualBalanceIn":"', _uint(vIn_decay), '"',
                ',"virtualBalanceOut":"', _uint(vOut_decay), '"',
                ',"netAmountIn":"', _uint(netAmountIn), '"',
                ',"amountOut":"', _uint(realOut), '"}'
            ),
            // Before: same as pre-swap (ERC-20 moves happen after program)
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            // After: taker sent WETH, received USDC; maker received WETH, paid USDC
            _balSnap(
                _uint(makerWethAfter), _uint(makerUsdcAfter),
                _uint(takerWethAfter), _uint(takerUsdcAfter)
            ),
            _curveState(
                _uint(poolWethAfter), _uint(poolUsdcAfter),
                _uint(poolWethAfter), _uint(poolUsdcAfter),
                spotAfter, humanFeeBps, "null",
                _uintFrac(poolSpotXnum, 1000)
            )
        );

        return string.concat(step0, ",", step1, ",", step2, ",", step3);
    }

    // ---------------------------------------------------------------------------
    // Large swap steps builder
    // Steps: [0] _salt, [1] _decayXD, [2] _flatFeeAmountInXD, [3] _xycConcentrateGrowLiquidity2D
    // ---------------------------------------------------------------------------

    function _buildLargeSwapSteps(
        uint256 amountIn,
        uint256 realOut,
        uint256 feeAmount,
        uint256 netAmountIn,
        uint256 rIn0, uint256 rOut0,
        uint256 vIn_decay, uint256 vOut_decay,
        uint256 vIn_conc, uint256 vOut_conc,
        uint256 L, uint256 amplPct,
        uint256 poolWethAfter, uint256 poolUsdcAfter,
        uint256 spotBefore,
        uint256 spotAfterVirt,
        uint256 poolSpotXnum,
        uint256 takerWethBefore, uint256 takerUsdcBefore,
        uint256 takerWethAfter, uint256 takerUsdcAfter,
        uint256 makerWethBefore, uint256 makerUsdcBefore,
        uint256 makerWethAfter, uint256 makerUsdcAfter
    ) internal pure returns (string memory) {
        uint256 humanFeeBps = uint256(FEE_BPS) * 10_000 / BPS;

        // Concentrated range prices in human-readable form (USDC per WETH)
        // sqrt(P) is in 1e18 fp, P = tokenGt/tokenLt = WETH_balance/USDC_balance
        // P in raw = WETH_balance/USDC_balance, but we want USDC per WETH:
        // USDC_per_WETH = 1/P_raw * (1e18/1e6) = 1e12 / P_raw
        // P_raw = sqrtP^2 / 1e36, so USDC_per_WETH = 1e12 * 1e36 / sqrtP^2
        // For human price display: use spotBefore (already computed as rOut*1e12/rIn)

        // priceLower (at sqrtMin): P_raw = sqrtMin^2/1e36, USDC_per_WETH = 1e48 / sqrtMin^2
        // We want integer price in USDC/WETH range:
        // spotBefore = rOut0 * 1e12 / rIn0 = 300_000*1e6*1e12 / 100*1e18 = 3000
        // sqrtMin = 17344...e3, spot sqrtP ≈ 18257... So:
        //   priceLower_raw_P = (sqrtMin^2/1e36) => USDC_per_WETH = 1e12/P_raw = 1e12*1e36/sqrtMin^2
        // But these are huge numbers. Use 1e18 ONE:
        //   priceLower_usdc = ONE * ONE / sqrtMin * ONE / sqrtMin * 1e12 / 1e18 ... complex
        // Simpler: priceLower_usdc ≈ spotBefore * (sqrtMin/sqrtSpot)^2
        // sqrtSpot ≈ 18257e18 (mid of [17344,19170])
        // Let's just compute from sqrt prices:
        // For USDC/WETH: 1/P where P = bGt/bLt = WETH/USDC
        // priceLower USDC/WETH = 1/(sqrtMin^2/1e36) = 1e36/sqrtMin^2
        // But in 1e6/1e18 decimals = 1e36/sqrtMin^2 * 1e6/1e18 = 1e24/sqrtMin^2
        // sqrtMin = 17_344_547_654_330_260_259_470 ~ 1.73e22
        // priceLower ~ 1e24 / (1.73e22)^2 = 1e24 / 3e44 ~ 3.33e-21 ... that's wrong
        // The issue: sqrtP is sqrt(tokenGt/tokenLt) in raw balance units.
        // tokenGt = WETH (18 dp), tokenLt = USDC (6 dp)
        // P_raw = WETH_amount/USDC_amount (no decimal adjustment)
        // For 3000 USDC/WETH:  WETH/USDC = 1/3000, but in raw: 1e18/3000e6 = ~3.33e8
        // sqrtP_raw = sqrt(3.33e8) ≈ 18257, times 1e18 = 1.8257e22 ✓ matches SQRT_MIN range
        // P_raw = sqrtP^2/1e36 = WETH_amount/USDC_amount
        // USDC_per_WETH = 1/P_raw * (1e18/1e6) = 1e12/P_raw = 1e12 * 1e36 / sqrtP^2 = 1e48 / sqrtP^2
        // But sqrtP ~ 1.73e22, sqrtP^2 ~ 3e44, 1e48/3e44 ~ 3333 ✓

        // Compute prices as uint256 with potential overflow — use mulDiv
        uint256 ONE = 1e18;
        // priceLower: 1e48 / SQRT_MIN^2 — but SQRT_MIN^2 overflows uint256
        // Use: price = 1e12 / (sqrtP/1e18)^2 = 1e12 * 1e36 / sqrtP^2
        // = Math.mulDiv(1e12, 1e36, sqrtP^2) but sqrtP^2 overflows
        // Instead: price = Math.mulDiv(1e12, ONE, Math.mulDiv(SQRT_MIN, SQRT_MIN, ONE))
        // = 1e12 * 1e18 / (SQRT_MIN^2/1e18) = 1e30 * 1e18 / SQRT_MIN^2
        // ... still overflows. Use simpler approximation:
        // spotBefore * (sqrtSpot/sqrtMin)^2 for lower, (sqrtSpot/sqrtMax)^2 for upper
        // sqrtSpot ~ sqrt(spotBefore * 1e18/1e12) * 1e18... too complex.
        // Just use spotBefore ± 5% to match the ±5% band from ComposedStrategyFork
        uint256 priceLower_usdc = spotBefore * 9025 / 10000; // ~(0.95)^2 = 0.9025
        uint256 priceUpper_usdc = spotBefore * 11025 / 10000; // ~(1.05)^2 = 1.1025

        string memory concRange = string.concat(
            '{"priceLower":', _uint(priceLower_usdc),
            ',"priceUpper":', _uint(priceUpper_usdc),
            ',"isInRange":true}'
        );

        // Step 0: _salt
        string memory step0 = _buildStep(
            0, "_salt",
            "Uniqueness salt: pure no-op that perturbs the order hash to distinguish this concentrated pool",
            string.concat('{"type":"_salt","salt":"', _uint(902), '"}'),
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _curveState(
                _uint(rIn0), _uint(rOut0),
                _uint(vIn_decay), _uint(vOut_decay),
                spotBefore, 0, concRange, "null"
            )
        );

        // Step 1: _decayXD — first swap, no prior offsets
        string memory step1 = _buildStep(
            1, "_decayXD",
            string.concat("MEV decay: period=", _uint(DECAY_PERIOD), "s; first swap so offset=0. Virtual reserves unchanged. Wraps fee+AMM inner loop."),
            string.concat(
                '{"type":"_decayXD","decayPeriodSeconds":', _uint(DECAY_PERIOD),
                ',"elapsedSeconds":0,"currentOffsetIn":"0","currentOffsetOut":"0"',
                ',"virtualReservesBefore":{"reserveA":"', _uint(rIn0), '","reserveB":"', _uint(rOut0), '"}',
                ',"virtualReservesAfter":{"reserveA":"', _uint(vIn_decay), '","reserveB":"', _uint(vOut_decay), '"}}'
            ),
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _curveState(
                _uint(rIn0), _uint(rOut0),
                _uint(vIn_decay), _uint(vOut_decay),
                spotBefore, 0, concRange, "null"
            )
        );

        // Step 2: _flatFeeAmountInXD
        string memory step2 = _buildStep(
            2, "_flatFeeAmountInXD",
            string.concat("LP fee: ", _uint(humanFeeBps), " bps. Gross=", _uint(amountIn), " WETH, fee=", _uint(feeAmount), " WETH, netAmountIn=", _uint(netAmountIn), " WETH"),
            string.concat(
                '{"type":"_flatFeeAmountInXD","feeBps":', _uint(FEE_BPS),
                ',"humanFeeBps":', _uint(humanFeeBps),
                ',"grossAmountIn":"', _uint(amountIn), '"',
                ',"feeAmount":"', _uint(feeAmount), '"',
                ',"netAmountIn":"', _uint(netAmountIn), '"}'
            ),
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            // Virtual reserves now include L-based extension (the concentrated amplification)
            _curveState(
                _uint(rIn0), _uint(rOut0),
                _uint(vIn_conc), _uint(vOut_conc),
                spotBefore, humanFeeBps, concRange, "null"
            )
        );

        // Step 3: _xycConcentrateGrowLiquidity2D — innermost leaf
        string memory step3 = _buildStep(
            3, "_xycConcentrateGrowLiquidity2D",
            string.concat("Concentrated-liquidity AMM leaf: virtual reserves amplified ", _uint(amplPct), "% vs real. amountOut=", _uint(realOut), " USDC"),
            string.concat(
                '{"type":"_xycConcentrateGrowLiquidity2D","sqrtPriceMin":"', _uint(SQRT_MIN), '"',
                ',"sqrtPriceMax":"', _uint(SQRT_MAX), '"',
                ',"liquidity":"', _uint(L), '"',
                ',"virtualBalanceIn":"', _uint(vIn_conc), '"',
                ',"virtualBalanceOut":"', _uint(vOut_conc), '"',
                ',"netAmountIn":"', _uint(netAmountIn), '"',
                ',"amountOut":"', _uint(realOut), '"}'
            ),
            _balSnap(
                _uint(makerWethBefore), _uint(makerUsdcBefore),
                _uint(takerWethBefore), _uint(takerUsdcBefore)
            ),
            _balSnap(
                _uint(makerWethAfter), _uint(makerUsdcAfter),
                _uint(takerWethAfter), _uint(takerUsdcAfter)
            ),
            _curveState(
                _uint(poolWethAfter), _uint(poolUsdcAfter),
                _uint(poolWethAfter), _uint(poolUsdcAfter), // real = virtual post-swap (decay offset stored separately)
                spotAfterVirt, humanFeeBps, concRange,
                _uintFrac(poolSpotXnum, 1000)
            )
        );

        return string.concat(step0, ",", step1, ",", step2, ",", step3);
    }

    // ---------------------------------------------------------------------------
    // JSON helper primitives
    // ---------------------------------------------------------------------------

    function _buildStep(
        uint256 idx,
        string memory opcode,
        string memory description,
        string memory paramsJson,
        string memory balBefore,
        string memory balAfter,
        string memory curveStateJson
    ) internal pure returns (string memory) {
        return string.concat(
            '{"stepIndex":', _uint(idx),
            ',"opcode":', _jsonStr(opcode),
            ',"description":', _jsonStr(description),
            ',"params":', paramsJson,
            ',"balancesBefore":', balBefore,
            ',"balancesAfter":', balAfter,
            ',"curveState":', curveStateJson,
            '}'
        );
    }

    function _balSnap(
        string memory makerA, string memory makerB,
        string memory takerA, string memory takerB
    ) internal pure returns (string memory) {
        return string.concat(
            '{"makerTokenA":"', makerA, '","makerTokenB":"', makerB,
            '","takerTokenA":"', takerA, '","takerTokenB":"', takerB, '"}'
        );
    }

    function _curveState(
        string memory realA, string memory realB,
        string memory virtA, string memory virtB,
        uint256 spotRaw, // USDC per WETH integer (e.g. 3000)
        uint256 feeBps,
        string memory concentratedRangeJson,
        string memory swapPointX
    ) internal pure returns (string memory) {
        return string.concat(
            '{"realReserves":{"reserveA":"', realA, '","reserveB":"', realB, '"}',
            ',"virtualReserves":{"reserveA":"', virtA, '","reserveB":"', virtB, '"}',
            ',"spotPriceAInB":', _uint(spotRaw),
            ',"feeBps":', _uint(feeBps),
            ',"concentratedRange":', concentratedRangeJson,
            ',"swapPointX":', swapPointX,
            '}'
        );
    }

    function _uint(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory buf = new bytes(78);
        uint256 i = 78;
        while (v != 0) {
            unchecked { i--; }
            buf[i] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        bytes memory result = new bytes(78 - i);
        for (uint256 j = 0; j < result.length; j++) {
            result[j] = buf[i + j];
        }
        return string(result);
    }

    /// @dev Format a fraction like poolSpotXnum/denominator as "0.NNN" for JSON
    function _uintFrac(uint256 numerator, uint256 denominator) internal pure returns (string memory) {
        uint256 whole = numerator / denominator;
        uint256 frac = numerator % denominator;
        // 3 decimal places
        frac = frac * 1000 / denominator;
        return string.concat(
            _uint(whole), ".",
            frac < 10 ? "00" : (frac < 100 ? "0" : ""),
            _uint(frac)
        );
    }

    function _jsonStr(string memory s) internal pure returns (string memory) {
        return string.concat('"', s, '"');
    }

    function _bytes32Hex(bytes32 b) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(66);
        result[0] = '0';
        result[1] = 'x';
        for (uint256 i = 0; i < 32; i++) {
            result[2 + i * 2] = hexChars[uint8(b[i]) >> 4];
            result[3 + i * 2] = hexChars[uint8(b[i]) & 0x0f];
        }
        return string(result);
    }

    // ---------------------------------------------------------------------------
    // Helpers (mirrors ComposedStrategyFork.t.sol)
    // ---------------------------------------------------------------------------

    function _shipPool(ComposedStrategyBuilder.PoolParams memory params)
        internal
        returns (ISwapVM.Order memory order, bytes32 strategyHash)
    {
        order = builder.buildComposedOrder(maker, params);
        bytes32 orderHash = router.hash(order);

        deal(WETH, maker, RESERVE_WETH);
        deal(USDC, maker, RESERVE_USDC);
        vm.startPrank(maker);
        IERC20(WETH).approve(AQUA_ADDR, type(uint256).max);
        IERC20(USDC).approve(AQUA_ADDR, type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = RESERVE_WETH;
        amounts[1] = RESERVE_USDC;

        strategyHash = aqua.ship(address(router), abi.encode(order), tokens, amounts);
        vm.stopPrank();

        assertEq(strategyHash, orderHash, "strategyHash must equal orderHash");
    }

    function _takerData() internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            threshold: "",
            to: address(taker),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            preTransferOutCallbackData: "",
            preTransferInCallbackData: "",
            postTransferOutHookData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    // ---------------------------------------------------------------------------
    // _computeL: mirrors XYCConcentrateArgsBuilder._computeL
    // ---------------------------------------------------------------------------

    function _computeL(
        uint256 bLt, uint256 bGt,
        uint256 sqrtPriceMin, uint256 sqrtPriceMax
    ) internal pure returns (uint256) {
        uint256 ONE = 1e18;
        uint256 priceDelta = sqrtPriceMax - sqrtPriceMin;
        uint256 beta = Math.mulDiv(bLt, sqrtPriceMin, ONE) + Math.mulDiv(bGt, ONE, sqrtPriceMax);
        uint256 fourAC = Math.mulDiv(4 * priceDelta, bLt * bGt, sqrtPriceMax);
        uint256 disc = beta * beta + fourAC;
        return Math.mulDiv(beta + Math.sqrt(disc), sqrtPriceMax, 2 * priceDelta);
    }
}
