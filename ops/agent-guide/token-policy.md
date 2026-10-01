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

The agent cannot reach client, money or commission data with the status token. That
requires a logged-in account — which is the open decision in
`command-center-guide.md` §5.

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

### Recommended path: extend the pattern that already works

Rather than create a write-capable login, generate a second read-only JSON file the same
way `status.json` is produced, exposing only the business figures the agent needs
(client health colours, unpaid invoice count, pending payouts, new critical alerts), and
serve it at `/api/business-status` behind its own token.

This inherits every property that makes the current setup safe: **physically incapable of
writing**, no session to expire, no password to rotate, no browser automation needed, and
the agent's existing polling code barely changes. It is strictly better than a login for a
monitoring agent.

---

## 4. Security note worth one line

A browser-automation agent with a dashboard login has every page it renders inside its
prompt-injection surface — client names, notes, uploaded document titles, message bodies.
If any of that is attacker-influenced (a client-submitted form, an inbound DM), it becomes
instruction-adjacent text in front of an agent holding write access. The read-only JSON
endpoint above removes this concern entirely; a login does not.
