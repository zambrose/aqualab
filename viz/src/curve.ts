/**
 * Animated canvas renderer for the constant-product AMM price curve.
 *
 * Draws:
 *  - Full-range constant-product hyperbola (x * y = k) in dim colour
 *  - Concentrated-liquidity highlighted band
 *  - The current swap point moving along the curve (animated)
 *  - Virtual reserve curve (shifted from real curve)
 *  - Fee and decay annotations
 */

import type { CurveState } from './types.js';

export interface CurveAnimState {
  /** Current swap point X in [0,1] (normalised position on curve) */
  swapPointX: number;
  /** Target swap point X we're animating towards */
  targetSwapPointX: number;
  /** Animation progress [0,1] */
  progress: number;
  /** Whether the swap-point translation animation is running */
  animating: boolean;
  /** Monotonic time counter (ms) for idle pulse */
  time: number;
}

/** Palette — dark theme */
const C = {
  bg:           '#0d1117',
  gridLine:     '#21262d',
  axisTick:     '#8b949e',
  curveReal:    '#1f6feb',       // blue  — real reserve hyperbola
  curveVirtual: '#388bfd44',     // faint blue — virtual
  rangeHighlight: '#d2a8ff22',   // purple tint for concentrated range
  rangeBorder:  '#8957e5',
  swapDot:      '#f78166',       // red-orange
  swapDotGlow:  '#f7816655',
  labelText:    '#e6edf3',
  dimText:      '#8b949e',
  feeLabel:     '#ffa657',
  decayLabel:   '#79c0ff',
  priceLabel:   '#56d364',
};

export function createCurveAnimState(): CurveAnimState {
  return {
    swapPointX: 0.5,
    targetSwapPointX: 0.5,
    progress: 1,
    animating: false,
    time: 0,
  };
}

/**
 * Kick off an animation to move the swap point to a new position.
 */
export function animateTo(state: CurveAnimState, targetX: number | null): void {
  state.targetSwapPointX = targetX ?? 0.5;
  state.progress = 0;
  state.animating = true;
}

/** Ease-in-out cubic */
function easeInOut(t: number): number {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

/**
 * Advance the animation by one frame (call every requestAnimationFrame).
 * Returns true if a redraw is needed.
 */
export function tickAnimation(state: CurveAnimState, dt: number): boolean {
  state.time += dt;
  if (!state.animating) {
    // Always redraw for the idle pulse effect on the swap dot
    return true;
  }
  state.progress = Math.min(1, state.progress + dt / 600); // 600 ms total
  state.swapPointX = state.progress >= 1
    ? state.targetSwapPointX
    : state.swapPointX + (state.targetSwapPointX - state.swapPointX) * easeInOut(state.progress / 1);
  if (state.progress >= 1) {
    state.swapPointX = state.targetSwapPointX;
    state.animating = false;
  }
  return true;
}

// ----- rendering helpers -----

interface Margins { top: number; right: number; bottom: number; left: number }

/**
 * Map a normalised curve parameter t ∈ [0.05, 0.95] to a (px, py) point
 * on the xy=k hyperbola, within the plot area.
 *
 * We parameterise by reserveA: x = reserveA_min * (1/t), y = k/x
 * but normalise so that t=0 → far left (high price) and t=1 → far right (low price).
 */
function curvePoint(t: number, k: number, plot: { x0: number; y0: number; w: number; h: number },
  xMin: number, xMax: number, yMin: number, yMax: number): [number, number] {
  const reserveA = xMin + t * (xMax - xMin);
  const reserveB = k / reserveA;
  const px = plot.x0 + ((reserveA - xMin) / (xMax - xMin)) * plot.w;
  const py = plot.y0 + plot.h - ((reserveB - yMin) / (yMax - yMin)) * plot.h;
  return [px, py];
}

export function drawCurve(
  canvas: HTMLCanvasElement,
  curveState: CurveState,
  animState: CurveAnimState,
  prevCurveState: CurveState | null,
): void {
  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  const dpr = window.devicePixelRatio || 1;
  const w = canvas.width / dpr;
  const h = canvas.height / dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  ctx.fillStyle = C.bg;
  ctx.fillRect(0, 0, w, h);

  const margin: Margins = { top: 32, right: 24, bottom: 48, left: 64 };
  const plot = { x0: margin.left, y0: margin.top, w: w - margin.left - margin.right, h: h - margin.top - margin.bottom };

  // Use real reserves as basis for the curve
  const rA = Number(curveState.realReserves.reserveA) / 1e18; // WETH
  const rB = Number(curveState.realReserves.reserveB) / 1e6;  // USDC
  const k = rA * rB;

  // Define visible range: ±60% around current reserve
  const xMin = rA * 0.35;
  const xMax = rA * 2.0;
  const yMin = k / xMax;
  const yMax = k / xMin;

  // ---- Grid lines ----
  ctx.strokeStyle = C.gridLine;
  ctx.lineWidth = 0.5;
  const gridCount = 5;
  for (let i = 0; i <= gridCount; i++) {
    const t = i / gridCount;
    const gx = plot.x0 + t * plot.w;
    const gy = plot.y0 + t * plot.h;
    ctx.beginPath(); ctx.moveTo(gx, plot.y0); ctx.lineTo(gx, plot.y0 + plot.h); ctx.stroke();
    ctx.beginPath(); ctx.moveTo(plot.x0, gy); ctx.lineTo(plot.x0 + plot.w, gy); ctx.stroke();
  }

  // ---- Axis labels ----
  ctx.fillStyle = C.dimText;
  ctx.font = `${10 * dpr / dpr}px monospace`;
  ctx.textAlign = 'center';
  for (let i = 0; i <= gridCount; i++) {
    const t = i / gridCount;
    const gx = plot.x0 + t * plot.w;
    const reserveAtX = xMin + t * (xMax - xMin);
    ctx.fillText(reserveAtX.toFixed(0), gx, plot.y0 + plot.h + 16);
  }
  ctx.textAlign = 'right';
  for (let i = 0; i <= gridCount; i++) {
    const t = i / gridCount;
    const gy = plot.y0 + (1 - t) * plot.h;
    const reserveAtY = yMin + t * (yMax - yMin);
    ctx.fillText((reserveAtY / 1e6).toFixed(0) + 'M', plot.x0 - 6, gy + 4);
  }

  // Axis titles
  ctx.save();
  ctx.fillStyle = C.dimText;
  ctx.font = '10px monospace';
  ctx.textAlign = 'center';
  ctx.fillText('Reserve WETH', plot.x0 + plot.w / 2, h - 6);
  ctx.translate(14, plot.y0 + plot.h / 2);
  ctx.rotate(-Math.PI / 2);
  ctx.fillText('Reserve USDC', 0, 0);
  ctx.restore();

  // ---- Concentrated range highlight ----
  const range = curveState.concentratedRange;
  if (range) {
    // Compute reserveA positions at range price bounds
    // price = rB / rA → rA = rB / price = k / (rA * price) → rA = sqrt(k / price)
    const rA_upper = Math.sqrt(k / range.priceLower); // low price → high rA
    const rA_lower = Math.sqrt(k / range.priceUpper); // high price → low rA

    const px_low  = plot.x0 + ((rA_lower - xMin) / (xMax - xMin)) * plot.w;
    const px_high = plot.x0 + ((rA_upper - xMin) / (xMax - xMin)) * plot.w;

    ctx.fillStyle = C.rangeHighlight;
    ctx.fillRect(Math.max(px_low, plot.x0), plot.y0, Math.min(px_high, plot.x0 + plot.w) - Math.max(px_low, plot.x0), plot.h);

    // Range border lines
    ctx.strokeStyle = C.rangeBorder;
    ctx.lineWidth = 1;
    ctx.setLineDash([4, 4]);
    if (px_low >= plot.x0 && px_low <= plot.x0 + plot.w) {
      ctx.beginPath(); ctx.moveTo(px_low, plot.y0); ctx.lineTo(px_low, plot.y0 + plot.h); ctx.stroke();
    }
    if (px_high >= plot.x0 && px_high <= plot.x0 + plot.w) {
      ctx.beginPath(); ctx.moveTo(px_high, plot.y0); ctx.lineTo(px_high, plot.y0 + plot.h); ctx.stroke();
    }
    ctx.setLineDash([]);

    // Range label
    ctx.fillStyle = C.rangeBorder;
    ctx.font = '9px monospace';
    ctx.textAlign = 'center';
    const midPx = (Math.max(px_low, plot.x0) + Math.min(px_high, plot.x0 + plot.w)) / 2;
    ctx.fillText(`Conc. Range [${range.priceLower.toLocaleString()}–${range.priceUpper.toLocaleString()}]`, midPx, plot.y0 + 14);
  }

  // ---- Virtual reserves curve (prev step → this step transition) ----
  if (prevCurveState) {
    const vA = Number(prevCurveState.virtualReserves.reserveA) / 1e18;
    const vB = Number(prevCurveState.virtualReserves.reserveB) / 1e6;
    const kv = vA * vB;
    ctx.strokeStyle = C.curveVirtual;
    ctx.lineWidth = 1.5;
    ctx.setLineDash([3, 5]);
    ctx.beginPath();
    const steps = 80;
    for (let i = 0; i <= steps; i++) {
      const t = i / steps;
      const [px, py] = curvePoint(t, kv, plot, xMin, xMax, yMin, yMax);
      i === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
    }
    ctx.stroke();
    ctx.setLineDash([]);
  }

  // ---- Real reserves curve ----
  ctx.strokeStyle = C.curveReal;
  ctx.lineWidth = 2;
  ctx.beginPath();
  const steps = 120;
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    const [px, py] = curvePoint(t, k, plot, xMin, xMax, yMin, yMax);
    i === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
  }
  ctx.stroke();

  // ---- Swap point (animated pulse) ----
  const swapT = animState.swapPointX;
  const [spx, spy] = curvePoint(swapT, k, plot, xMin, xMax, yMin, yMax);

  // Pulsing outer ring
  const pulse = (Math.sin(animState.time / 700) + 1) / 2; // 0..1
  const ringRadius = 10 + pulse * 8;
  const ringAlpha = 0.15 + pulse * 0.2;
  const grd = ctx.createRadialGradient(spx, spy, 0, spx, spy, ringRadius + 4);
  grd.addColorStop(0, `rgba(247, 129, 102, ${ringAlpha + 0.15})`);
  grd.addColorStop(1, 'transparent');
  ctx.fillStyle = grd;
  ctx.beginPath();
  ctx.arc(spx, spy, ringRadius + 4, 0, Math.PI * 2);
  ctx.fill();

  // Outer ring stroke
  ctx.strokeStyle = `rgba(247, 129, 102, ${ringAlpha})`;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.arc(spx, spy, ringRadius, 0, Math.PI * 2);
  ctx.stroke();

  // Inner dot
  ctx.fillStyle = C.swapDot;
  ctx.beginPath();
  ctx.arc(spx, spy, 5, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = '#ffffffcc';
  ctx.lineWidth = 1;
  ctx.stroke();

  // ---- Price label at swap point ----
  ctx.fillStyle = C.priceLabel;
  ctx.font = 'bold 11px monospace';
  ctx.textAlign = spx > plot.x0 + plot.w * 0.7 ? 'right' : 'left';
  const priceLabel = `$${curveState.spotPriceAInB.toLocaleString('en-US', { maximumFractionDigits: 0 })}`;
  ctx.fillText(priceLabel, spx + (ctx.textAlign === 'left' ? 10 : -10), spy - 10);

  // ---- Fee annotation ----
  if (curveState.feeBps > 0) {
    ctx.fillStyle = C.feeLabel;
    ctx.font = '10px monospace';
    ctx.textAlign = 'left';
    ctx.fillText(`Fee: ${curveState.feeBps} bps`, plot.x0 + 6, plot.y0 + 16);
  }

  // ---- Decay annotation ----
  const vA_cur = Number(curveState.virtualReserves.reserveA) / 1e18;
  const rA_cur = Number(curveState.realReserves.reserveA) / 1e18;
  if (Math.abs(vA_cur - rA_cur) / rA_cur > 0.005) {
    ctx.fillStyle = C.decayLabel;
    ctx.font = '10px monospace';
    ctx.textAlign = 'left';
    const pct = ((1 - vA_cur / rA_cur) * 100).toFixed(1);
    ctx.fillText(`Decay: −${pct}% virt.`, plot.x0 + 6, plot.y0 + 30);
  }

  // ---- In-range indicator ----
  if (range) {
    const dot = range.isInRange ? '●' : '○';
    const col = range.isInRange ? '#56d364' : '#f78166';
    ctx.fillStyle = col;
    ctx.font = '10px monospace';
    ctx.textAlign = 'right';
    ctx.fillText(`${dot} ${range.isInRange ? 'In range' : 'Out of range'}`, plot.x0 + plot.w - 6, plot.y0 + 16);
  }
}
