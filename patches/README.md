# Moonveil cloud patches (rebase-able series on v2.0.0)

Baseline: AA release tag `v2.0.0`. Each item is a commit on `moonveil` branch.

| ID | Title | Status | Why (no upstream equiv / hardening) |
|----|-------|--------|-------------------------------------|
| P0 | AGENT_SERVER_SECRET fail-fast (auth.py:17) | DONE | D3 R1: code-published literal default = anyone forges connector/attachment tokens. We delete the default, require env. |
| P1 | own-aud `moonveil-mobile` registration | TODO | D3: prevent two-cloud token cross-auth. Server must accept our client aud; G3 uses upstream aud for first round-trip, swap at hardening. |
| P2 | vendor httpx-s3-client mirror | TODO | 02-findings: only external git dep is an author's personal repo; mirror into patches/vendor to survive upstream removal. |
| P3 | global rate limit | TODO | upstream only has email rate limit; add per-IP/per-account limiter at the gateway. |

Upgrade discipline: on new AA tag, `git rebase moonveil --onto <newtag>` then run contracts fixtures diff before promoting.
