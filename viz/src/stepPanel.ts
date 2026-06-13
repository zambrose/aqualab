/**
 * Renders the instruction-pipeline step panel:
 * opcode name, decoded params table, balance deltas.
 */

import type {
  TraceStep, Trace, OpcodeParams,
  ParamsBalanceSetup, ParamsXycConcentrateGrowLiquidityXD,
  ParamsProgressiveFeeInXD, ParamsDecayXD,
} from './types.js';
import { formatAmount, formatDelta, formatBps, truncateHex } from './format.js';

/** Render the param table for any opcode */
function renderParams(params: OpcodeParams): string {
  const rows: [string, string][] = [];

  if (params.type === 'BALANCE_SETUP') {
    const p = params as ParamsBalanceSetup;
    rows.push(['makerDeposit.token', p.makerDeposit.token]);
    rows.push(['makerDeposit.amount', p.makerDeposit.amount]);
    rows.push(['takerDeposit.token', p.takerDeposit.token]);
    rows.push(['takerDeposit.amount', p.takerDeposit.amount]);
  } else if (params.type === '_xycConcentrateGrowLiquidityXD') {
    const p = params as ParamsXycConcentrateGrowLiquidityXD;
    rows.push(['lowerTick', p.lowerTick.toString()]);
    rows.push(['upperTick', p.upperTick.toString()]);
    rows.push(['currentTick', p.currentTick.toString()]);
    rows.push(['liquidity', p.liquidity]);
    rows.push(['sqrtPriceX96', truncateHex('0x' + BigInt(p.sqrtPriceX96).toString(16))]);
    rows.push(['amountSpecified', p.amountSpecified]);
    rows.push(['zeroForOne', String(p.zeroForOne)]);
    rows.push(['concentratedRangePct', `${p.concentratedRangePct}%`]);
  } else if (params.type === '_progressiveFeeInXD') {
    const p = params as ParamsProgressiveFeeInXD;
    rows.push(['baseFeesBps', `${p.baseFeesBps} bps`]);
    rows.push(['progressiveRate', `${p.progressiveRate} bps / 1e18`]);
    rows.push(['appliedFeesBps', formatBps(p.appliedFeesBps)]);
    rows.push(['tradeNotional', p.tradeNotional]);
  } else if (params.type === '_decayXD') {
    const p = params as ParamsDecayXD;
    rows.push(['halfLifeSeconds', `${p.halfLifeSeconds}s`]);
    rows.push(['elapsedSeconds', `${p.elapsedSeconds}s`]);
    rows.push(['decayFactor', p.decayFactor.toFixed(4)]);
    rows.push(['vReserveA before→after',
      `${(Number(p.virtualReservesBefore.reserveA) / 1e18).toFixed(2)} → ${(Number(p.virtualReservesAfter.reserveA) / 1e18).toFixed(2)} WETH`]);
    rows.push(['vReserveB before→after',
      `${(Number(p.virtualReservesBefore.reserveB) / 1e6).toFixed(0)} → ${(Number(p.virtualReservesAfter.reserveB) / 1e6).toFixed(0)} USDC`]);
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

function opcodeClass(opcode: string): string {
  if (opcode === 'BALANCE_SETUP') return 'opcode-setup';
  if (opcode.includes('Concentrate') || opcode.includes('Swap')) return 'opcode-amm';
  if (opcode.includes('Fee')) return 'opcode-fee';
  if (opcode.includes('decay') || opcode.includes('Decay')) return 'opcode-decay';
  return 'opcode-generic';
}

export function renderStepPanel(container: HTMLElement, step: TraceStep, trace: Trace): void {
  const { tokenA, tokenB } = trace.metadata;

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
      <span class="pipeline-name">${escHtml(s.opcode.replace('_', '').replace('XD', '').slice(0, 12))}</span>
    </button>
    ${i < steps.length - 1 ? '<span class="pipeline-arrow">→</span>' : ''}
  `).join('');
}
