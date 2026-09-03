# jet-fallback

JET's outage kit, built after the 2026-08-13 hosting.com outage (loop L191 in
`jet-claude-central`). Three things live here:

1. **The emergency fallback page** (`index.html`), deployed on Vercel. One static page:
   JET The Agency, phone, email, Jay. It exists so a hosting outage never again means
   a dead screen for a customer.
2. **The uptime monitor** (`.github/workflows/uptime.yml` + `check.sh`). GitHub Actions
   checks all JET sites and apps about every 5 minutes and pushes to ntfy (Jay's phone)
   on the down transition, hourly while down, and once on recovery. DOWN = timeout or
   HTTP 5xx; a 4xx (bot challenge, auth wall) counts as UP because the server answered.
3. **The DNS failover switch** (`scripts/failover.ps1`). One command points
   `jettheagency.com` or `jet.furniture` at the fallback page; one command restores.

## Runbook: a WP site is down

Turn the fallback on (from either laptop):

```
powershell -File scripts/failover.ps1 -Domain jettheagency.com -Mode on
```

When hosting recovers, restore:

```
powershell -File scripts/failover.ps1 -Domain jettheagency.com -Mode off
```

Same for `jet.furniture`. Add `-DryRun` to preview. Requires the Cloudflare token at
`%USERPROFILE%\.claude\secrets\cloudflare-jet-dns-token.txt` (Zone Read + DNS Edit on
both zones).

Full teaching-format documentation of every piece: `jet-claude-central`
`docs/guides/2026-08-14-outage-fallback-and-monitoring.md`.

This repo is public so the uptime schedule gets unlimited GitHub Actions minutes.
Nothing secret lives here: the page content is public by definition, the monitored URLs
are public, and the ntfy topic is a repo secret.

## Make automation health watchdog (`make-health.sh`)

Watches the two Make scenarios that build each new JET project's Google Drive folder
tree, and emails Jay when either stops working.

- **Runs:** `.github/workflows/make-health.yml`, every 15 minutes, plus manual
  `workflow_dispatch` with a `force_test` input that forces a RED so the alert path can
  be proven end to end.
- **Watches:** Make scenarios `2785090` (Google Drive Folder Creation on Item Creation)
  and `2798917` (File Upload Sync to Google Drive Subfolder), and their webhook queues.
- **Unhealthy means:** scenario switched off, flagged invalid by Make, more than
  `QUEUE_LIMIT` events stuck in its webhook queue, or the Make API unreadable. Unreadable
  counts as unhealthy on purpose: a check that cannot run is never a silent pass.
- **Alerts:** one merged email per incident via Resend, sent once on the down transition,
  repeated hourly while unresolved, and once on recovery. Repair steps are selected to
  match the actual cause, so a healthy subsystem is never blamed.
- **Why it lives here and not in Make:** the failure it catches is Make deactivating a
  scenario, so nothing inside Make can be trusted to report it. On 2026-08-25 the Drive
  scenario was auto-deactivated by a revoked Google refresh token and nobody was told for
  nine days.
- **A red run of this workflow means the script itself broke.** A detected problem with
  the scenarios exits 0 and emails instead, so one incident never sends two notifications.

### Secrets it needs

| Secret | What | Where to get it |
| --- | --- | --- |
| `MAKE_API_TOKEN` | Make API token, scopes `scenarios:read` and `hooks:read` | `https://us2.make.com/api-tokens` |
| `RESEND_API_KEY` | Resend sending-only key scoped to `jet.events` | `https://resend.com/api-keys` |
| `ALERT_EMAIL_TO` | optional, defaults to `j@jet.events` | n/a |
