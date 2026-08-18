#!/usr/bin/env bash
# =============================================================================
# patch-vllm-spinwait.sh — apply the GB10 vLLM spin-wait fix to your containers
# =============================================================================
# Original analysis (Korean): https://nacyot.github.io/artifacts/vllm-spin-wait-gb10/
#
# vLLM's SpinCondition.wait() spins for busy_loop_s=1s before falling back to sleep.
# Decode messages arrive every few milliseconds, so the sleep path is never reached and
# CPU cores spin at full clock (~10-20W each). On GB10 the CPU and GPU share one SoC
# thermal budget, so that heat competes with the GPU. 1s -> 2ms fixes it, with no
# throughput cost.
#
#   ./patch-vllm-spinwait.sh                  patch all detected vLLM images
#   ./patch-vllm-spinwait.sh --dry-run        show what would be patched
#   ./patch-vllm-spinwait.sh img:tag [...]    patch specific images
#   ./patch-vllm-spinwait.sh --running NAME   patch a RUNNING container (temporary!)
#   ./patch-vllm-spinwait.sh --tag-suffix -x  suffix for patched tags (default -spinfix)
#
# Patched images are NEW tags: <image><suffix>. Originals are never modified.
# =============================================================================
set -uo pipefail

SUFFIX="-spinfix"
DRY=0
RUNNING=""
declare -a EXPLICIT=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY=1; shift ;;
    --tag-suffix) SUFFIX="${2:?--tag-suffix needs a value}"; shift 2 ;;
    --running)    RUNNING="${2:?--running needs a container name}"; shift 2 ;;
    -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
    -*)           echo "unknown option: $1" >&2; exit 2 ;;
    *)            EXPLICIT+=("$1"); shift ;;
  esac
done

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

SED_EXPR='s/busy_loop_s: float = 1,/busy_loop_s: float = 0.002,/'
FIND_EXPR='find /usr/local/lib /usr/lib /opt -name shm_broadcast.py -path "*device_communicators*" 2>/dev/null | head -1'

# ---------------------------------------------------------------- running container
if [ -n "$RUNNING" ]; then
  echo "!! Patching a RUNNING container. This is LOST when the container is recreated."
  echo "!! For a permanent fix, patch the image instead."
  f=$(docker exec "$RUNNING" bash -lc "$FIND_EXPR" 2>/dev/null | tr -d '\r')
  [ -z "$f" ] && { echo "no shm_broadcast.py in $RUNNING"; exit 1; }
  if docker exec "$RUNNING" grep -q 'busy_loop_s: float = 0.002,' "$f" 2>/dev/null; then
    echo "already patched: $RUNNING ($f)"; exit 0
  fi
  docker exec "$RUNNING" sed -i "$SED_EXPR" "$f" || { echo "sed failed" >&2; exit 1; }
  docker exec "$RUNNING" grep -n 'busy_loop_s: float' "$f" | head -2
  echo "patched $RUNNING — restart it to take effect:  docker restart $RUNNING"
  exit 0
fi

# ---------------------------------------------------------------- select images
declare -a IMAGES=()
if [ ${#EXPLICIT[@]} -gt 0 ]; then
  IMAGES=("${EXPLICIT[@]}")
else
  mapfile -t IMAGES < <(docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -v '<none>' \
    | grep -v -- "${SUFFIX}\$" \
    | grep -iE 'vllm|sglang|nvfp4|dspark|dflash|aeon|gb10|spark|b12x' \
    | sort -u)
fi

[ ${#IMAGES[@]} -eq 0 ] && { echo "no candidate images found (pass image names explicitly)"; exit 0; }

echo "candidates: ${#IMAGES[@]}"
patched=0; skipped=0; failed=0

for img in "${IMAGES[@]}"; do
  out="${img}${SUFFIX}"

  if docker image inspect "$out" >/dev/null 2>&1; then
    echo "  SKIP  already built : $out"; skipped=$((skipped+1)); continue
  fi

  probe=$(docker run --rm --entrypoint bash "$img" -lc \
    "f=\$($FIND_EXPR);
     if [ -z \"\$f\" ]; then echo NOFILE;
     elif grep -q 'busy_loop_s: float = 0.002,' \"\$f\"; then echo ALREADY;
     else echo \"\$f\"; fi" 2>/dev/null | tr -d '\r' | tail -1)

  case "$probe" in
    NOFILE)  echo "  SKIP  no vLLM shm_broadcast : $img"; skipped=$((skipped+1)); continue ;;
    ALREADY) echo "  SKIP  already patched       : $img"; skipped=$((skipped+1)); continue ;;
    "")      echo "  SKIP  probe failed          : $img"; skipped=$((skipped+1)); continue ;;
  esac

  if [ "$DRY" = "1" ]; then
    echo "  WOULD PATCH $img -> $out   ($probe)"; continue
  fi

  if printf 'FROM %s\nRUN sed -i "%s" "%s" && grep -n "busy_loop_s: float = 0.002," "%s"\n' \
        "$img" "$SED_EXPR" "$probe" "$probe" | docker build -q -t "$out" - >/dev/null 2>&1; then
    echo "  PATCHED $out"; patched=$((patched+1))
  else
    echo "  FAILED  $img"; failed=$((failed+1))
  fi
done

echo
echo "patched=$patched skipped=$skipped failed=$failed"
[ "$DRY" = "1" ] && echo "(dry run — nothing was built)"
[ "$patched" -gt 0 ] && cat <<EOF

Next: serve from the patched tag, e.g.
  docker run ... <your-image>${SUFFIX} ...
Verify with:  ./verify-spinwait.sh
EOF
exit 0
