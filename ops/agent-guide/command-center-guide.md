# Command Center — Monitoring Guide for the Muse Agent

**Target:** `https://ops.jakisai.com` · **App:** `/opt/jakisai-command-center/server.js` (Node, `127.0.0.1:8080`)
**Written:** 2026-10-01 · Verified against the live app and database, not inferred.

---

## 0. ACCESS STATUS — READ FIRST

**No dashboard login exists, and none is needed.** The Command Center has roles but
**cannot do read-only** (see §5). Instead a second read-only endpoint was built:

```
GET https://ops.jakisai.com/api/business-status
Authorization: Bearer <same token as /api/status>      # header only, no ?token= form
```

Live since 2026-10-01. Refreshes every 10 minutes, stale after 30. Same shape as
`/api/status` — `overall`, `summary`, `counts`, `checks[]` with priorities, `not_covered[]`,
`how_to_read` — so the agent's existing polling logic applies unchanged.

It reads the dashboard database with SQLite `mode=ro`: writes are refused by the database
engine, not by convention. There is no session to expire, no password, and no browser
automation involved.

**The agent should poll both endpoints:** `/api/status` for infrastructure,
`/api/business-status` for the business. Neither duplicates the other.

The sections below describe what the dashboard holds and which endpoint now surfaces it.

---

## 1. The seven sections

The app's permission vocabulary is the real section list. These are the ones Boss named,
mapped to what actually backs them:

| Section | Endpoint | What it holds |
|---|---|---|
| **Clients** | `GET /api/clients`, `/api/clients/{id}` | Subscriptions, fees, billing day, grace days, next due date, assigned staff, connected systems, per-client health |
| **Money** | `/api/invoices`, `/api/expenses`, `/api/wallets`, `/api/reports/profitability`, `/api/reports/bookkeeper` | Invoices (paid/unpaid), payments, expenses by category, wallet balances, per-client profit and margin |
| **Commissions** | `/api/commissions`, `/api/payout-requests`, `/api/affiliates` | Commission entries by recipient, affiliate tree, payout requests awaiting Owner review |
| **Documents** | `/api/documents` | Uploaded files per client, categorised |
| **Alerts** | `/api/alerts` | Auto-generated renewal / overdue / pause-review items |
| **Staff** | `/api/users` | Accounts, roles, permissions, last login |
| **AI insights** | `/api/ai/ask` | Free-text question endpoint over the dataset |

Also present and worth knowing: `/api/dashboard` (the landing summary — the single most
efficient read), `/api/vps/status` (the app's own host view), `/api/backups`,
`/api/products`, `/api/settings`, `/api/client-messages`, `/api/integrations`.

---

## 2. What "normal" looks like, and what is a problem

### Client health — the app computes this for you

Do **not** invent your own scoring. `clientHealth()` already returns a colour and the
reasons behind it. Its weights, verified in source:

**Red factors (+3 each):** subscription `past_due` · client `paused` · **2 or more**
unpaid invoices · **negative profit** on a client with revenue · any connected system in
`red` status.

**Yellow factors (+1 each):** exactly **one** unpaid invoice · any unresolved alert ·
any overdue task · any connected system in `yellow`.

**Report to Boss:** any client that newly gains a **red** factor. The `reasons[]` array is
already written in plain language — quote it rather than paraphrasing.

### Alerts — three types, with real severities

| Type | Severity | Trigger | Action |
|---|---|---|---|
| `renewal` | info / warning | Due within `renewal_alert_days` (**currently 3**); `warning` on the due date itself | Routine. Do not wake Boss |
| `overdue` | danger | Past due date, still inside grace | Same-day report |
| `client_pause` | critical | Past `due + grace_days`. Sets `past_due`, or auto-pauses if `auto_suspend` is on | Report immediately |

> **Calibration warning, measured today:** there are **28 unread alerts against 3 clients**.
> Unread alert *count* is therefore already saturated and is a **useless** signal — a rising
> count means nobody is clearing the list, not that something broke. Alert on **new
> `critical` or `danger` rows by `id`**, never on the total.

### Money

Normal: `unpaid_invoices` small and shrinking; every active client with positive profit.

Problem worth reporting: a client whose `profitability.profit` goes negative (the health
check already flags this, `+3`) · an invoice still `unpaid` after its grace period ·
`payout_requests` sitting in `pending`, since **only the Owner can approve them** — so a
pending payout is always blocked on Boss personally.

### Today's baseline (2026-10-01)

```
clients            3        documents        2
active_clients     1        payout_pending   0
unpaid_invoices    2        open_alerts     28  (saturated — see warning above)
```

Treat these as the starting line. With 3 clients, *any* change is significant; these
thresholds must be revisited once the client count grows.

### Staff

Normal: 3 accounts — `jakis` (owner), `aprilly` (manager), `kaitlyn` (manager).
**Report immediately:** any account you did not expect, any `role` change, or any account
with `must_change_password = 1` that stays unused. A new account appearing here is a
security event, not a routine change.

---

## 3. Which pages matter day to day

**Every cycle (cheap, high signal):**
1. `GET /api/status` — already polling. Keep it as the primary heartbeat.
2. `GET /api/dashboard` — one call, covers the landing figures for all sections.
3. `GET /api/alerts` — filter to `severity IN ('critical','danger')` **and unseen `id`**.

**Daily:** `/api/clients` (watch `health.color` transitions) · `/api/payout-requests`
(anything `pending` blocks Boss) · `/api/invoices?status=unpaid`.

**Weekly:** `/api/reports/profitability` · `/api/commissions` · `/api/backups`.

**Rarely — do not poll:** `/api/documents`, `/api/products`, `/api/settings`,
`/api/users` (check on change, not on a timer), `/api/ai/ask` (costs an AI call — use it
to *explain* a finding you already have, never to discover one).

---

## 4. What the dashboard shows that `/api/status` does not

`/api/status` is infrastructure-only. It ships its own `not_covered[]` list, which you
should read each poll. The **business** blind spots it leaves are exactly these:

- **Money.** No revenue, invoices, expenses, wallet balances or margins. Nothing about
  whether a client has paid.
- **Clients as customers.** `status` knows whether a *website* answers; it knows nothing
  about `past_due`, `paused`, grace periods or renewal dates.
- **Commissions and payouts.** Entirely absent, including payouts blocked on Boss.
- **Documents and staff.** Absent.
- **Client health.** The composite score and its `reasons[]` exist only in the app.

In short: `/api/status` answers *"is the machine up?"*. The Command Center answers
*"is the business healthy?"*. The second question is the reason the agent needs it.

---

## 5. Why no account yet

The app's permissions are **section-scoped, not verb-scoped**. The same check guards
reading and writing:

```js
// GET  /api/clients/{id}  → requirePermission(user,'clients')
// PATCH /api/clients/{id} → requirePermission(user,'clients')   // same permission
```

Verified: **11 permissions** (`clients`, `finance`, `documents`, `payouts`, `settings`,
`staff`, `commissions`, `affiliates`, `alerts`, `messages`, `products`) each gate write
methods under the identical name used for reads. None of the 7 roles — `owner`,
`manager`, `finance`, `sales`, `technical`, `support`, `affiliate` — is read-only.

**Consequence:** an account that can *see* money can also *change* money. Granting the
agent visibility into the sections Boss listed would hand a browser-automation agent
write access to client records, invoices, commissions and documents. That is the opposite
of the intent, so it is Boss's call to make, not a default to assume.
