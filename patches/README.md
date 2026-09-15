# Moonveil cloud patches (rebase-able series on v2.0.0)

Baseline: AA release tag `v2.0.0`. Each item is a commit on `moonveil` branch.

| ID | Title | Status | Why (no upstream equiv / hardening) |
|----|-------|--------|-------------------------------------|
| P0 | AGENT_SERVER_SECRET fail-fast (auth.py:17) | DONE | D3 R1: code-published literal default = anyone forges connector/attachment tokens. We delete the default, require env. |
| P1 | own-aud `moonveil-mobile` registration | TODO | D3: prevent two-cloud token cross-auth. Server must accept our client aud; G3 uses upstream aud for first round-trip, swap at hardening. |
| P2 | vendor httpx-s3-client mirror | TODO | 02-findings: only external git dep is an author's personal repo; mirror into patches/vendor to survive upstream removal. |
| P3 | global rate limit | TODO | upstream only has email rate limit; add per-IP/per-account limiter at the gateway. |
| P4 | split browser API base from SSR target (web-next/next.config.ts) | DONE | Deployment-shape, not a feature cut: official gets an empty browser base for free because it serves the static export from the API server (single origin). Our web runs as its own SSR service, and `browserApiTarget = apiTarget` baked `http://127.0.0.1:8000` into 2/17 client chunks — a remote browser then calls its own loopback (and mixed-content-blocked under HTTPS). Adds `AGENTS_ANYWHERE_BROWSER_API` (empty => same-origin relative, what the edge expects); SSR-side `AGENTS_ANYWHERE_API` keeps the in-network target and is also corrected to `http://server:8000`. |

Upgrade discipline: on new AA tag, `git rebase moonveil --onto <newtag>` then run contracts fixtures diff before promoting.
