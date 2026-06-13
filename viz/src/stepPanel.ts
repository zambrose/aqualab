/**
 * Renders the instruction-pipeline step panel:
 * opcode name, decoded params table, balance deltas.
 *
 * Opcode names match the real AquaOpcodes table (as discovered by Agent 2):
 *   _salt                          — Controls._salt (index 21)
 *   _decayXD                       — Decay._decayXD (index 20)
 *   _flatFeeAmountInXD             — Fee._flatFeeAmountInXD (index 22)
 *   _xycSwapXD                     — XYCSwap._xycSwapXD (index 18)
 *   _xycConcentrateGrowLiquidity2D — XYCConcentrate._xycConcentrateGrowLiquidity2D (index 19)
 */

import type {
  TraceStep, Trace, OpcodeParams,
  ParamsSalt,
  ParamsDecayXD,
  ParamsFlatFeeAmountInXD,
  ParamsXycSwapXD,
  ParamsXycConcentrateGrowLiquidity2D,
  SwapRegisters,
  TokenInfo,
} from './types.js';
import { formatAmount, formatDelta, formatBps, truncateHex } from './format.js';

/**
 * Render the SwapVM registers panel for the current step.
 *
 * Direction mapping (VM-relative in/out → real token):
 *   swapDirection A_TO_B → tokenIn = tokenA, tokenOut = tokenB
 *   swapDirection B_TO_A → tokenIn = tokenB, tokenOut = tokenA
 *
 * Registers that changed value vs. the previous step are highlighted with a
 * CSS class so the per-instruction mutation is visible at a glance.
 */
function renderRegisters(
  registers: SwapRegisters,
  prevRegisters: SwapRegisters | null,
  tokenA: TokenInfo,
  tokenB: TokenInfo,
  swapDirection: 'A_TO_B' | 'B_TO_A',
): string {
  // Resolve which token is "in" and which is "out" for this swap.
  const tokenIn  = swapDirection === 'A_TO_B' ? tokenA : tokenB;
  const tokenOut = swapDirection === 'A_TO_B' ? tokenB : tokenA;

  /**
   * Format a bigint-string using the correct token's decimals/symbol.
   * Falls back to raw value if formatting throws.
   */
  function fmt(raw: string, token: TokenInfo): string {
    try {
      return formatAmount(raw, token, 6);
    } catch {
      return raw;
    }
  }

  /** Return CSS class if the register value changed; empty string if unchanged or no prev. */
  function changedClass(field: keyof SwapRegisters): string {
    if (!prevRegisters) return '';
    return prevRegisters[field] !== registers[field] ? 'reg-changed' : '';
  }

  /** Render one register row. */
  function regRow(
    name: string,
    value: string,
    humanValue: string,
    tooltip: string,
    field: keyof SwapRegisters,
  ): string {
    const cls = changedClass(field);
    const changedMark = cls ? ' <span class="reg-changed-mark" title="Changed this step">▲</span>' : '';
    return `<tr class="${cls}">
      <td class="reg-name" title="${escHtml(tooltip)}">${escHtml(name)}</td>
      <td class="reg-human">${escHtml(humanValue)}${changedMark}</td>
      <td class="reg-raw" title="${escHtml(value)}">${escHtml(value.length > 20 ? value.slice(0, 12) + '…' : value)}</td>
    </tr>`;
  }

  return `<table class="registers-table">
    <thead>
      <tr>
        <th class="reg-th-name">Register</th>
        <th class="reg-th-human">Value</th>
        <th class="reg-th-raw">Raw (uint256)</th>
      </tr>
    </thead>
    <tbody>
      ${regRow(
        'balanceIn',
        registers.balanceIn,
        fmt(registers.balanceIn, tokenIn),
        `ctx.swap.balanceIn — virtual reserve of the input token (${tokenIn.symbol})`,
        'balanceIn',
      )}
      ${regRow(
        'balanceOut',
        registers.balanceOut,
        fmt(registers.balanceOut, tokenOut),
        `ctx.swap.balanceOut — virtual reserve of the output token (${tokenOut.symbol})`,
        'balanceOut',
      )}
      ${regRow(
        'amountIn',
        registers.amountIn,
        fmt(registers.amountIn, tokenIn),
        `ctx.swap.amountIn — taker gross input; fee wrappers reduce this`,
        'amountIn',
      )}
      ${regRow(
        'amountOut',
        registers.amountOut,
        fmt(registers.amountOut, tokenOut),
        `ctx.swap.amountOut — computed output; set by the AMM leaf`,
        'amountOut',
      )}
      ${regRow(
        'amountNetPulled',
        registers.amountNetPulled,
        fmt(registers.amountNetPulled, tokenIn),
        `ctx.swap.amountNetPulled — net input pulled to the maker (protocol-fee opcodes only; 0 in flat-fee programs)`,
        'amountNetPulled',
      )}
    </tbody>
  </table>
  <p class="reg-direction-note">In/Out direction: <strong>${escHtml(swapDirection.replace('_', ' → '))}</strong> — balanceIn/amountIn = ${escHtml(tokenIn.symbol)}, balanceOut/amountOut = ${escHtml(tokenOut.symbol)}</p>`;
}

/** Render the param table for any opcode */
function renderParams(params: OpcodeParams): string {
  const rows: [string, string][] = [];

  if (params.type === '_salt') {
    const p = params as ParamsSalt;
    rows.push(['salt (uint64)', p.salt]);
    rows.push(['effect', 'No-op — only perturbs the order hash for pool uniqueness']);
  } else if (params.type === '_decayXD') {
    const p = params as ParamsDecayXD;
    rows.push(['decayPeriodSeconds', `${p.decayPeriodSeconds}s`]);
    rows.push(['elapsedSeconds', `${p.elapsedSeconds}s`]);
    const decayFactor = p.decayPeriodSeconds > 0
      ? Math.max(0, 1 - p.elapsedSeconds / p.decayPeriodSeconds)
      : 1;
    const isDecayActive = p.elapsedSeconds > 0 && p.elapsedSeconds < p.decayPeriodSeconds;
    rows.push(['decay factor (1-t/T)', isDecayActive
      ? `${decayFactor.toFixed(4)}  ← active MEV protection`
      : decayFactor.toFixed(4)]);
    rows.push(['offsetIn (raw, tokenIn units)',
      BigInt(p.currentOffsetIn) > 0n
        ? `${p.currentOffsetIn} (non-zero — adds virtual depth to tokenIn)`
        : '0 (no prior same-direction trade)']);
    rows.push(['offsetOut (raw, tokenOut units)',
      BigInt(p.currentOffsetOut) > 0n
        ? `${p.currentOffsetOut} (non-zero — reduces virtual tokenOut supply)`
        : '0 (no prior same-direction trade)']);
    rows.push(['vReserveA before→after',
      `${(Number(p.virtualReservesBefore.reserveA) / 1e18).toFixed(4)} → ${(Number(p.virtualReservesAfter.reserveA) / 1e18).toFixed(4)} WETH`]);
    rows.push(['vReserveB before→after',
      `${(Number(p.virtualReservesBefore.reserveB) / 1e6).toFixed(0)} → ${(Number(p.virtualReservesAfter.reserveB) / 1e6).toFixed(0)} USDC`]);
  } else if (params.type === '_flatFeeAmountInXD') {
    const p = params as ParamsFlatFeeAmountInXD;
    rows.push(['feeBps (SwapVM 1e9=100%)', p.feeBps.toLocaleString()]);
    rows.push(['humanFeeBps (out of 10000)', `${p.humanFeeBps} bps (${(p.humanFeeBps / 100).toFixed(2)}%)`]);
    rows.push(['grossAmountIn (WETH)', (Number(p.grossAmountIn) / 1e18).toFixed(6)]);
    rows.push(['feeAmount (WETH)', (Number(p.feeAmount) / 1e18).toFixed(6)]);
    rows.push(['netAmountIn (WETH)', (Number(p.netAmountIn) / 1e18).toFixed(6)]);
  } else if (params.type === '_xycSwapXD') {
    const p = params as ParamsXycSwapXD;
    rows.push(['curve', 'constant-product x*y=k']);
    rows.push(['virtualBalanceIn (WETH)', (Number(p.virtualBalanceIn) / 1e18).toFixed(4)]);
    rows.push(['virtualBalanceOut (USDC)', (Number(p.virtualBalanceOut) / 1e6).toFixed(0)]);
    rows.push(['netAmountIn (WETH)', (Number(p.netAmountIn) / 1e18).toFixed(6)]);
    rows.push(['amountOut (USDC)', (Number(p.amountOut) / 1e6).toFixed(6)]);
    rows.push(['formula', 'netIn * vOut / (vIn + netIn)']);
  } else if (params.type === '_xycConcentrateGrowLiquidity2D') {
    const p = params as ParamsXycConcentrateGrowLiquidity2D;
    rows.push(['curve', 'concentrated-liquidity (price band)']);
    rows.push(['sqrtPriceMin', truncateHex('0x' + BigInt(p.sqrtPriceMin).toString(16))]);
    rows.push(['sqrtPriceMax', truncateHex('0x' + BigInt(p.sqrtPriceMax).toString(16))]);
    rows.push(['liquidity L', p.liquidity]);
    rows.push(['virtualBalanceIn (WETH)', (Number(p.virtualBalanceIn) / 1e18).toFixed(4)]);
    rows.push(['virtualBalanceOut (USDC)', (Number(p.virtualBalanceOut) / 1e6).toFixed(0)]);
    rows.push(['netAmountIn (WETH)', (Number(p.netAmountIn) / 1e18).toFixed(6)]);
    rows.push(['amountOut (USDC)', (Number(p.amountOut) / 1e6).toFixed(6)]);
    rows.push(['amplification', `${(Number(p.virtualBalanceIn) / Math.max(1, Number(p.virtualBalanceIn) - Number(p.liquidity) * 1e-18)).toFixed(2)}x vs plain x*y=k`]);
  } else {
    for (const [k, v] of Object.entries(params as Record<string, unknown>)) {
      if (k !== 'type') rows.push([k, String(v)]);
    }
  }

  if (rows.length === 0) return '<p class="dim">No params</p>';
  return `<table class="param-table">
    ${rows.map(([k, v]) => `<tr><td class="param-key">${escHtml(k)}</td><td class="param-val">${escHtml(v)}</td></tr>`).join('')}
  </table>`;
}

function escHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * Map opcode name to CSS class for color-coding.
 * Uses substring matching so it works with all real opcode names:
 *   _salt              → opcode-generic
 *   _decayXD           → opcode-decay   (contains 'decay'/'Decay')
 *   _flatFeeAmountInXD → opcode-fee     (contains 'Fee'/'fee')
 *   _xycSwapXD         → opcode-amm     (contains 'Swap')
 *   _xycConcentrateGrowLiquidity2D → opcode-amm (contains 'Concentrate'/'Swap')
 *   BALANCE_SETUP      → opcode-setup
 */
function opcodeClass(opcode: string): string {
  if (opcode === 'BALANCE_SETUP') return 'opcode-setup';
  if (opcode === '_salt') return 'opcode-generic';
  if (opcode.toLowerCase().includes('concentrate') || opcode.toLowerCase().includes('swap')) return 'opcode-amm';
  if (opcode.toLowerCase().includes('fee')) return 'opcode-fee';
  if (opcode.toLowerCase().includes('decay')) return 'opcode-decay';
  return 'opcode-generic';
}

export function renderStepPanel(container: HTMLElement, step: TraceStep, trace: Trace, prevStep: TraceStep | null = null): void {
  const { tokenA, tokenB, swapDirection } = trace.metadata;

  const dMakerA = formatDelta(step.balancesBefore.makerTokenA, step.balancesAfter.makerTokenA, tokenA);
  const dMakerB = formatDelta(step.balancesBefore.makerTokenB, step.balancesAfter.makerTokenB, tokenB);
  const dTakerA = formatDelta(step.balancesBefore.takerTokenA, step.balancesAfter.takerTokenA, tokenA);
  const dTakerB = formatDelta(step.balancesBefore.takerTokenB, step.balancesAfter.takerTokenB, tokenB);

  function deltaClass(s: string): string {
    if (s.startsWith('+')) return 'delta-pos';
    if (s.startsWith('-')) return 'delta-neg';
    return 'delta-zero';
  }

  function balRow(label: string, before: string, after: string, token: typeof tokenA, delta: string): string {
    return `<tr>
      <td class="bal-label">${escHtml(label)}</td>
      <td class="bal-val">${escHtml(formatAmount(before, token, 4))}</td>
      <td class="bal-arrow">→</td>
      <td class="bal-val">${escHtml(formatAmount(after, token, 4))}</td>
      <td class="bal-delta ${deltaClass(delta)}">${escHtml(delta)}</td>
    </tr>`;
  }

  container.innerHTML = `
    <div class="step-header">
      <span class="step-index">Step ${step.stepIndex + 1} / ${trace.steps.length}</span>
      <span class="opcode-badge ${opcodeClass(step.opcode)}">${escHtml(step.opcode)}</span>
    </div>
    <p class="step-description">${escHtml(step.description)}</p>

    <h3 class="section-title">Params</h3>
    ${renderParams(step.params)}

    <h3 class="section-title">SwapVM Registers</h3>
    ${renderRegisters(step.registers, prevStep?.registers ?? null, tokenA, tokenB, swapDirection)}

    <h3 class="section-title">Balance Deltas</h3>
    <table class="balance-table">
      <thead>
        <tr><th>Account</th><th colspan="3">Amount</th><th>Delta</th></tr>
      </thead>
      <tbody>
        ${balRow('Maker WETH', step.balancesBefore.makerTokenA, step.balancesAfter.makerTokenA, tokenA, dMakerA)}
        ${balRow('Maker USDC', step.balancesBefore.makerTokenB, step.balancesAfter.makerTokenB, tokenB, dMakerB)}
        ${balRow('Taker WETH', step.balancesBefore.takerTokenA, step.balancesAfter.takerTokenA, tokenA, dTakerA)}
        ${balRow('Taker USDC', step.balancesBefore.takerTokenB, step.balancesAfter.takerTokenB, tokenB, dTakerB)}
      </tbody>
    </table>

    <h3 class="section-title">Curve State</h3>
    <table class="param-table">
      <tr><td class="param-key">Spot price</td><td class="param-val price-val">$${step.curveState.spotPriceAInB.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}/WETH</td></tr>
      <tr><td class="param-key">Fee applied</td><td class="param-val fee-val">${formatBps(step.curveState.feeBps)}</td></tr>
      <tr><td class="param-key">Real rA</td><td class="param-val">${(Number(step.curveState.realReserves.reserveA) / 1e18).toLocaleString('en-US', { maximumFractionDigits: 2 })} WETH</td></tr>
      <tr><td class="param-key">Real rB</td><td class="param-val">${(Number(step.curveState.realReserves.reserveB) / 1e6).toLocaleString('en-US', { maximumFractionDigits: 0 })} USDC</td></tr>
      <tr><td class="param-key">Virtual rA</td><td class="param-val">${(Number(step.curveState.virtualReserves.reserveA) / 1e18).toLocaleString('en-US', { maximumFractionDigits: 2 })} WETH</td></tr>
      <tr><td class="param-key">Virtual rB</td><td class="param-val">${(Number(step.curveState.virtualReserves.reserveB) / 1e6).toLocaleString('en-US', { maximumFractionDigits: 0 })} USDC</td></tr>
      ${step.curveState.concentratedRange ? `
      <tr><td class="param-key">Conc. range</td><td class="param-val">$${step.curveState.concentratedRange.priceLower.toLocaleString()} – $${step.curveState.concentratedRange.priceUpper.toLocaleString()}</td></tr>
      <tr><td class="param-key">In range</td><td class="param-val ${step.curveState.concentratedRange.isInRange ? 'delta-pos' : 'delta-neg'}">${step.curveState.concentratedRange.isInRange ? '✓ Yes' : '✗ No'}</td></tr>
      ` : ''}
    </table>
  `;
}

/** Render the pipeline breadcrumb row */
export function renderPipelineBreadcrumb(container: HTMLElement, steps: TraceStep[], currentIndex: number): void {
  container.innerHTML = steps.map((s, i) => `
    <button class="pipeline-step ${i === currentIndex ? 'active' : ''} ${opcodeClass(s.opcode)}"
            data-index="${i}" title="${escHtml(s.opcode)}">
      <span class="pipeline-num">${i + 1}</span>
      <span class="pipeline-name">${escHtml(s.opcode.replace(/^_/, '').replace('XD', '').slice(0, 14))}</span>
    </button>
    ${i < steps.length - 1 ? '<span class="pipeline-arrow">→</span>' : ''}
  `).join('');
}
