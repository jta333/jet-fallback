#!/usr/bin/env bash
# JET Make-scenario health check. Runs on a GitHub Actions schedule
# (see .github/workflows/make-health.yml), OUTSIDE Make on purpose: the failure
# this exists to catch is Make itself switching a scenario off, so nothing
# inside Make can be trusted to report it.
#
# The incident, 2026-09-03: "Google Drive Folder Creation on Item Creation" was
# auto-deactivated on 2026-08-25 when the Google connection's refresh token was
# revoked (the third revocation: 2026-06-29, 2026-07-21, 2026-08-25). Nobody was
# told. For nine days every new project on the Trade Show board was created with
# no Google Drive folder and no Estimate Request doc, and the team found out by
# noticing the folder was missing.
#
# UNHEALTHY means any of:
#   - the scenario is switched off (isActive false)
#   - Make flagged it invalid (isinvalid true)
#   - its webhook queue has backed up past QUEUE_LIMIT (events arriving, nothing
#     draining them, which is what an off scenario looks like from the outside)
#   - the Make API could not be read at all
# That last one is deliberate: a check that cannot run is RED, never a silent pass.
#
# Alerts are EMAIL via Resend, with numbered repair steps, per the JET alert
# standard. One email per incident however many scenarios it broke: findings are
# merged into a single message. Sent once on the down transition, repeated hourly
# while still down, and once on recovery.
set -uo pipefail

MAKE_BASE="${MAKE_BASE:-https://us2.make.com}"
MAKE_TEAM="${MAKE_TEAM:-1261422}"
ALERT_TO="${ALERT_EMAIL_TO:-j@jet.events}"
ALERT_FROM="${ALERT_EMAIL_FROM:-JET Automation Watchdog <alerts@jet.events>}"
STATE_FILE="${STATE_FILE:-make-health-state.json}"
REMIND_SECS=3600

# A backed-up webhook queue is the outside view of a stalled scenario. The Drive
# scenario polls every 15 minutes and drains one event per run, so a couple in
# flight is normal and anything past this is a stall.
QUEUE_LIMIT="${QUEUE_LIMIT:-4}"

# scenarioId|hookId|what a human calls it|what breaks for the business when it is off
WATCHED=(
  "2785090|1420316|Google Drive Folder Creation on Item Creation|New projects on the Trade Show board get NO Google Drive folder and NO Estimate Request doc."
  "2798917|1420354|File Upload Sync to Google Drive Subfolder|Files uploaded to a Monday project item never reach that project's Drive subfolder."
)

api_get() {
  # Prints the body, then the HTTP code on its own final line. curl prints the
  # -w code even when the request fails, so a transport failure lands as 000 and
  # is read as unhealthy rather than skipped.
  curl -sS -L --max-time 20 \
    -H "Authorization: Token ${MAKE_API_TOKEN}" \
    -w '\n%{http_code}' \
    "$1" 2>/dev/null || true
}

now=$(date -u +%s)
measured_at=$(date -u -d "@${now}" +%Y-%m-%dT%H:%M:%SZ)

[ -s "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

problems=""      # one line per unhealthy scenario, for the email body
problem_count=0
exit_code=0

# Which repair steps this incident actually needs. The alert standard is explicit
# that steps must match the finding: a body that tells Jay to reauthorize a
# healthy Google connection because the WATCHDOG's own token expired sends him to
# fix the wrong subsystem, which is the exact bug that shipped in L222.
fix_watchdog=0   # this checker cannot read Make at all
fix_scenario=0   # a scenario is off or invalid
fix_queue=0      # events are piling up in a hook queue

if [ -z "${MAKE_API_TOKEN:-}" ]; then
  echo "FATAL: MAKE_API_TOKEN is not set. Cannot evaluate; treating as RED."
  problems="Could not check anything: the MAKE_API_TOKEN secret is missing from this workflow, so the watchdog itself is blind."$'\n'
  problem_count=1
  fix_watchdog=1
fi

for row in "${WATCHED[@]}"; do
  [ "$problem_count" = "1" ] && [ -z "${MAKE_API_TOKEN:-}" ] && break

  IFS='|' read -r sid hid sname simpact <<< "$row"

  resp=$(api_get "${MAKE_BASE}/api/v2/scenarios/${sid}")
  code=$(printf '%s' "$resp" | tail -n 1)
  body=$(printf '%s' "$resp" | sed '$d')

  if [ "$code" != "200" ]; then
    problems="${problems}${sname}: could not read its state from Make (HTTP ${code}). Unknown is treated as broken."$'\n'
    problem_count=$((problem_count + 1))
    fix_watchdog=1
    echo "unhealthy ${sid} ${sname} (api ${code})"
    continue
  fi

  # Tolerate both shapes: Make's REST API wraps the object as {"scenario": {...}}
  # while some clients hand back the bare object. Guessing wrong here would pin
  # isActive to false and alert forever, so accept either rather than assume.
  is_active=$(printf '%s' "$body" | jq -r '(.scenario // .) | .isActive // false')
  is_invalid=$(printf '%s' "$body" | jq -r '(.scenario // .) | .isinvalid // false')

  # The hook queue is read separately and is best-effort: a scenario that is ON
  # and valid is not condemned because its queue could not be read.
  qcount=""
  if [ -n "$hid" ]; then
    hresp=$(api_get "${MAKE_BASE}/api/v2/hooks/${hid}")
    hcode=$(printf '%s' "$hresp" | tail -n 1)
    [ "$hcode" = "200" ] && qcount=$(printf '%s' "$hresp" | sed '$d' | jq -r '(.hook // .) | .queueCount // empty')
  fi

  reasons=""
  if [ "$is_active" != "true" ]; then reasons="switched OFF"; fix_scenario=1; fi
  if [ "$is_invalid" = "true" ]; then
    fix_scenario=1
    [ -n "$reasons" ] && reasons="${reasons}, "
    reasons="${reasons}flagged invalid by Make (usually a dead connection)"
  fi
  if [ -n "$qcount" ] && [ "$qcount" -gt "$QUEUE_LIMIT" ] 2>/dev/null; then
    fix_queue=1
    [ -n "$reasons" ] && reasons="${reasons}, "
    reasons="${reasons}${qcount} events stuck in its queue"
  fi

  if [ -n "$reasons" ]; then
    problems="${problems}${sname}: ${reasons}. ${simpact}"$'\n'
    problem_count=$((problem_count + 1))
    echo "unhealthy ${sid} ${sname} (${reasons})"
  else
    echo "healthy ${sid} ${sname} (queue ${qcount:-n/a})"
  fi
done

# Force a red for a live end-to-end test of the alert path. A watchdog nobody has
# watched fire is a guess, so this is how it gets proven without breaking anything.
if [ "${FORCE_TEST:-}" = "true" ]; then
  problems="${problems}TEST: this line was forced by a manual run to prove the alert path works. Nothing is actually wrong."$'\n'
  problem_count=$((problem_count + 1))
  fix_scenario=1
  fix_queue=1
  fix_watchdog=1
fi

prev=$(jq -r '.status // "up"' "$STATE_FILE")
since=$(jq -r '.since // 0' "$STATE_FILE")
last_alert=$(jq -r '.last_alert // 0' "$STATE_FILE")

send_email() {
  local subject="$1" bodytext="$2"
  if [ -z "${RESEND_API_KEY:-}" ]; then
    echo "RESEND_API_KEY not set; would have sent:"
    echo "SUBJECT: ${subject}"
    printf '%s\n' "$bodytext"
    return 0
  fi
  local payload
  payload=$(jq -n --arg from "$ALERT_FROM" --arg to "$ALERT_TO" \
                  --arg subject "$subject" --arg text "$bodytext" \
                  '{from: $from, to: [$to], subject: $subject, text: $text}')
  local out hcode
  out=$(curl -sS --max-time 20 -X POST "https://api.resend.com/emails" \
        -H "Authorization: Bearer ${RESEND_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" -w '\n%{http_code}' 2>/dev/null || true)
  hcode=$(printf '%s' "$out" | tail -n 1)
  if [ "$hcode" != "200" ]; then
    # Resend's own response body carries the real reason. Never log the key.
    echo "WARNING: alert email failed to send (HTTP ${hcode}): $(printf '%s' "$out" | sed '$d')"
    return 1
  fi
  echo "Alert email sent (HTTP 200): ${subject}"
}

if [ "$problem_count" -gt 0 ]; then
  exit_code=1
  should_send="no"
  if [ "$prev" != "down" ]; then
    since=$now
    last_alert=$now
    should_send="first"
  elif [ $((now - last_alert)) -ge $REMIND_SECS ]; then
    last_alert=$now
    should_send="reminder"
  fi
  [ "${FORCE_TEST:-}" = "true" ] && should_send="first"

  mins=$(( (now - since) / 60 ))

  if [ "$should_send" != "no" ]; then
    # The subject names the condition that is actually true, because Jay's Gmail
    # filters route on the first token and he reads the subject before the body.
    if [ "$fix_scenario" = "1" ] || [ "$fix_queue" = "1" ]; then
      headline="JET Drive folder automation is broken, new projects are getting no Drive folder"
    else
      headline="JET automation watchdog cannot read Make, scenario health is UNKNOWN"
    fi
    if [ "$should_send" = "reminder" ]; then
      subject="RED: ${headline}, still unresolved after ~${mins} min (measured ${measured_at})"
    else
      subject="RED: ${headline} (measured ${measured_at})"
    fi

    # Only the steps this incident actually needs, numbered in order. Steps for a
    # subsystem that is healthy are worse than no steps: they send Jay to fix the
    # wrong thing and teach him the alert is noise.
    steps=()
    if [ "$fix_watchdog" = "1" ]; then
      steps+=("This checker could not read Make, so nothing below is confirmed. Open https://us2.make.com/api-tokens and confirm the JET watchdog API token still exists and has the scenarios:read and hooks:read scopes. If it is gone, add a new token there, then paste it into https://github.com/jta333/jet-fallback/settings/secrets/actions as MAKE_API_TOKEN.")
    fi
    if [ "$fix_scenario" = "1" ]; then
      steps+=("Open Make Connections at https://us2.make.com/${MAKE_TEAM}/connections and find \"My Google connection\". There are two with that name: pick the Google Restricted one on j@jet.events, NOT the developerproto one. Click Reauthorize and sign in as j@jet.events. This is the usual cause; that refresh token has now been revoked three times (2026-06-29, 2026-07-21, 2026-08-25).")
      steps+=("Open https://us2.make.com/${MAKE_TEAM}/scenarios/2785090/edit and switch the scenario ON with the Scheduling toggle at the bottom left.")
      steps+=("Open https://us2.make.com/${MAKE_TEAM}/scenarios/2798917/edit and switch that one ON the same way.")
    fi
    if [ "$fix_scenario" = "1" ] || [ "$fix_queue" = "1" ]; then
      steps+=("Anything created while it was off is queued and builds itself within about 15 minutes per project. To clear a backlog faster, press \"Run once\" on https://us2.make.com/${MAKE_TEAM}/scenarios/2785090/edit and wait for it to finish, once per queued project.")
      steps+=("If either scenario shows an INCOMPLETE EXECUTIONS tab, open it, select all, and click Discard. Do NOT use Resolve or retry: a retry now would build a second, duplicate Drive folder for a project that already has one.")
    fi

    fixblock=""
    n=0
    for st in "${steps[@]}"; do
      n=$((n + 1))
      fixblock="${fixblock}${n}. ${st}"$'
'
    done

    if [ "$fix_scenario" = "1" ] || [ "$fix_queue" = "1" ]; then
      donewhen="Both scenarios show their Scheduling toggle green, and the newest item on the Trade Show Booths & Events board has a link in its Project Folder column within 15 minutes."
    else
      donewhen="The next run of this watchdog reports the scenarios as healthy instead of unreadable. Runs at https://github.com/jta333/jet-fallback/actions/workflows/make-health.yml"
    fi

    read -r -d '' body <<EOF || true
WHAT HAPPENED
${problem_count} JET Make automation check(s) came back unhealthy at ${measured_at} UTC:

$(printf '%s' "$problems" | sed 's/^/  - /')

WHY IT MATTERS
These automations are what give every new project on the Trade Show Booths & Events
board its Google Drive folder tree, its Estimate Request doc, and its file sync. While
they are down, projects get created with nothing behind them and the team only finds out
by opening the Project Folder column and seeing it empty. The last outage ran nine days
before anyone noticed.

FIX IT
${fixblock}
DONE WHEN
${donewhen}

Board: https://jet-the-agency.monday.com/boards/5709044383

If this is wrong or already fixed, reply and it gets tuned.
EOF
    send_email "$subject" "$body" || true
  else
    echo "Still down, next reminder in $(( (REMIND_SECS - (now - last_alert)) / 60 )) min."
  fi

  jq -n --argjson la "$last_alert" --argjson si "$since" \
    '{status: "down", last_alert: $la, since: $si}' > "$STATE_FILE"
else
  if [ "$prev" = "down" ]; then
    mins=$(( (now - since) / 60 ))
    read -r -d '' rbody <<EOF || true
WHAT HAPPENED
All watched JET Make automations were healthy again when checked at ${measured_at} UTC,
after roughly ${mins} minutes unhealthy.

WHY IT MATTERS
New projects on the Trade Show Booths & Events board are building their Drive folders
again. Anything created during the outage should have caught up from the queue.

FIX IT
1. Open the Trade Show board at https://jet-the-agency.monday.com/boards/5709044383 and
   check that every project created during the outage now has a link in its Project
   Folder column.
2. Any row still empty after 15 minutes: press "Run once" on
   https://us2.make.com/${MAKE_TEAM}/scenarios/2785090/edit until its queue is empty.

DONE WHEN
No project created during the outage has an empty Project Folder column.

If this is wrong or already fixed, reply and it gets tuned.
EOF
    send_email "GREEN: JET Drive folder automation recovered after ~${mins} min (measured ${measured_at})" "$rbody" || true
  fi
  echo '{"status": "up", "last_alert": 0, "since": 0}' > "$STATE_FILE"
fi

# Always exit 0 when the check RAN, even if it found a problem: the email is the
# signal, and a non-zero exit here would fire a GitHub Actions failure email for
# the same incident, which is the alert-multiplying the standard forbids. That
# leaves a red workflow run meaning exactly one thing: this script itself broke.
echo "check complete, problems=${problem_count}, exit_code_would_have_been=${exit_code}"
exit 0
