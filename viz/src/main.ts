/**
 * AquaLab Trace Visualizer — main entry point
 */

import type { Trace } from './types.js';
import { renderStepPanel, renderPipelineBreadcrumb } from './stepPanel.js';
import { drawCurve, createCurveAnimState, animateTo, tickAnimation } from './curve.js';

// ---- Load fixtures (Vite will bundle these as JSON) ----
import smallSwap   from '../fixtures/trace-small-swap.fixture.json';
import largeSwap   from '../fixtures/trace-large-swap.fixture.json';
import twoSwapDecay from '../fixtures/trace-two-swap-decay.fixture.json';

const TRACES: Record<string, Trace> = {
  small:        smallSwap    as Trace,
  large:        largeSwap    as Trace,
  twoSwapDecay: twoSwapDecay as Trace,
};

// ---- State ----
let currentTrace: Trace = TRACES.small;
let currentStep = 0;

const animState = createCurveAnimState();
let lastFrameTime = 0;
let rafId = 0;

// ---- DOM refs ----
const traceSelect    = document.getElementById('trace-select') as HTMLSelectElement;
const prevBtn        = document.getElementById('btn-prev') as HTMLButtonElement;
const nextBtn        = document.getElementById('btn-next') as HTMLButtonElement;
const stepContainer  = document.getElementById('step-panel') as HTMLElement;
const pipelineRow    = document.getElementById('pipeline-row') as HTMLElement;
const canvas         = document.getElementById('curve-canvas') as HTMLCanvasElement;
const metaBar        = document.getElementById('meta-bar') as HTMLElement;
const progressFill   = document.getElementById('progress-bar-fill') as HTMLElement;

// ---- Resize canvas ----
function resizeCanvas(): void {
  const dpr = window.devicePixelRatio || 1;
  const parent = canvas.parentElement!;
  const w = parent.clientWidth;
  const h = Math.min(Math.max(w * 0.5, 220), 380);
  canvas.style.width  = `${w}px`;
  canvas.style.height = `${h}px`;
  canvas.width  = Math.round(w * dpr);
  canvas.height = Math.round(h * dpr);
}

// ---- Render ----
function render(): void {
  const step = currentTrace.steps[currentStep];
  const prevStep = currentStep > 0 ? currentTrace.steps[currentStep - 1] : null;

  renderStepPanel(stepContainer, step, currentTrace);
  renderPipelineBreadcrumb(pipelineRow, currentTrace.steps, currentStep);

  // Pipeline breadcrumb click
  pipelineRow.querySelectorAll<HTMLButtonElement>('.pipeline-step').forEach(btn => {
    btn.addEventListener('click', () => {
      goToStep(Number(btn.dataset.index));
    });
  });

  // Nav buttons
  prevBtn.disabled = currentStep === 0;
  nextBtn.disabled = currentStep === currentTrace.steps.length - 1;

  // Progress bar
  const pct = currentTrace.steps.length > 1
    ? (currentStep / (currentTrace.steps.length - 1)) * 100
    : 100;
  progressFill.style.width = `${pct}%`;

  // Meta bar
  const md = currentTrace.metadata;
  metaBar.innerHTML = `
    <span class="meta-item"><span class="meta-label">Trace</span><span class="meta-val">${md.label ?? 'Unnamed'}</span></span>
    <span class="meta-sep">·</span>
    <span class="meta-item"><span class="meta-label">Block</span><span class="meta-val">${md.blockNumber.toLocaleString()}</span></span>
    <span class="meta-sep">·</span>
    <span class="meta-item"><span class="meta-label">Strategy</span><span class="meta-val mono">${md.strategyHash.slice(0, 10)}…</span></span>
    <span class="meta-sep">·</span>
    <span class="meta-item"><span class="meta-label">Direction</span><span class="meta-val">${md.swapDirection.replace('_', ' → ')}</span></span>
    <span class="meta-sep">·</span>
    <span class="meta-item"><span class="meta-label">Total fee</span><span class="meta-val fee-val">${md.totalFeesBps} bps</span></span>
  `;

  // Kick off curve animation to new swap point
  animateTo(animState, step.curveState.swapPointX);
  drawCurve(canvas, step.curveState, animState, prevStep?.curveState ?? null);
}

function goToStep(index: number): void {
  const clamped = Math.max(0, Math.min(currentTrace.steps.length - 1, index));
  if (clamped === currentStep) return;
  currentStep = clamped;
  render();
  // Flash the step panel to signal the transition
  stepContainer.classList.remove('flash');
  void stepContainer.offsetWidth; // force reflow to restart animation
  stepContainer.classList.add('flash');
}

// ---- Animation loop ----
function loop(now: number): void {
  const dt = now - lastFrameTime;
  lastFrameTime = now;
  const needsRedraw = tickAnimation(animState, dt);
  if (needsRedraw) {
    const step = currentTrace.steps[currentStep];
    const prevStep = currentStep > 0 ? currentTrace.steps[currentStep - 1] : null;
    drawCurve(canvas, step.curveState, animState, prevStep?.curveState ?? null);
  }
  rafId = requestAnimationFrame(loop);
}

// ---- Event listeners ----
traceSelect.addEventListener('change', () => {
  currentTrace = TRACES[traceSelect.value] ?? TRACES.small;
  currentStep = 0;
  render();
});

prevBtn.addEventListener('click', () => goToStep(currentStep - 1));
nextBtn.addEventListener('click', () => goToStep(currentStep + 1));

document.addEventListener('keydown', (e) => {
  if (e.key === 'ArrowRight' || e.key === 'ArrowDown') goToStep(currentStep + 1);
  if (e.key === 'ArrowLeft'  || e.key === 'ArrowUp')   goToStep(currentStep - 1);
});

window.addEventListener('resize', () => {
  resizeCanvas();
  const step = currentTrace.steps[currentStep];
  const prevStep = currentStep > 0 ? currentTrace.steps[currentStep - 1] : null;
  drawCurve(canvas, step.curveState, animState, prevStep?.curveState ?? null);
});

// ---- Boot ----
resizeCanvas();
render();
rafId = requestAnimationFrame(loop);
void rafId; // suppress unused warning
