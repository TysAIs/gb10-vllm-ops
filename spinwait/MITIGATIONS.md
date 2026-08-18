# GB10 thermal mitigations — what we tried, and what it actually did

Everything below was measured on a five-node DGX Spark (GB10) cluster, 2026-08-16/17,
serving 27B-class models under vLLM 0.27.x. Numbers are single-run unless stated.

**Short version:** the *diagnosis* (CPU, not GPU, is the thermal limiter) reproduced
strongly. No mitigation we tried is a cure. GPU clock capping is the most effective lever
available today, and it costs throughput.

---

## Summary table

| Mitigation | Effort | Effect measured | Verdict |
|---|---|---|---|
| GPU clock cap (uncapped → 1600 MHz) | one command, reversible | package power **−54%**, GPU 69→63 °C, SoC 92→83-90 °C | ⭐ **best available**, partial |
| `busy_loop_s` 1 s → 2 ms patch | image rebuild | **no measurable change at TP=1** | free, keep it, but not a fix here |
| Reading real trip points | 30 seconds | avoided an unnecessary cluster-wide throttle | ⭐ **do this first** |
| Per-node cap verification | one command | caught 2 nodes silently running uncapped | ⭐ **do this** |
| CPU clock limiting | n/a | already applied by vendor (2.808 GHz, not 3.9) | nothing left to reclaim |

---

## 1. GPU clock capping — the most effective lever we found

**What:** lower the GPU clock ceiling with `nvidia-smi -lgc 0,<MHz>`; revert with `-rgc`.

**Measured** on one node under a sustained two-node TP=2 job:

| Clock ceiling | Actual clock | GPU power | GPU temp | SoC temp |
|---|---:|---:|---:|---:|
| uncapped | 2405 MHz | 43.6 W | 69 °C | 92 °C (rising) |
| 2200 MHz | 2177–2184 MHz | 33.3 W | 68 °C | 81–93 °C (oscillating) |
| 1600 MHz | 1521 MHz | 19.9 W | 63 °C | 83–90 °C |

**Verdict: works, partially, and it is instant and reversible.** It does not interrupt
running jobs. But it is a *tourniquet*: it bounds the excursion without curing it, because a
GPU clock ceiling cannot throttle CPU-side work, and the CPU is where the heat is (§4).

**Cost.** Roughly **15% lower fresh-generation throughput** at 2200 MHz vs uncapped on
clock-bound work. Acceptance-bound workloads — where speculative decoding lands many tokens
per forward pass — were nearly unaffected, because they are not clock-limited to begin with.

**Recommendation.** Start at 2200, step down 2100 / 2000, keep the highest ceiling that holds
under *your* workload. Do not assume a number from someone else's cluster transfers.

---

## 2. The `busy_loop_s` patch — free, but not a fix in every configuration

See [README](README.md) for the full A/B. In brief: on a single-GPU (TP=1) serve, patched vs
unpatched container CPU was identical sample-for-sample (104.5/104.1/104.4/104.5/103.6% vs
104.9/104.5/104.4/103.8/104.5%) under an identical 8-stream load. A two-node TP=2 job that
already carried the patch still sustained ~275% CPU per node, versus the 88.7% reported
upstream.

**Verdict: apply it — it costs no throughput — but do not expect it to solve a thermal
problem on a single-GPU box, or on hosts whose CPU cores are already clock-limited.**

---

## 3. Read your actual trip points *before* you intervene

The most valuable 30 seconds in this entire investigation:

```bash
for z in /sys/class/thermal/thermal_zone*; do
  printf "%s %s: trip=%s°C now=%s°C\n" "$(basename $z)" "$(cat $z/type)" \
    "$(( $(cat $z/trip_point_0_temp 2>/dev/null || echo 0) / 1000 ))" \
    "$(( $(cat $z/temp) / 1000 ))"
done
```

We alarmed at **87 °C** because that figure circulates in community reports. Our hardware
trips at **104 °C**. Acting on the wrong number turned a normal thermal equilibrium into a
perceived emergency, and we throttled an entire cluster for nothing — the job would have
finished fine.

**Verdict: do this first, every time, on your own hardware.**

---

## 4. Confirming the heat is CPU-side (diagnosis, not mitigation)

Worth reproducing before you spend effort on GPU-side fixes that cannot work.

```bash
# per-process, not aggregate — aggregate hides a single pegged core
ps -eo pcpu,comm --sort=-pcpu | head -5
# all zones, not just the hottest — look for a localized hot region
for z in /sys/class/thermal/thermal_zone*; do
  printf "%s=%s°C " "$(basename $z)" "$(( $(cat $z/temp)/1000 ))"; done; echo
nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.gr,utilization.gpu --format=csv
```

What we saw at SoC 90 °C: `VLLM::Worker_TP` at **168% CPU** (next process 1.1%), zones 0 and
4 at 90 °C while the rest sat at 66–77 °C, and the **GPU at 63 °C drawing 19.9 W**. A
localized hot region on the CPU side, with an idle-ish GPU.

Two further confirmations, both free:
- Cutting GPU power **54%** did not durably cool the package.
- When the job ended on its own, SoC fell **93 → 65 °C in 60 seconds** — the thermal state
  tracks the compute process, not ambient.

---

## 5. Verify a cap actually applied — per node

Our fleet tooling reported "capped, all nodes OK" **twice** while one node was still running
wide open (2405 MHz while the rest sat at 2177). A central state file or dashboard is not
evidence.

```bash
nvidia-smi --query-gpu=clocks.gr,clocks.max.gr --format=csv,noheader
```

Note `clocks.max.gr` reports the *hardware* maximum (3003 MHz on GB10) even when a software
cap is active — it is **not** a way to verify a cap. Read the achieved clock under load, or
run a brief GPU load and sample the peak.

---

## 6. CPU clock limiting — already done for us

The original report used CPU clock limiting as a pre-patch mitigation (−11.3 °C, at −8%
performance). On our hosts:

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq   # 2808000 = 2.808 GHz
```

Cores are already limited to **2.808 GHz**, not the 3.9 GHz of the original report. That
reclamation appears to be banked already — which is one plausible reason the patch had less
left to recover on our hardware. Worth checking on yours before assuming otherwise.

---

## 7. Things we did *not* try

Listed so nobody assumes they were ruled out:

- Pinning containers to efficiency cores (original author: −11.3 °C, −8% performance)
- `VLLM_USE_SPINLOOP_EXT=1` (original author: no effect)
- `TORCH_NCCL_BLOCKING_WAIT=1` (original author: no effect, slight warming)
- Fan-curve or firmware-level thermal tuning
- Undervolting
- Any change to the physical enclosure, airflow, or ambient temperature

---

## Monitoring

[`fleet-temps.sh`](fleet-temps.sh) prints SoC / GPU / power / clock / container-CPU for one
host or a whole cluster, colour-coded, with `--watch` and `--csv` modes. Set thresholds from
*your* trip points, not from ours:

```bash
./fleet-temps.sh                      # local host
NODES="192.168.0.1 192.168.0.2" ./fleet-temps.sh --watch 10
WARN=92 CRIT=99 ./fleet-temps.sh      # anchor to your trip point, not an anecdote
```

---

## If you test any of this

The open questions are in the [README](README.md#future-study). The cheapest useful
contribution is a **clock sweep** — uncapped / 2200 / 2100 / 2000, logging temperature and
tok/s on one node — which would establish where the thermal-vs-throughput knee actually sits.
Issues and PRs welcome.
