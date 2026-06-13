# AquaLab — demo deck

A self-contained presentation for the 3-minute demo. No build step, no network,
no dependencies — it's a single HTML file so it works offline at the booth.

## Present it

Open `slides/index.html` in any browser:

```bash
# from the repo root, either just open the file…
open slides/index.html          # macOS  (xdg-open on Linux)

# …or serve it (e.g. alongside the visualizer)
npx serve slides                # then visit the printed URL
```

## Controls

| Key | Action |
|---|---|
| `→` / `Space` / click right | next slide |
| `←` / click left | previous slide |
| `S` | toggle **speaker notes** (per-slide talk track + live-demo commands) |
| `F` | fullscreen |
| `Home` / `End` | first / last slide |

The current slide is stored in the URL hash, so you can deep-link or refresh
without losing your place.

## The 3-minute flow

The deck is built around the demo's three beats; the speaker notes (`S`) carry the
exact commands for each:

1. **Transfers are real** — run `forge test -vv` live; point at `1 WETH → 2970.297 USDC`
   and 12 passing (slide 6).
2. **The pipeline is visible** — `cd viz && npm run dev`, step through the real
   exported trace (slide 7).
3. **The position is sophisticated** — switch to the large / two-swap trace: concentrated
   liquidity returns more, and decay makes successive swaps cost more (slide 8).

Slide 10 doubles as the live-demo runbook — keep speaker notes open on it as a cheat
sheet.
