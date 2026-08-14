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
