/**
 * Formatting utilities for token amounts, prices, etc.
 */

import type { TokenInfo } from './types.js';

/**
 * Convert a bigint string (smallest unit) to a human-readable string
 * respecting the token's decimals.
 */
export function formatAmount(raw: string, token: TokenInfo, maxDecimals = 6): string {
  const value = BigInt(raw);
  const divisor = 10n ** BigInt(token.decimals);
  const whole = value / divisor;
  const frac = value % divisor;
  if (frac === 0n) return `${whole} ${token.symbol}`;

  const fracStr = frac.toString().padStart(token.decimals, '0');
  const trimmed = fracStr.replace(/0+$/, '').slice(0, maxDecimals);
  return `${whole}.${trimmed} ${token.symbol}`;
}

/**
 * Format a bigint string as a short human number (e.g. "1,000.25").
 */
export function formatAmountShort(raw: string, token: TokenInfo): string {
  const value = BigInt(raw);
  const divisor = 10n ** BigInt(token.decimals);
  const whole = value / divisor;
  const frac = value % divisor;
  const fracStr = frac.toString().padStart(token.decimals, '0').slice(0, 4).replace(/0+$/, '');
  const wholeFormatted = whole.toLocaleString();
  return fracStr ? `${wholeFormatted}.${fracStr}` : wholeFormatted;
}

/**
 * Compute the signed delta between two bigint strings.
 * Returns { delta, sign, abs }.
 */
export function computeDelta(before: string, after: string): {
  delta: bigint;
  sign: '+' | '-' | '';
  abs: bigint;
} {
  const b = BigInt(before);
  const a = BigInt(after);
  const delta = a - b;
  return {
    delta,
    sign: delta > 0n ? '+' : delta < 0n ? '-' : '',
    abs: delta < 0n ? -delta : delta,
  };
}

export function formatDelta(before: string, after: string, token: TokenInfo): string {
  const { sign, abs } = computeDelta(before, after);
  if (sign === '') return '±0';
  const divisor = 10n ** BigInt(token.decimals);
  const whole = abs / divisor;
  const frac = abs % divisor;
  const fracStr = frac.toString().padStart(token.decimals, '0').slice(0, 4).replace(/0+$/, '');
  const num = fracStr ? `${whole}.${fracStr}` : `${whole}`;
  return `${sign}${num} ${token.symbol}`;
}

export function formatPrice(price: number): string {
  return price.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export function formatBps(bps: number): string {
  return `${bps} bps (${(bps / 100).toFixed(2)}%)`;
}

export function truncateHex(hex: string, chars = 8): string {
  if (hex.length <= chars + 4) return hex;
  return `${hex.slice(0, chars + 2)}…${hex.slice(-4)}`;
}
