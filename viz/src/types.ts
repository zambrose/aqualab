/**
 * TypeScript types matching trace.schema.json v1.0
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

// --- Per-opcode param shapes ---

export interface ParamsBalanceSetup {
  type: 'BALANCE_SETUP';
  makerDeposit: { token: 'tokenA' | 'tokenB'; amount: string };
  takerDeposit: { token: 'tokenA' | 'tokenB'; amount: string };
}

export interface ParamsXycConcentrateGrowLiquidityXD {
  type: '_xycConcentrateGrowLiquidityXD';
  lowerTick: number;
  upperTick: number;
  currentTick: number;
  liquidity: string;
  sqrtPriceX96: string;
  amountSpecified: string;
  zeroForOne: boolean;
  concentratedRangePct: number;
}

export interface ParamsProgressiveFeeInXD {
  type: '_progressiveFeeInXD';
  baseFeesBps: number;
  progressiveRate: number;
  appliedFeesBps: number;
  tradeNotional: string;
}

export interface ParamsDecayXD {
  type: '_decayXD';
  halfLifeSeconds: number;
  elapsedSeconds: number;
  decayFactor: number;
  virtualReservesBefore: ReservePair;
  virtualReservesAfter: ReservePair;
}

export interface ParamsGeneric {
  type: string;
  [key: string]: unknown;
}

export type OpcodeParams =
  | ParamsBalanceSetup
  | ParamsXycConcentrateGrowLiquidityXD
  | ParamsProgressiveFeeInXD
  | ParamsDecayXD
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
