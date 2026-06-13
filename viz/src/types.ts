/**
 * TypeScript types matching trace.schema.json v1.0
 *
 * Real opcode names used by AquaOpcodes (as discovered by Agent 2):
 *   _salt                          — uniqueness no-op (Controls._salt, index 21)
 *   _decayXD                       — MEV decay wrapper (Decay._decayXD, index 20)
 *   _flatFeeAmountInXD             — LP fee wrapper (Fee._flatFeeAmountInXD, index 22)
 *   _xycSwapXD                     — constant-product AMM leaf (XYCSwap._xycSwapXD, index 18)
 *   _xycConcentrateGrowLiquidity2D — concentrated-liquidity AMM leaf (XYCConcentrate, index 19)
 */

export interface TokenInfo {
  address: string;
  symbol: string;
  decimals: number;
}

export interface TraceMetadata {
  strategyHash: string;
  blockNumber: number;
  txHash: string;
  tokenA: TokenInfo;
  tokenB: TokenInfo;
  swapAmountIn: string;
  swapAmountOut: string;
  swapDirection: 'A_TO_B' | 'B_TO_A';
  totalFeesBps: number;
  label?: string;
}

export interface BalanceSnapshot {
  makerTokenA: string;
  makerTokenB: string;
  takerTokenA: string;
  takerTokenB: string;
}

export interface ReservePair {
  reserveA: string;
  reserveB: string;
}

export interface ConcentratedRange {
  priceLower: number;
  priceUpper: number;
  isInRange: boolean;
}

export interface CurveState {
  realReserves: ReservePair;
  virtualReserves: ReservePair;
  spotPriceAInB: number;
  feeBps: number;
  concentratedRange: ConcentratedRange | null;
  swapPointX: number | null;
}

// --- Per-opcode param shapes (real AquaOpcodes names) ---

/** Controls._salt — pure no-op that perturbs the order hash for uniqueness. */
export interface ParamsSalt {
  type: '_salt';
  salt: string; // uint64 as bigint string
}

/**
 * Decay._decayXD — MEV / size protection wrapper.
 * Linear decay: offset = storedOffset * timeLeft / decayPeriod.
 * Adjusts ctx.swap.balanceIn += offsetIn, ctx.swap.balanceOut -= offsetOut.
 * Then calls ctx.runLoop() for the inner instructions, and records new offsets.
 */
export interface ParamsDecayXD {
  type: '_decayXD';
  decayPeriodSeconds: number;
  elapsedSeconds: number;
  currentOffsetIn: string;   // bigint: decayed offsetIn added to balanceIn
  currentOffsetOut: string;  // bigint: decayed offsetOut subtracted from balanceOut
  virtualReservesBefore: ReservePair;
  virtualReservesAfter: ReservePair;
}

/**
 * Fee._flatFeeAmountInXD — LP flat-fee wrapper.
 * Exact-in: reduces ctx.swap.amountIn by ceil(amountIn * feeBps / 1e9),
 * calls inner loop, then restores original amountIn. Fee stays with the maker.
 */
export interface ParamsFlatFeeAmountInXD {
  type: '_flatFeeAmountInXD';
  feeBps: number;       // SwapVM units (1e9 = 100%), e.g. 3_000_000 = 0.30%
  humanFeeBps: number;  // traditional bps (out of 10000), e.g. 30 = 0.30%
  grossAmountIn: string;
  feeAmount: string;
  netAmountIn: string;
}

/**
 * XYCSwap._xycSwapXD — constant-product AMM leaf.
 * Exact-in: amountOut = netAmountIn * virtualBalanceOut / (virtualBalanceIn + netAmountIn)
 */
export interface ParamsXycSwapXD {
  type: '_xycSwapXD';
  virtualBalanceIn: string;
  virtualBalanceOut: string;
  netAmountIn: string;
  amountOut: string;
}

/**
 * XYCConcentrate._xycConcentrateGrowLiquidity2D — concentrated-liquidity AMM leaf.
 * Virtual reserves = real reserves + L-based extension within [sqrtPriceMin, sqrtPriceMax].
 * Exact-in: amountOut = netAmountIn * virtualBalanceOut / (virtualBalanceIn + netAmountIn)
 */
export interface ParamsXycConcentrateGrowLiquidity2D {
  type: '_xycConcentrateGrowLiquidity2D';
  sqrtPriceMin: string;   // sqrt(P_min) in 1e18 fp, P = tokenGt/tokenLt
  sqrtPriceMax: string;   // sqrt(P_max) in 1e18 fp
  liquidity: string;      // computed L value
  virtualBalanceIn: string;
  virtualBalanceOut: string;
  netAmountIn: string;
  amountOut: string;
}

export interface ParamsGeneric {
  type: string;
  [key: string]: unknown;
}

export type OpcodeParams =
  | ParamsSalt
  | ParamsDecayXD
  | ParamsFlatFeeAmountInXD
  | ParamsXycSwapXD
  | ParamsXycConcentrateGrowLiquidity2D
  | ParamsGeneric;

export interface TraceStep {
  stepIndex: number;
  opcode: string;
  description: string;
  params: OpcodeParams;
  balancesBefore: BalanceSnapshot;
  balancesAfter: BalanceSnapshot;
  curveState: CurveState;
  gasUsed?: number;
  revertReason?: string | null;
}

export interface Trace {
  schemaVersion: '1.0';
  metadata: TraceMetadata;
  steps: TraceStep[];
}
