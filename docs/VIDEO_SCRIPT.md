# AquaLab — 3-minute demo video script

A record-ready script for the submission video. Two rules keep it easy to deliver:

1. **One AMM idea only.** You don't need to explain the math. The audience needs
   exactly one concept: *SwapVM lets you build a trading strategy out of small
   composable instructions, like Lego.* That's it.
2. **Every claim is on screen.** You only ever narrate what the viewer can see —
   so you can't be "wrong," and you never have to defend something off-camera.

Target length: **~3:00**. The narration below is ~340 words; the rest is demo
time. Speaking slowly, this lands right around three minutes.

---

## Before you hit record (5-minute setup)

- [ ] **Warm the fork cache.** Run `forge test` once now so the mainnet RPC data
      is cached locally. Your on-camera run will then take ~1 second instead of
      waiting on the network. (Needs `MAINNET_RPC_URL` in `.env`.)
- [ ] **Two terminals, big font.** Terminal A for the test, Terminal B for the
      visualizer. Bump the font size so it's readable in 1080p.
- [ ] **Pre-start the visualizer.** In Terminal B: `cd viz && npm install &&
      npm run dev`. Open `http://localhost:5173` in a browser tab and leave it on
      the **small swap** trace. Zoom the browser to ~110–125%.
- [ ] **Open one more tab** on `docs/judges.html` (optional closing shot).
- [ ] **Clear Terminal A** so the only thing on screen will be your `forge test`
      command and its output.
- [ ] **Do one full dry run** off-camera. The whole thing should feel calm.

> Note: these commands assume Foundry is on your PATH (the normal `foundryup`
> install) and Node is installed. If you're recording inside the cloud dev
> environment, prefix shells with `export PATH="$HOME/.foundry/bin:$PATH"` and
> `set -a; source .env; set +a`.

---

## The script

Format: **[time] · what you DO · what you SAY.** Say the lines in your own voice —
they're written to be spoken, not read stiffly.

### 0:00–0:20 — Hook  ·  *(webcam or title slide)*

> "Hi, I'm **[your name]**, and this is **AquaLab**. 1inch just released **Aqua** —
> a new way to provide liquidity on-chain, powered by something called **SwapVM**.
> I built a custom trading strategy on it, and — because this stuff is hard to
> see — a **visual debugger** that shows the strategy executing, step by step."

### 0:20–0:45 — The one idea  ·  *(title slide, or the pipeline diagram in `docs/judges.html`)*

> "Here's the only idea you need. Most on-chain exchanges price every trade with
> a single, fixed formula. SwapVM is different — it's like **Lego**. You compose
> a strategy out of small **instructions**. I stacked three: a pricing curve that
> **concentrates liquidity** for better rates, a **fee** for liquidity providers,
> and **MEV protection** that defends traders from getting front-run."

*(Don't define "concentrate liquidity" or "MEV" yet — you'll show both later.
Naming them now just plants the words.)*

### 0:45–1:25 — Beat 1: it really works  ·  *(Terminal A)*

**DO:** type and run:

```bash
forge test -vv
```

**SAY** (while it runs — it's fast because you warmed the cache):

> "First: does it actually work? This runs my test suite. It **forks real
> Ethereum mainnet**, ships my strategy into the **live Aqua contract**, and
> executes a real swap. There —"

**DO:** point at the log line `Swapped 1 WETH for USDC (6dp): 2970297029` and the
final `15 passed`.

> "— one WETH in, about **2,970 USDC out**. Real tokens, moving on a real fork.
> **Fifteen tests, all green.** That's the on-chain proof the bounty asks for."

### 1:25–2:15 — Beat 2: the visualizer  ·  *(Browser — small swap trace)*

**DO:** switch to the browser tab. Use the **→ arrow** (or the step button) to
advance through the steps as you talk.

> "But a passing test is a black box. So here's the **visualizer** — that *same*
> swap, broken into the actual instructions the VM ran."

**DO:** step forward once per item as you name it.

> "Watch the **pipeline** along the top light up: first the **decay** protection,
> then the **fee**, then the **pricing curve**. Down here are the VM's internal
> **registers** — the highlighted ones are what changed on this step, so you can
> literally watch the numbers move through the machine. On the right, the **price
> curve** updates live."

**DO:** point at the green **`quote == swap ✓`** badge.

> "And this badge — **quote equals swap** — means the price you'd be *quoted*
> exactly matches what *executed*. No bait-and-switch."

### 2:15–2:40 — Beat 3: the sophisticated part  ·  *(Browser — switch the dropdown to the decay trace)*

**DO:** change the trace dropdown to the **decay / two-swap** trace. Step to the
`_decayXD` instruction.

> "One more — this is the MEV protection actually working. A **big trade just
> happened**, so when this next trade arrives, the **decay** instruction shifts
> the price *against* it — which makes front-running expensive. That's real
> sandwich-attack defense, and you can **watch it happen** instead of taking my
> word for it."

### 2:40–3:00 — Close  ·  *(webcam, or `docs/judges.html` hero)*

> "So that's **AquaLab**: a composed **SwapVM** strategy running on **live Aqua**,
> proven with real **on-chain transfers**, and made completely **transparent**
> with the visualizer. I used SwapVM **directly**, and documented every
> instruction and why it's there. Thanks for watching."

---

## If something breaks (don't panic)

- **The test is slow or the RPC hiccups on camera.** You warmed the cache, so
  this is unlikely — but if it stalls, keep talking and cut to the visualizer;
  the UI needs no network at all. You can splice the passing test in afterward.
- **You fumble a line.** Pause, breathe, say it again. You'll edit; nobody sees
  the retake.
- **Total network failure.** The visualizer (`viz/dist` after `npm run build`),
  the slide deck, and both `docs/*.html` pages all run fully offline. Only
  `forge test` needs the fork RPC.

---

## If a judge asks a follow-up (simple, honest answers)

- **"What's an AMM?"** → "A way to trade tokens against a pool using a formula
  instead of matching buyers and sellers — like a vending machine that quotes a
  price from its own inventory."
- **"What does 'concentrated liquidity' mean?"** → "Putting the pool's money to
  work in the price range where trading actually happens, so you get better rates
  for the same capital. It's the Uniswap v3 idea."
- **"How is decay MEV protection?"** → "After a trade, the price recovers
  gradually instead of instantly. A front-runner's second trade has to fight that
  lingering offset, which kills their profit."
- **"Did you use SwapVM directly?"** → "Yes — the strategy is a real program of
  SwapVM opcodes (salt, decay, flat-fee, and a concentrated-liquidity curve),
  shipped into the live Aqua deployment. It's documented in the README."
- **"Is this really on-chain?"** → "It runs on a mainnet *fork* — the live Aqua
  contract and real WETH/USDC liquidity — with real token transfers asserted in
  the tests. Local forks are explicitly allowed by the bounty."
- **"Anything tricky you ran into?"** → "Yes — the SwapVM router deployed on
  mainnet is a newer build than the published source, so I execute on a
  pinned-version engine while using the real live Aqua liquidity, and a test
  proves the link on-chain. It's documented honestly."

---

## One-line cheat sheet (tape it next to your screen)

```
HOOK  → strategy on Aqua + a visualizer
IDEA  → SwapVM = Lego: curve + fee + MEV protection
RUN   → forge test -vv  →  1 WETH → 2970 USDC, 15 green
SEE   → visualizer: pipeline + registers + curve + quote==swap
WOW   → decay trace: front-running gets penalized, live
CLOSE → direct SwapVM, real transfers, fully transparent
```
