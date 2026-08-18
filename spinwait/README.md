# vLLM spin-wait fix for DGX Spark / GB10 — English guide + one-command patcher

**On GB10, the hottest thing during LLM inference is not the GPU. It's four CPU cores
spinning while they wait for messages.**

A one-line change to vLLM drops SoC temperature by up to **24 °C** with **no change in
throughput**. This repo explains why, in English, and gives you a script that patches
every vLLM container and image on your machine.

> **Credit.** The original analysis is by **nacyot**, published in Korean as
> *"LLM 추론에서 가장 뜨거운 것은 GPU가 아니었다"* ("The hottest thing in LLM inference
> wasn't the GPU"):
> <https://nacyot.github.io/artifacts/vllm-spin-wait-gb10/>
> All credit for the diagnosis belongs to that author. This repo is an English
> write-up plus tooling, published so the fix is easier to find and apply.

---

## TL;DR

```bash
git clone https://github.com/drowzeys/vllm-gb10-spin-wait-fix.git
cd vllm-gb10-spin-wait-fix

./fleet-temps.sh --trips             # FIRST: your real trip point, not an anecdote
./patch-vllm-spinwait.sh --dry-run   # see what would change
./patch-vllm-spinwait.sh             # patch every vLLM image -> <image>-spinfix
./verify-spinwait.sh                 # confirm, and check running containers
./fleet-temps.sh --watch             # live SoC/GPU/power/clock watch
```

Then serve from the `-spinfix` image instead of the original.

> **The patch alone may not cool your machine.** See **[MITIGATIONS.md](MITIGATIONS.md)** for
> everything we tried and what each actually did — GPU clock capping was the most effective
> lever we found, and none of it is a cure.

---

## The problem

vLLM processes talk to each other over a shared-memory ring buffer. The reader waits
using a **hybrid** strategy in `SpinCondition.wait()`:

```python
def wait(self, timeout_ms=None):
    ...
    if current_time <= self.last_read + self.busy_loop_s:   # default: 1 second
        sched_yield()                         # SPIN: yield the CPU, return immediately
    else:
        self.poller.poll(timeout=timeout_ms)  # SLEEP: wake on a zmq notify socket
```

The intent is sensible: spin briefly (latency), then sleep (power). The bug is the
threshold. `busy_loop_s` defaults to **1 second**, but during decoding messages arrive
every **few milliseconds**. The 1-second gap never happens, so **the sleep branch is
never taken** — the reader spins for the entire life of the request.

Spinning is not free. The core executes instructions continuously (check flag →
`sched_yield` → return), so it stays at full clock, ~**10–20 W per core**. Sleeping
removes the thread from the kernel runqueue and lets the hardware power-gate the core
(~0 W). Same "waiting" — completely different power.

### Why this is a GB10 problem specifically

On a conventional server — 100+ cores, CPU and GPU on separate boards with separate
cooling — four wasted cores are under 5% of capacity and thermally invisible. **GB10
integrates CPU and GPU into one 20-core SoC package sharing one thermal budget.** Four
spinning cores are ~20% of the machine and a large share of that budget, and the heat
lands right next to the GPU.

Reported symptom: **SoC hit 96 °C** (OS force-shutdown at 104.8 °C; users report
shutdowns near 87 °C) **while the GPU itself was only 74 °C**.

---

## How it was diagnosed (original author's method)

Worth reading even if you only want the fix — it's a good template for "the obvious
suspect is innocent" debugging.

1. **Seven thermal zones logged every 15 s** — TSOC, TS1P/TS0P (performance-core
   clusters), TUNC (uncore/memory), TGPU, NVMe, ConnectX-7. TGPU was *not* the hottest.
2. **`mpstat` per-core, not aggregate.** Total CPU showed a harmless-looking 19.3%.
   Per-core showed **four cores pinned at 100%**, all of them 3.9 GHz performance cores.
   Aggregate utilization hides this completely.
3. **`py-spy` stack profiling** located the exact path:
   ```
   sched_yield        (vllm/distributed/utils.py:48)
   wait               (shm_broadcast.py:196)   <- SpinCondition.wait
   acquire_read       (shm_broadcast.py:698)
   dequeue            (shm_broadcast.py:779)
   ```
4. **Physical confirmation by clock-capping.** Capping performance cores at 2.8 GHz
   produced a *distance-dependent* temperature drop — performance cores −14 °C, uncore
   −3.7 °C, GPU −1.7 °C, NVMe ~0 °C. That spatial gradient proves the heat originated at
   the cores, not the GPU. Decode speed was unaffected, proving those cores weren't doing
   useful work.

Things that did **not** help: `VLLM_USE_SPINLOOP_EXT=1` (no change),
`TORCH_NCCL_BLOCKING_WAIT=1` (no change, slight warming), pinning the container to
efficiency cores (−11.3 °C but −8% performance).

---

## The fix

One line in `vllm/distributed/device_communicators/shm_broadcast.py`:

```diff
- busy_loop_s: float = 1,
+ busy_loop_s: float = 0.002,
```

2 ms of spinning, then sleep. The notify socket wakes the thread in tens of
microseconds, so latency is unaffected. **No new code** — it just makes the existing
sleep path reachable.

### Measured by the original author (2× ASUS Ascent GX10, vLLM 0.25.2, TP=2 `mp`, DeepSeek V4 Flash FP8)

| Sensor | 1 s spin (avg/max) | 2 ms spin (avg/max) | Δ avg |
|---|---|---|---|
| TSOC (SoC) | 89.1 / 97 °C | 64.9 / 73 °C | **−24.2 °C** |
| TS1P (perf core) | 87.9 / 97 °C | 60.1 / 73 °C | **−27.8 °C** |
| TS0P (perf core 0) | 85.1 / 91 °C | 59.6 / 62 °C | −25.5 °C |
| TUNC (uncore) | 78.2 / 85 °C | 63.9 / 66 °C | −14.3 °C |
| TGPU | 74.2 / 80 °C | 63.8 / 66 °C | −10.4 °C |
| NVMe | 59.4 / 64 °C | 47.5 / 49 °C | −12.0 °C |

| Metric | 1 s spin | 2 ms spin |
|---|---|---|
| vLLM CPU under load | **333.6%** | **88.7%** |
| Decode c=1 | 52–63 tok/s | 58.0 tok/s |
| Decode c=8 | 154–173 tok/s | 157.8 tok/s |
| GPU utilization | 95% | 96% |

CPU usage down ~73%, throughput unchanged within noise.

---

## Independent measurement — read this before you expect −24 °C

We re-tested on a **single-GPU (TP=1)** DGX Spark serve (Qwen3.8-27B NVFP4, vLLM 0.27.1,
`turboquant_4bit_nc` KV, MTP k=7) and measured **no change at all**.

Method: same container, patch applied and then reverted, `docker restart` plus a 60 s settle
between arms, identical **8 concurrent streams × 2000 tokens** each, sampled every 40 s.

| t | CPU patched (2 ms) | CPU unpatched (1 s) |
|---|---|---|
| 20 s | 104.5% | 104.9% |
| 60 s | 104.1% | 104.5% |
| 100 s | 104.4% | 104.4% |
| 140 s | 104.5% | 103.8% |
| 180 s | 103.6% | 104.5% |

Identical, sample for sample. There is no spin to remove: that ~104% is a single
engine-core process doing real scheduling, sampling and detokenization work.
(SoC temperature differed by a few degrees between arms, but that tracked thermal
history — the patched arm followed earlier load — so CPU is the trustworthy signal.)

That is not a contradiction — it is the expected result. The original measurement is from
**TP=2 with the `mp` backend across two nodes**, where several ranks sit in
`shm_broadcast` waiting. The 333% figure is roughly 3.3 cores spinning; you need multiple
waiters to get there. A TP=1 serve has one engine-core process, so there is simply no
second rank to spin.

**Practical guidance:**

| Deployment | Expect |
|---|---|
| TP ≥ 2, multi-rank, `mp` backend | The large win. This is the reported case. |
| Single GPU, TP=1 | Little or no measurable change. Apply anyway — it is free. |
| Thermally throttled / near shutdown | Try it first. It costs nothing and needs no downtime beyond a restart. |

The patch has **no throughput cost in any configuration**, so there is no reason not to
apply it. Just don't promise anyone −24 °C on a single-GPU box.

---

## Usage

### Patch every vLLM image on the machine

```bash
./patch-vllm-spinwait.sh --dry-run    # list what would be patched
./patch-vllm-spinwait.sh              # build <image>-spinfix for each
./patch-vllm-spinwait.sh --tag-suffix -patched   # custom suffix
```

The script:
- finds candidate images (`vllm`, `sglang`, and common community GB10 tags), or takes explicit image names as arguments
- probes each image for `shm_broadcast.py` and **skips** ones already patched or without it
- builds a thin layer (a few KB — no image copy)
- never modifies the original tag

### Verify

```bash
./verify-spinwait.sh                # all local images + running containers
./verify-spinwait.sh my-image:tag   # one image
```

### Bake it into your own Dockerfile

Guarded so it can never fail a build, even if that image has no vLLM:

```dockerfile
RUN f=$(find /usr/local/lib -name shm_broadcast.py -path "*device_communicators*" 2>/dev/null | head -1); \
    if [ -n "$f" ]; then \
      sed -i 's/busy_loop_s: float = 1,/busy_loop_s: float = 0.002,/' "$f"; \
    fi
```

**Path note:** most images use `/usr/local/lib/python3.*/dist-packages/...`, but some
(e.g. `ghcr.io/aeon-7/aeon-vllm-ultimate`) use `site-packages`. The `find` handles both.

### Patch a running container (temporary)

```bash
./patch-vllm-spinwait.sh --running my-container   # then restart the container
```

⚠️ **This is lost the moment the container is recreated** (`docker run`/`compose up`
after a `rm`). It survives `docker restart` only. For anything permanent, patch the
**image**.

---

## FAQ

**Does this change model output?**
No. It only changes how long a thread spins before sleeping. Sampling, kernels and
weights are untouched.

**Does it hurt latency?**
Not measurably. The notify socket wakes the sleeping thread in tens of microseconds,
far below inter-token time.

**Is it upstream?**
The 1-second default is hardcoded in upstream vLLM main. The original author prepared a
patch to expose it as an environment variable. Until that lands, patch the image. If a
build of yours honors `VLLM_BUSY_LOOP_S`, set it to `0.002` instead.

**Which vLLM versions?**
Everywhere `shm_broadcast.py` has `busy_loop_s: float = 1`. Verified on 0.25.x through
0.27.x. The script checks rather than assuming.

**I'm on a normal server, not GB10 — should I care?**
The CPU waste is identical, but with 100+ cores and separate CPU/GPU cooling it is
usually thermally invisible. It still frees cores.

---

## License

MIT for the scripts in this repo. The original analysis and its measurements belong to
**nacyot** — please read and credit
<https://nacyot.github.io/artifacts/vllm-spin-wait-gb10/>.
