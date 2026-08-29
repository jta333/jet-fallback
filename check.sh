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
  # Not a site: the lead-pipeline canary's dead man's switch. It answers 200
  # while the canary's last fully clean run is recent and 503 once that goes
  # stale, has never happened, or cannot be read. It is here rather than in an
  # email because the canary is deliberately silent when healthy, so this is
  # the only thing that can tell "the lead pipeline is fine" apart from "the
  # thing watching it died". A 5xx is DOWN and a timeout is DOWN, which is
  # exactly the pair of failures worth hearing about. Loop L222.
  "https://jet-command-center-production.up.railway.app/api/lead-canary/health"
)
if [ -n "${EXTRA_URL:-}" ]; then SITES+=("$EXTRA_URL"); fi

UA="Mozilla/5.0 (compatible; JET-uptime; +https://github.com/jta333/jet-fallback)"

# What an alert calls a target. Everything here is a site, and its URL says so
# on a phone screen, with one exception: the canary health probe is a state
# check, not a page, so it gets a name a human can act on. Anything unlisted
# falls back to the URL, so this can never make an existing alert worse.
label_for() {
  case "$1" in
    */api/lead-canary/health) echo "Lead pipeline canary (stale, unreachable, or not deployed)" ;;
    *) echo "$1" ;;
  esac
}

# Which targets must answer 200 exactly, rather than merely answering.
#
# Every site here is a page, and for a page any answer proves reachability, so
# a 4xx counts as UP: a Cloudflare bot challenge or an auth wall is not an
# outage, and the real one was a 522. The canary probe is not a page. Its
# entire contract IS the status code, and the two ways it can be wrong are a
# 503 (the canary went stale) and a 404 (the route is gone, or was never
# deployed). Under the general rule that 404 would read as UP and the dead
# man's switch would sit green forever, which is a check that cannot fail.
strict_200() {
  case "$1" in
    */api/lead-canary/health) return 0 ;;
    *) return 1 ;;
  esac
}

# What a strict target's body must contain for its 200 to be believed.
#
# A status code alone is NOT evidence here, proven against the live URL on
# 2026-08-29: an unauthenticated request to the canary probe answered 307 to
# the sign-in page, and this script follows redirects, so it landed on a 200
# HTML login page. Status-code-only logic would have called a dead man's
# switch that has never once worked UP, forever. Same family of bug as the
# 000000 false-UP caught on 2026-08-14, and the same fix: make the check
# assert the thing it actually cares about.
STRICT_MARKER='"status":"ok"'

REMIND_SECS=3600

check_once() {
  # curl prints the -w code even when it fails (000 on timeout/DNS/connect errors),
  # so no fallback may be appended on failure: "000" + a fallback echo made "000000",
  # which slipped past the != "000" test and read a dead site as UP (caught by the
  # negative control on 2026-08-14). Sanitize to exactly three digits instead.
  local code body
  if strict_200 "$1"; then
    # Strict targets are judged on their body as well as their status, so the
    # response is kept instead of discarded. The code is appended on its own
    # last line so it survives whatever the body contains.
    body=$(curl -sS -L -A "$UA" --max-time 20 -w '
%{http_code}' "$1" 2>/dev/null || true)
    code=$(printf '%s' "$body" | tail -n 1)
  else
    body=""
    code=$(curl -sS -L -A "$UA" -o /dev/null --max-time 20 -w "%{http_code}" "$1" 2>/dev/null || true)
  fi
  code=${code: -3}
  case "$code" in
    [0-9][0-9][0-9]) ;;
    *) code="000" ;;
  esac
  # A strict target that returned 200 WITHOUT its marker did not really answer:
  # that is an auth redirect followed to a login page, or some other stand-in.
  # Report it as no answer, so it can never be read as healthy.
  if [ "$code" = "200" ] && strict_200 "$1"; then
    case "$body" in
      *"$STRICT_MARKER"*) ;;
      *) code="000" ;;
    esac
  fi
  echo "$code"
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
      if strict_200 "$url" && [ "$code" != "200" ]; then
        # It answered, but not with the answer that means healthy. Keep
        # retrying and leave the status down if it never becomes 200.
        status="down"
      else
        status="up"
        break
      fi
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
      down_lines="${down_lines}DOWN: $(label_for "$url") (HTTP ${code})"$'\n'
    elif [ $((now - last_alert)) -ge $REMIND_SECS ]; then
      last_alert=$now
      mins=$(( (now - since) / 60 ))
      down_lines="${down_lines}STILL DOWN: $(label_for "$url") (~${mins} min, HTTP ${code})"$'\n'
    fi
  else
    if [ "$prev" = "down" ]; then
      mins=$(( (now - since) / 60 ))
      up_lines="${up_lines}RECOVERED: $(label_for "$url") (was down ~${mins} min)"$'\n'
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
