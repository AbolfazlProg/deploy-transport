#!/usr/bin/env bash
set -uo pipefail
# B4-D 2026-11-28 — resilient range-piece download + docker load + staged swap for e3201742 (CH02-B4, PR #213)
D=e320174213ac4af5ac0d781681eaea5481f5dae3
PREV=69a58a6e9723ddf07a276423188f29f1af7ff61c
ARCHIVE_SHA=17f2045f803acf9ec7ae9efb912f8f1baff224df5912328f1d3b53cddc17a6d4
IMAGE="ghcr.io/abolfazlprog/hanaso:${D}"
SRC=/opt/hanaso-src
DEPLOY_ENV="${SRC}/infra/deploy/learn-kotodama/.env"
CC() { docker compose -f "${SRC}/infra/deploy/learn-kotodama/docker-compose.shared-vps.yml" \
             -f "${SRC}/infra/deploy/learn-kotodama/docker-compose.hanaso-ir-1core.yml" \
             --env-file "${DEPLOY_ENV}" "$@"; }
T=/root/b4-transport/e3201742
mkdir -p "${T}"; cd "${T}"
BASE="https://raw.githubusercontent.com/AbolfazlProg/deploy-transport/main/e3201742"

dl_small() { # url out size
  local url="$1" out="$2" want="$3" n=0 have
  while :; do
    have=$(stat -c%s "${out}" 2>/dev/null || echo 0)
    [ "${have}" = "${want}" ] && { echo "have ${out}"; return 0; }
    n=$((n+1)); [ "${n}" -gt 120 ] && { echo "STUCK ${out}"; return 1; }
    curl -4 -sL --connect-timeout 12 --speed-time 45 --speed-limit 2048 --max-time 120 -C - -o "${out}" "${url}" || sleep 3
  done
}

dl_file() { # url out size  (4MB range pieces, resume inside pieces)
  local url="$1" out="$2" size="$3" piece=4194304 pos=0
  [ "$(stat -c%s "${out}" 2>/dev/null || echo 0)" = "${size}" ] && { echo "have ${out}"; return 0; }
  while [ ${pos} -lt ${size} ]; do
    local end=$((pos+piece-1)); [ ${end} -ge ${size} ] && end=$((size-1))
    local want=$((end-pos+1)) have=0 newsz
    [ -f "${out}.p${pos}" ] && have=$(stat -c%s "${out}.p${pos}")
    if [ ${have} -lt ${want} ]; then
      curl -4 -s --connect-timeout 12 --speed-time 45 --speed-limit 2048 --max-time 240 \
        -r $((pos+have))-${end} -o "${out}.n" "${url}" || true
      if [ -s "${out}.n" ]; then
        newsz=$(stat -c%s "${out}.n")
        [ "${newsz}" -gt $((want-have)) ] && truncate -s $((want-have)) "${out}.n"
        cat "${out}.n" >> "${out}.p${pos}"
      fi
      rm -f "${out}.n"
    fi
    have=$(stat -c%s "${out}.p${pos}" 2>/dev/null || echo 0)
    if [ ${have} -ge ${want} ]; then pos=$((end+1));
      echo "  ${out}: $((pos*100/size))%"
    else
      sleep 3
    fi
  done
  cat $(ls -v "${out}".p*) > "${out}"
  rm -f "${out}".p* "${out}".n
  echo "done ${out} ($(stat -c%s "${out}") B)"
}

echo "== D0) disk + pre-deploy backup $(date -u +%T) =="
df -h / | tail -1
TS=$(date -u +%Y%m%dT%H%M%SZ)
docker exec hanaso-postgres pg_dump -U hanaso -d hanaso --no-owner > "/root/hanaso-backups/db-pre-b4-${TS}.sql" 2>/dev/null \
  && echo "backup: /root/hanaso-backups/db-pre-b4-${TS}.sql ($(du -h /root/hanaso-backups/db-pre-b4-${TS}.sql | cut -f1))" \
  || echo "WARN: pg_dump failed (continuing — no migrations expected in this deploy)"
cp "${DEPLOY_ENV}" "${DEPLOY_ENV}.pre-b4"

echo "== D1) resilient download $(date -u +%T) =="
CHUNKS=""
for c in 00 01 02 03 04 05 06 07 08 09 10 11 12; do CHUNKS="${CHUNKS} chunk${c}.part"; done
for f in ${CHUNKS}; do
  sz=$(python3 -c "print($(stat -c%s /nonexistent 2>/dev/null || echo 0))" 2>/dev/null || echo 0)
  :
done
# sizes read from the REAL chunk.sha256s listing (12x30131520 + 6400 last)
for c in 00 01 02 03 04 05 06 07 08 09 10 11; do
  dl_file "${BASE}/chunk${c}.part" "chunk${c}.part" 30131520 || exit 1
done
dl_file "${BASE}/chunk12.part" "chunk12.part" 6400 || exit 1
dl_small "${BASE}/archive.sha256" archive.sha256 91 || exit 1
dl_small "${BASE}/chunk.sha256s" chunk.sha256s 1027 || exit 1
wc -c archive.sha256 chunk.sha256s

echo "== D2) verify chunks =="
sed 's|e3201742/||' chunk.sha256s | sha256sum -c - || exit 1

echo "== D3) reassemble + verify archive =="
cat ${CHUNKS} > hanaso-image-e3201742.docker.tar
echo "${ARCHIVE_SHA}  hanaso-image-e3201742.docker.tar" | sha256sum -c - || exit 1

echo "== D4) docker load $(date -u +%T) =="
docker load -i hanaso-image-e3201742.docker.tar || exit 1

echo "== D5) sync source to D =="
git -C "${SRC}" fetch origin main --quiet
git -C "${SRC}" checkout -q --detach "${D}"
[ "$(git -C "${SRC}" rev-parse HEAD)" = "${D}" ] || { echo "checkout mismatch — abort"; exit 1; }
git -C "${SRC}" status --porcelain -- infra/deploy/learn-kotodama/ | head -3

echo "== D6) swap image line in .env =="
sed -i "s|^HANASO_WEB_IMAGE=.*|HANASO_WEB_IMAGE=${IMAGE}|" "${DEPLOY_ENV}"
grep -oE '^HANASO_WEB_IMAGE=.*' "${DEPLOY_ENV}"

echo "== D7) migrate (idempotent) =="
CC run --rm migrate 2>&1 | tail -4

echo "== D8) staged swap $(date -u +%T) =="
CC up -d --no-deps web worker

echo "== D9) health gate =="
for i in $(seq 1 40); do
  H=$(curl -fsS --max-time 5 http://127.0.0.1:3100/api/health || true)
  echo "${H}" | grep -q '"ok":true' && echo "${H}" | grep -q "\"commit\":\"${D}\"" && break
  sleep 3
done
echo "tier1: ${H:-FAILED}"
if ! echo "${H:-}" | grep -q "\"commit\":\"${D}\""; then
  echo "TIER1 FAILED — rolling back to ${PREV:0:7}"
  sed -i "s|^HANASO_WEB_IMAGE=.*|HANASO_WEB_IMAGE=ghcr.io/abolfazlprog/hanaso:${PREV}|" "${DEPLOY_ENV}"
  CC up -d --no-deps web worker
  exit 1
fi
echo "tier1 ok: commit=${D:0:12}"

echo "== D10) ready =="
curl -fsS --max-time 10 http://127.0.0.1:3100/api/ready | head -c 300; echo

echo "== D11) cleanup =="
rm -f hanaso-image-e3201742.docker.tar
rm -f ${CHUNKS}
df -h / | tail -1

echo "== D12) final identity $(date -u +%T) =="
curl -fsS --max-time 10 https://hanaso.ir/api/health | head -c 300; echo
docker ps --format '{{.Names}} | {{.Image}} | {{.Status}}' | grep -E 'hanaso-(web|worker)'
echo "DEPLOY B4 DONE — live commit ${D}"
