#!/usr/bin/env bash
# =============================================================================
# verify-spinwait.sh — report spin-wait patch status for images and containers
# =============================================================================
#   ./verify-spinwait.sh              all local vLLM images + running containers
#   ./verify-spinwait.sh img:tag ...  specific images
# Exit code 0 always (report tool).
# =============================================================================
set -uo pipefail
FIND_EXPR='find /usr/local/lib /usr/lib /opt -name shm_broadcast.py -path "*device_communicators*" 2>/dev/null | head -1'

check_image() {
  local img="$1"
  local r
  r=$(docker run --rm --entrypoint bash "$img" -lc \
    "f=\$($FIND_EXPR);
     if [ -z \"\$f\" ]; then echo 'n/a       (no vLLM shm_broadcast)';
     else grep -oE 'busy_loop_s: float = [0-9.]+' \"\$f\" | head -1; fi" 2>/dev/null | tr -d '\r' | tail -1)
  case "$r" in
    *"= 0.002"*) printf "  \033[1;32mPATCHED\033[0m   %-60s %s\n" "$img" "$r" ;;
    *"= 1"*)     printf "  \033[1;31mUNPATCHED\033[0m %-60s %s\n" "$img" "$r" ;;
    *)           printf "  ---       %-60s %s\n" "$img" "${r:-probe failed}" ;;
  esac
}

echo "=== IMAGES ==="
if [ $# -gt 0 ]; then
  for i in "$@"; do check_image "$i"; done
else
  mapfile -t imgs < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' \
      | grep -iE 'vllm|sglang|nvfp4|dspark|dflash|aeon|gb10|spark|b12x' | sort -u)
  [ ${#imgs[@]} -eq 0 ] && echo "  (no candidate images)"
  for i in "${imgs[@]}"; do check_image "$i"; done
fi

echo
echo "=== RUNNING CONTAINERS ==="
found=0
while read -r name; do
  [ -z "$name" ] && continue
  f=$(docker exec "$name" bash -lc "$FIND_EXPR" 2>/dev/null | tr -d '\r')
  [ -z "$f" ] && continue
  found=1
  v=$(docker exec "$name" grep -oE 'busy_loop_s: float = [0-9.]+' "$f" 2>/dev/null | head -1)
  case "$v" in
    *"= 0.002"*) printf "  \033[1;32mPATCHED\033[0m   %-40s %s\n" "$name" "$v" ;;
    *"= 1"*)     printf "  \033[1;31mUNPATCHED\033[0m %-40s %s\n" "$name" "$v" ;;
    *)           printf "  ---       %-40s %s\n" "$name" "${v:-unknown}" ;;
  esac
done < <(docker ps --format '{{.Names}}')
[ "$found" = "0" ] && echo "  (no running container exposes vLLM shm_broadcast)"

cat <<'EOF'

Reminder: a patch applied to a RUNNING container survives `docker restart` but is LOST
when the container is recreated (docker rm + run, compose up). Patch the IMAGE for a
permanent fix:  ./patch-vllm-spinwait.sh
EOF
