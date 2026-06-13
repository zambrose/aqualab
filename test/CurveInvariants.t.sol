// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { XYCConcentrateArgsBuilder } from "@1inch/swap-vm/src/instructions/XYCConcentrate.sol";

import { ComposedStrategyBuilder } from "../src/ComposedStrategyBuilder.sol";

/// @title CurveInvariants
/// @notice Pure / fuzz property tests on the AMM curve + fee + decay MATH, with NO
///         mainnet fork (so they run fast and don't hit the RPC). Each helper here
///         mirrors, line-for-line, the formula in the corresponding vendored
///         instruction — the invariant being proven is named in the test.
///
///         The vendored sources these mirror:
///           - XYCSwap._xycSwapXD                         (constant product)
///           - Fee._flatFeeAmountInXD / progressiveFeeBps (fee monotonicity)
///           - Decay.DecayingOffsetLib.getOffset          (decay monotonicity)
///           - XYCConcentrate._xycConcentrateGrowLiquidity2D + ArgsBuilder
///             (price stays inside the configured band)
contract CurveInvariantsTest is Test {
    uint256 internal constant BPS = 1e9;
    uint256 internal constant ONE = 1e18; // concentrate fixed-point base

    ComposedStrategyBuilder internal builder;

    function setUp() public {
        // No fork — the builder is only used for its pure progressiveFeeBps().
        builder = new ComposedStrategyBuilder(address(0));
    }

    // =====================================================================
    // Invariant 1: constant-product k is NON-DECREASING across a swap.
    //   out = amtIn*balOut / (balIn+amtIn)   (floor, exact-in)  [XYCSwap]
    //   ⇒ (balIn+amtIn)*(balOut-out) >= balIn*balOut
    // The floor in `out` always rounds in the pool's favour, so k only grows.
    // =====================================================================
    function testFuzz_ConstantProduct_KNonDecreasing(
        uint256 balIn,
        uint256 balOut,
        uint256 amtIn
    ) public pure {
        // Bound to realistic, overflow-safe ranges.
        balIn = bound(balIn, 1e6, 1e30);
        balOut = bound(balOut, 1e6, 1e30);
        amtIn = bound(amtIn, 1, 1e28);

        uint256 out = amtIn * balOut / (balIn + amtIn); // mirrors _xycSwapXD exact-in
        assertLe(out, balOut, "cannot output more than the reserve");

        uint256 kBefore = balIn * balOut;
        uint256 kAfter = (balIn + amtIn) * (balOut - out);
        assertGe(kAfter, kBefore, "constant-product k must never decrease");
    }

    // =====================================================================
    // Invariant 2: a flat fee on amountIn only ever REDUCES the output (the
    //   maker keeps the fee). Mirrors Fee._flatFeeAmountInXD exact-in:
    //   netIn = amtIn - ceil(amtIn*feeBps/BPS); out = swap(netIn).
    // =====================================================================
    function testFuzz_FlatFee_ReducesOutput(
        uint256 balIn,
        uint256 balOut,
        uint256 amtIn,
        uint32 feeBps
    ) public pure {
        balIn = bound(balIn, 1e6, 1e30);
        balOut = bound(balOut, 1e6, 1e30);
        amtIn = bound(amtIn, 1, 1e28);
        feeBps = uint32(bound(feeBps, 0, BPS - 1));

        uint256 outNoFee = amtIn * balOut / (balIn + amtIn);

        uint256 netIn = amtIn - Math.ceilDiv(amtIn * feeBps, BPS);
        uint256 outWithFee = netIn * balOut / (balIn + netIn);

        assertLe(outWithFee, outNoFee, "fee must never increase output");
    }

    // =====================================================================
    // Invariant 3: progressiveFeeBps is MONOTONICALLY NON-DECREASING in size.
    //   bigger trade ⇒ fee rate is >= the rate of any smaller trade.
    //   (The documented stand-in for the missing _progressiveFeeInXD opcode.)
    // =====================================================================
    function testFuzz_ProgressiveFee_MonotonicInSize(
        uint256 a,
        uint256 b,
        uint256 small,
        uint256 large,
        uint32 baseFee,
        uint32 midFee,
        uint32 highFee
    ) public view {
        // A well-formed, non-decreasing schedule.
        small = bound(small, 1, 1e24);
        large = bound(large, small, 1e30);
        baseFee = uint32(bound(baseFee, 0, BPS / 3));
        midFee = uint32(bound(midFee, baseFee, (2 * BPS) / 3));
        highFee = uint32(bound(highFee, midFee, BPS));

        // Two sizes with a <= b must yield fee(a) <= fee(b).
        a = bound(a, 0, 1e30);
        b = bound(b, a, 1e30);

        uint32 feeA = builder.progressiveFeeBps(a, small, large, baseFee, midFee, highFee);
        uint32 feeB = builder.progressiveFeeBps(b, small, large, baseFee, midFee, highFee);

        assertLe(feeA, feeB, "fee rate must be non-decreasing in trade size");
    }

    // =====================================================================
    // Invariant 4: the decaying offset is MONOTONICALLY NON-INCREASING in time
    //   and hits zero at expiry. Mirrors DecayingOffsetLib.getOffset:
    //   offset(t) = offset0 * (expiry - t) / period   for t < expiry, else 0.
    // =====================================================================
    function testFuzz_Decay_MonotonicInTime(
        uint256 offset0,
        uint256 period,
        uint256 t0Elapsed,
        uint256 dt
    ) public pure {
        offset0 = bound(offset0, 1, type(uint216).max);
        period = bound(period, 1, type(uint16).max);
        t0Elapsed = bound(t0Elapsed, 0, period); // time since the offset was set
        dt = bound(dt, 0, period); // extra time we then advance

        uint256 offAtT0 = _decayedOffset(offset0, period, t0Elapsed);
        uint256 offAtT1 = _decayedOffset(offset0, period, t0Elapsed + dt);

        assertLe(offAtT1, offAtT0, "decay offset must be non-increasing in time");
        // At/after expiry it is exactly zero.
        if (t0Elapsed >= period) {
            assertEq(offAtT0, 0, "offset is fully decayed at/after expiry");
        }
    }

    /// @dev offset(elapsed) per DecayingOffsetLib.getOffset.
    function _decayedOffset(uint256 offset0, uint256 period, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        if (elapsed >= period) return 0;
        uint256 timeLeft = period - elapsed;
        return offset0 * timeLeft / period;
    }

    // =====================================================================
    // Invariant 5: for reserves consistent with a price band, the concentrated
    //   curve's implied spot price stays INSIDE [sqrtPmin, sqrtPmax].
    //   Uses the vendored XYCConcentrateArgsBuilder.computeLiquidityAndPrice.
    // =====================================================================
    function testFuzz_Concentrated_PriceInRange(
        uint256 balLt,
        uint256 balGt,
        uint256 sqrtMin,
        uint256 sqrtMax
    ) public pure {
        // Bounds chosen to stay overflow-safe inside _computeL (which forms
        // bLt*bGt and beta^2); keep sqrt-prices in a 1e18-fp band and balances
        // moderate. These ranges comfortably cover the WETH/USDC pool we ship.
        balLt = bound(balLt, 1e6, 1e24);
        balGt = bound(balGt, 1e6, 1e24);
        sqrtMin = bound(sqrtMin, 1e15, 1e21);
        sqrtMax = bound(sqrtMax, sqrtMin + 1e14, sqrtMin + 1e21);

        (uint256 L, uint256 sqrtSpot) =
            XYCConcentrateArgsBuilder.computeLiquidityAndPrice(balLt, balGt, sqrtMin, sqrtMax);

        assertGt(L, 0, "non-degenerate liquidity");
        // The implied spot must lie within the configured band (allowing the
        // boundary — a single-sided band sits the spot exactly on an edge).
        assertGe(sqrtSpot, sqrtMin, "spot >= P_min (in range, lower edge)");
        assertLe(sqrtSpot, sqrtMax, "spot <= P_max (in range, upper edge)");
    }
}
