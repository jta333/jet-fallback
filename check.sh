#!/usr/bin/env bash
# JET uptime check. Runs on a GitHub Actions schedule (see .github/workflows/uptime.yml).
# DOWN means: connection failure/timeout, or HTTP 5xx after retries. 4xx counts as UP,
# because a Cloudflare bot challenge or an auth wall proves the site is reachable.
# Alerts go to ntfy (Jay's phone): once on the down transition, a reminder every hour
# while still down, and once on recovery.
set -uo pipefail

SITES=(
  "https://jettheagency.com"
  "https://jet.furniture"
  "https://jetexhibits.com"
  "https://jet-crm-sepia.vercel.app"
  "https://jet-ops-hub.vercel.app"
  "https://jetestimatebuilder.netlify.app"
  "https://jet-bematrix-calc.netlify.app"
  "https://jet-command-center-production.up.railway.app"
)
if [ -n "${EXTRA_URL:-}" ]; then SITES+=("$EXTRA_URL"); fi

UA="Mozilla/5.0 (compatible; JET-uptime; +https://github.com/jta333/jet-fallback)"
REMIND_SECS=3600

check_once() {
  # curl prints the -w code even when it fails (000 on timeout/DNS/connect errors),
  # so no fallback may be appended on failure: "000" + a fallback echo made "000000",
  # which slipped past the != "000" test and read a dead site as UP (caught by the
  # negative control on 2026-08-14). Sanitize to exactly three digits instead.
  local code
  code=$(curl -sS -L -A "$UA" -o /dev/null --max-time 20 -w "%{http_code}" "$1" 2>/dev/null || true)
  code=${code: -3}
  case "$code" in
    [0-9][0-9][0-9]) echo "$code" ;;
    *) echo "000" ;;
  esac
}

[ -s state.json ] || echo '{}' > state.json
now=$(date -u +%s)
new_state='{}'
down_lines=""
up_lines=""

for url in "${SITES[@]}"; do
  code="000"
  status="down"
  for attempt in 1 2 3; do
    code=$(check_once "$url")
    if [ "$code" != "000" ] && [ "$code" -lt 500 ]; then
      status="up"
      break
    fi
    [ "$attempt" -lt 3 ] && sleep 10
  done

  prev=$(jq -r --arg u "$url" '.[$u].status // "up"' state.json)
  since=$(jq -r --arg u "$url" '.[$u].since // 0' state.json)
  last_alert=$(jq -r --arg u "$url" '.[$u].last_alert // 0' state.json)

  if [ "$status" = "down" ]; then
    if [ "$prev" != "down" ]; then
      since=$now
      last_alert=$now
      down_lines="${down_lines}DOWN: ${url} (HTTP ${code})"$'\n'
    elif [ $((now - last_alert)) -ge $REMIND_SECS ]; then
      last_alert=$now
      mins=$(( (now - since) / 60 ))
      down_lines="${down_lines}STILL DOWN: ${url} (~${mins} min, HTTP ${code})"$'\n'
    fi
  else
    if [ "$prev" = "down" ]; then
      mins=$(( (now - since) / 60 ))
      up_lines="${up_lines}RECOVERED: ${url} (was down ~${mins} min)"$'\n'
    fi
    since=0
    last_alert=0
  fi

  echo "${status} ${code} ${url}"
  new_state=$(jq --arg u "$url" --arg s "$status" --argjson la "$last_alert" --argjson si "$since" \
    '.[$u] = {status: $s, last_alert: $la, since: $si}' <<< "$new_state")
done

printf '%s' "$new_state" > state.json

if [ -z "${NTFY_TOPIC:-}" ]; then
  echo "NTFY_TOPIC secret not set; skipping alerts."
  exit 0
fi

if [ -n "$down_lines" ]; then
  curl -sS --max-time 15 \
    -H "Title: JET site DOWN" \
    -H "Priority: urgent" \
    -H "Tags: rotating_light" \
    -d "$down_lines" \
    "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null || echo "WARNING: ntfy down-alert failed to send"
fi

if [ -n "$up_lines" ]; then
  curl -sS --max-time 15 \
    -H "Title: JET site recovered" \
    -H "Tags: white_check_mark" \
    -d "$up_lines" \
    "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null || echo "WARNING: ntfy recovery alert failed to send"
fi

exit 0
