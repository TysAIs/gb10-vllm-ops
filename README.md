# GB10 vLLM Ops — spin-wait fix + clock-cap sweep (turnkey)

> **Goal:** Hand this to any AI assistant — *"apply the GB10 vLLM fixes to my DGX Spark
> cluster"* — and it will do it. No prior knowledge needed.

Two operational tools for running vLLM on NVIDIA DGX Spark (GB10) without cooking the
SoC, distilled from a real 3-node cluster.

## 1. vLLM spin-wait fix (`spinwait/`)
On GB10, vLLM's distributed IPC (`shm_broadcast.py`, `SpinCondition.wait()`) spins for
`busy_loop_s = 1s` before sleeping — but decode messages arrive every few ms, so the
sleep branch is never taken and **CPU cores spin at full clock**, dumping ~10–20 W each
into the shared SoC thermal budget. Fix: `1s → 0.002s`.

- **vLLM-only.** Does NOT apply to SGLang (different IPC stack).
- **Real benefit at TP≥2** (multi-rank `mp` backend). On single-GPU TP=1 the original
  author's own A/B showed ~0 change — apply anyway, it's free.
- Builds a new `<image>-spinfix` tag; never modifies the original. See `spinwait/README.md`.
- Attribution: original analysis by **nacyot** (Korean), English write-up + tooling by
  **drowzeys** (MIT). Included here with credit.

## 2. Clock-cap sweep (`sweep/`)
Empirical 2190 / 2200 / 2300 MHz GPU-cap sweep to find the thermal/throughput knee on a
TP2 vLLM serve. Sets the cap on both nodes, benchmarks with
[eugr/llama-benchy](https://github.com/eugr/llama-benchy), samples the GR clock *under
load*, records tok/s + SoC temp, and **restores 2200** on exit.

```bash
# from a machine with llama-benchy on PATH and SSH to both nodes:
HEAD_NODE=node0 WORKER_NODE=node1 BASE_URL=http://node0:8888/v1 \
  bash sweep/clock-sweep.sh
```

**Conclusion (measured on GB10 TP2 DS4):** decode is bandwidth-bound, not clock-bound.
2190 / 2200 / 2300 all give the same decode (~70 tok/s c=1). 2200 MHz is the safe
recommended cap — set it once and leave it:

```bash
sudo nvidia-smi -lgc 0,2200        # live, instant, reversible
# persist via systemd unit gb10-clock-cap.service (ExecStart=/usr/bin/nvidia-smi -lgc 0,2200)
sudo systemctl daemon-reload && sudo systemctl enable --now gb10-clock-cap.service
```

## 3. The "empty response" trap (thinking default)
vLLM/SGLang serve reasoning models with **thinking ON by default**. A short chat reply
with a small `max_tokens` gets its entire budget eaten by invisible reasoning, and the
API returns `content: null` with `finish_reason: "length"`. The client shows a blank
message — looks like the model is dead, but it isn't. Fix: set the server default
`thinking: false` (e.g. vLLM `--default-chat-template-kwargs '{"thinking":false}'`, or
DS4's `DEFAULT_THINKING=off` in `.env`), and let clients opt IN per request.

## Sanitization
No LAN/IP/identity in this repo. Example node names (`node0`, `node1`, `192.168.0.x`)
are placeholders only. Git author: **TysAIs**.

## License
Tools MIT. Model weights subject to their respective licenses.
