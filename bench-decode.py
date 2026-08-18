#!/usr/bin/env python3
"""bench-decode.py — canonical c=1 decode tok/s benchmark for GB10 endpoints.

Measures PURE decode rate (tokens after first token / time after first token),
streaming, per MiaAI's benchmark-0731.py methodology. This is the ONLY number that
should be called "decode tok/s". Total-time methods (tokens/wallclock incl TTFT)
understate decode by ~40% at short prompts — see the accurate-tokens-per-second skill.

USAGE:
  python3 bench-decode.py --url http://node0:8888/v1 --model deepseek-v4-flash-0731
  python3 bench-decode.py --url http://node0:8889/v1 --model qwen38-27b-unsloth-nvfp4

KNOWN GOOD (2026-08-18, TP2 DS4, 2200 cap): official 70.4, abliterated 64.6 tok/s.
--think-budget 64 is REQUIRED (default) — without it reasoning eats the window (~47 tok/s).
"""
import argparse, json, statistics, time, urllib.request


def stream_decode(url, model, prompt, think_budget=None, max_tokens=512,
                  temperature=0.6, top_p=0.95, timeout=300):
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "stream_options": {"include_usage": True},
        "temperature": temperature,
        "top_p": top_p,
        "max_tokens": max_tokens,
    }
    if think_budget is not None:
        body["thinking_token_budget"] = think_budget
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    t0 = time.time()
    first_token_t = None
    usage = {}
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except Exception:
                continue
            # DS4 vLLM streams reasoning tokens via delta.reasoning and content via
            # delta.content; either one counts as "first token" for decode timing.
            if not first_token_t and chunk.get("choices"):
                delta = chunk["choices"][0].get("delta", {})
                if isinstance(delta, dict) and (delta.get("content") or delta.get("reasoning")):
                    first_token_t = time.time()
            if chunk.get("usage"):
                usage = chunk["usage"]
    t1 = time.time()
    total = usage.get("completion_tokens", 0)
    reasoning = usage.get("reasoning_tokens", 0)
    if not first_token_t or total <= 1:
        return None, total, reasoning, None, None
    decode_tokens = total - 1
    decode_time = t1 - first_token_t
    ttft_ms = (first_token_t - t0) * 1000
    rate = decode_tokens / decode_time if decode_time > 0 else 0.0
    return rate, total, reasoning, ttft_ms, decode_time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://node0:8888/v1/chat/completions")
    ap.add_argument("--model", required=True)
    ap.add_argument("--trials", type=int, default=5)
    ap.add_argument("--warmup", type=int, default=2, help="discarded warmup runs")
    ap.add_argument("--think-budget", type=int, default=64,
                    help="thinking_token_budget (DS4 issue31-v2). REQUIRED for correct "
                         "decode numbers — without it reasoning eats the window (~47 vs ~64 tok/s)")
    ap.add_argument("--prompt", default=(
        "Write a short paragraph about renewable energy technologies.\n"
        "Return exactly 128 numbered lowercase english words, then stop."))
    a = ap.parse_args()

    rates = []
    for i in range(a.warmup + a.trials):
        rate, total, reasoning, ttft, dtime = stream_decode(
            a.url, a.model, a.prompt, a.think_budget)
        if i < a.warmup:
            print(f"warmup {i+1}: ok" if rate else f"warmup {i+1}: no-decode")
            continue
        if rate is None:
            print(f"trial{i+1-a.warmup}: NO VALID DECODE (total={total}, reasoning={reasoning})")
            continue
        rates.append(rate)
        print(f"trial{i+1-a.warmup}: {total} tok (reasoning={reasoning}) "
              f"TTFT={ttft:.0f}ms, decode {total-1} tok / {dtime:.2f}s = {rate:.1f} tok/s")
    if rates:
        print(f"\nMEAN c=1 decode: {statistics.mean(rates):.1f} ± "
              f"{statistics.stdev(rates):.1f} tok/s ({len(rates)} trials)")
        print(f"MIN/MAX: {min(rates):.1f} / {max(rates):.1f}")


if __name__ == "__main__":
    main()
