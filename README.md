# GB10 vLLM Ops — spin-wait fix + clock-cap sweep

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
load*, records tok/s + SoC temp, and **restores 2190** on exit.

```bash
# from a machine with llama-benchy on PATH and SSH to both nodes:
HEAD_NODE=node0 WORKER_NODE=node1 BASE_URL=http://node0:8888/v1 \
  bash sweep/clock-sweep.sh
```

## Sanitization
No LAN/IP/identity. Topology is env-parameterized with `[VERIFY]` markers. Git author: **TysAIs**.
