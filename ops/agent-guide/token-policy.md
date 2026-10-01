# `/api/status` Token — Policy and API Reference

**For Boss.** Written 2026-10-01. No secret values appear in this file, by design.

---

## 1. Token stability commitment

**The `/api/status` token has not been rotated, and nothing in this session changed it.**
Verified still live: an unauthenticated request returns `401`, an authenticated one `200`.

One honest caveat on "if you ever rotate it, tell Boss first": a chat session is ephemeral
and cannot hold a standing promise across time — a future session, or a future operator,
has no memory of this conversation. A promise is the wrong mechanism. The durable
mechanism is this written procedure plus the comment already sitting in the nginx config,
which is why both exist.

### Where it lives (two places, must match)

| Location | Purpose | Mode |
|---|---|---|
| `/etc/nginx/conf.d/jakisai-status.conf` | The `map` nginx validates against | root-only |
| `/root/.secrets/jakisai-status-token` | The copy of record | `600`, root-only |

### Rotation procedure — notify Boss BEFORE step 1

1. **Tell Boss.** He must load the new token into the agent's vault *before* the old one
   stops working, or monitoring goes blind.
2. Write the new value to both locations above.
3. `nginx -t && systemctl reload nginx`
4. Confirm: old token → `401`, new token → `200`.

**To revoke instead:** delete the two `map` lines and reload. Monitoring stops immediately.

### Accepted forms

```
Authorization: Bearer <token>        # preferred
?token=<token>                       # query-string fallback — avoid; lands in access logs
```

Prefer the header. The query form is logged to `/var/log/nginx/ops-status.access.log`.

**Rate limit:** 30 requests/minute, burst 20, then `429`. A 30-minute poll uses 0.07% of
that — no risk. Do not tighten the interval below ~2 minutes without raising the zone.

---

## 2. Does the same token work for the Command Center API?

**No.** They are separate systems, and this is the key thing to understand:

| | `/api/status` | Everything else on `ops.jakisai.com` |
|---|---|---|
| Served by | nginx, directly from a static JSON file | Node app on `127.0.0.1:8080` |
| Auth | nginx `map` on a bearer token | Session token from `POST /api/auth/login` |
| Token works? | ✅ | ❌ — returns `401`, the app has never seen that token |
| Session life | Permanent until rotated | `SESSION_DAYS=14`, then re-login |

**`/api/business-status` uses the same token as `/api/status`** — one vault entry, one
rotation, both endpoints. It is served by nginx from a generated file exactly like
`/api/status`, so it is not affected by the dashboard's session auth at all.

One deliberate difference: `/api/business-status` accepts the **header form only**. There is
no `?token=` fallback, because this file carries financial data and a query-string token
would be written to the access log.

The agent still cannot reach the dashboard *app* with this token — but it no longer needs
to, because the business figures now arrive through `/api/business-status`.

---

## 3. Read-only is not available — the blocker

The Command Center's permissions are **section-scoped, not verb-scoped**: the same
`requirePermission(user,'<section>')` guards `GET` and `PATCH` alike. Verified across 11
permissions. None of the 7 roles (`owner`, `manager`, `finance`, `sales`, `technical`,
`support`, `affiliate`) is read-only.

So an account that can *view* money can also *edit* money. No combination of existing
roles or `permissions_json` produces look-but-don't-touch.

Two further wrinkles:

- `POST /api/users` hardcodes `must_change_password = 1`, so an account made through the
  API hits a forced password-change wall on first browser login. A headless agent would
  stall there unless the flag is cleared directly in the database.
- `support` is the lowest-privilege role, but it carries `view_all_clients: false` and no
  `finance` or `commissions` — so it cannot see most of what Boss asked the agent to watch.

### Resolution: a read-only endpoint was built instead — BUILT AND LIVE

No account was created. `/api/business-status` was built on 2026-10-01 following the same
pattern as `status.json`:

| | |
|---|---|
| Collector | `/usr/local/sbin/jakisai-business-collect` |
| Schedule | `jakisai-business.timer` → `.service`, every 10 min |
| Output | `/var/lib/jakisai-status/business.json` (~9 KB, ~0.1 s) |
| DB access | `sqlite mode=ro` — **writes refused by SQLite itself** |
| Hardening | `ProtectSystem=strict`, `ReadWritePaths=/var/lib/jakisai-status`, `NoNewPrivileges` |
| nginx backup | `/root/nginx-backup-20261001-business/` |

Verified after reload: no token → `401`, wrong token → `401`, correct header → `200`,
`?token=` → `401` (by design). Both `/api/status` and the dashboard login page were
re-tested and still return `200`.

This has every property a login lacks: **physically incapable of writing**, no session to
expire, no password, no browser automation, and no prompt-injection surface.

---

## 4. Security note worth one line

A browser-automation agent with a dashboard login has every page it renders inside its
prompt-injection surface — client names, notes, uploaded document titles, message bodies.
If any of that is attacker-influenced (a client-submitted form, an inbound DM), it becomes
instruction-adjacent text in front of an agent holding write access.

The endpoint that was built avoids this entirely: it serves a fixed set of numbers and
names the collector chose, never free-text fields a third party can write into. Client
contact details and document contents are excluded by design. Keep it that way — if a
future check adds client `notes` or message bodies to the feed, that reintroduces the
problem.
