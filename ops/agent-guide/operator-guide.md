# Command Center — Operator's Guide for the Muse Agent

**Account:** `jakisai-agent` · **Role:** `owner` · **Created:** 2026-10-01
**Base URL:** `https://ops.jakisai.com`
Every path and payload below was read from the running source, not assumed.

---

## 0. Credentials

The password is in **`/root/.secrets/jakisai-agent-password`** on the VPS, mode `0600`,
root-only. It was generated as 24 random bytes (192 bits, base64url) and written straight to
that file by the generator — it has never appeared in a chat, a shell argument, or a log.
Boss loads it into the vault from there.

```http
POST /api/auth/login
Content-Type: application/json

{"username": "jakisai-agent", "password": "<from the vault>"}
```

Returns `{token, user}`. Send `Authorization: Bearer <token>` on every later call.
Sessions last **14 days** (`SESSION_DAYS=14`); on a `401`, log in again.

`must_change_password` is `0`, so there is no forced password-change wall on first login.

> **Login is rate-limited to 10/min (burst 5), then `429`.** Never retry login in a tight
> loop — cache the session token and reuse it for the full 14 days.

---

## 1. Section map

The dashboard is a single-page app at `/`; all data moves over these endpoints.

| Section | Read | Write |
|---|---|---|
| **Clients** | `GET /api/clients` · `GET /api/clients/{id}` · `GET /api/clients-health` | `POST /api/clients` · `PATCH /api/clients/{id}` |
| **Money** | `GET /api/invoices` · `/api/expenses` · `/api/wallets` · `/api/reports/profitability` · `/api/reports/bookkeeper` · `/api/payouts/summary` | `POST /api/invoices` · `POST /api/invoices/{id}/pay` · `POST /api/expenses` |
| **Commissions** | `GET /api/commissions` · `/api/payout-requests` · `/api/affiliates` | `POST /api/payout-requests` · `PATCH /api/payout-requests/{id}` ⚠️ |
| **Documents** | `GET /api/documents` · `/api/documents/search` · `/api/documents/{id}/download` | `POST /api/documents/upload` |
| **Alerts** | `GET /api/alerts` | `POST /api/alerts/{id}` (mark read) |
| **Staff** | `GET /api/users` | `POST /api/users` ⛔ · `PATCH /api/users/{id}` ⛔ |
| **AI insights** | — | `POST /api/ai/ask` (costs an AI call) |

Also available: `GET /api/dashboard` (the landing summary — one call, cheapest overview),
`/api/tasks`, `/api/systems`, `/api/products`, `/api/kb`, `/api/audit`, `/api/version`.

---

## 2. The four procedures

### 2.1 Record a payment received

Payments attach to an invoice. **Paying the invoice is what creates the payment** — and it
also calculates commissions automatically. Do not try to write a payment any other way.

```http
POST /api/invoices/{invoice_id}/pay
{"amount": 2500, "paid_at": "2026-10-01T09:00:00.000Z",
 "reference": "GCash 0917xxxxxxx", "notes": "screenshot verified"}
```

Returns `{payment, commissions[]}` — the commission entries it generated. Every field is
optional; `amount` defaults to the invoice amount and `paid_at` to now.

**If no invoice exists yet,** create one first, then pay it:

```http
POST /api/invoices
{"client_id": "<id>", "type": "subscription", "amount": 2500,
 "issue_date": "2026-10-01", "due_date": "2026-10-01", "description": "October subscription"}
```

- **Safe to retry.** Paying an already-paid invoice returns the *existing* payment rather
  than creating a duplicate. A timeout is safe to repeat.
- Requires the `finance` permission (the agent has it).

### 2.2 Record a commission paid

Commissions are **never recorded by hand** — §2.1 generates them from the payment using the
client's commission plan. What "paying" means here is the payout flow:

1. The recipient requests a payout. ⚠️ `POST /api/payout-requests` always creates the
   request **for the logged-in user** (`owner_id = user.id`). The agent therefore *cannot*
   raise a request on someone else's behalf — doing so would create one for `jakisai-agent`
   itself. Leave step 1 to the staff member or affiliate.
2. Boss approves it:
   ```http
   PATCH /api/payout-requests/{id}
   {"status": "paid"}        // approved | paid | rejected | reversed
   ```

**The agent must not perform step 2.** See §3.

Minimum payout is the `minimum_payout` setting (default ₱500), and a request above the
wallet's available balance is rejected with `400`.

### 2.3 Record an allowance paid

Staff allowances **post themselves**. `ensureRecurringAllowances()` runs on its own and, once
per calendar month, writes one expense per active user with `allowance_monthly > 0`:

```
category     = "Staff Allowance"
description  = "Monthly staff allowance — <Full Name>"
amount       = users.allowance_monthly
expense_date = <first day of month>
created_by   = <that user's id>
```

So in the normal case **do nothing** — checking that the row exists is the whole job.

> ⚠️ **Double-posting hazard.** The auto-poster skips a month only if it finds an expense
> matching `created_by` + `category='Staff Allowance'` + that **exact description** + month.
> A manual entry worded differently will not be recognised, and the allowance posts **twice**.
> If you must add one by hand, reproduce the description character for character, em-dash
> included.

To change someone's monthly figure, don't post an expense — update the user (but see §3,
staff edits are off-limits; raise it with Boss).

### 2.4 Pause or resume a past-due client

```http
POST /api/clients/{id}/pause     {"reason": "beyond grace period, 23 days past due"}
POST /api/clients/{id}/resume    {"reason": "payment received 2026-10-01"}
```

Sets status to `paused` / `active` **and dispatches a live command to the client's connected
system** via `dispatchPauseCommand`. This is not a bookkeeping flag — **pausing takes the
client's service down, and they will notice.**

**The agent must not pause or resume.** Report the recommendation to Boss and let him run it.
See §3.

For context when reporting: `refreshAlerts()` already moves a client to `past_due`
automatically once past the due date, and raises a `client_pause` **critical** alert once
past `due_date + grace_days`. It auto-pauses only if the client's `auto_suspend` is set or
the `auto_pause_after_grace` setting is on — currently neither, which is why both overdue
clients are sitting in `past_due` awaiting a human decision.

---

## 3. Never touch

The account is `owner`, so the app will **not** stop the agent doing any of this. These are
boundaries of judgement, not of permission.

| Action | Endpoint | Why |
|---|---|---|
| Approve / pay / reverse a payout | `PATCH /api/payout-requests/{id}` | Money leaving the business. Boss only — and the agent could approve a request it raised for itself |
| Create or modify any user | `POST /api/users`, `PATCH /api/users/{id}` | Privilege escalation. As `owner` the agent can mint accounts and change roles, including its own |
| Change its own password | `POST /api/me/password` | Instantly invalidates the vault copy and locks the agent out |
| Change global settings | `PATCH /api/settings` | Controls `auto_pause_after_grace`, `renewal_alert_days`, `minimum_payout`, `large_expense_alert` — one edit silently changes system-wide behaviour |
| Pause / resume a client | `POST /api/clients/{id}/(pause\|resume)` | Customer-visible outage |
| Close or reopen an accounting month | `POST /api/finance/close`, `/reopen` | Freezes or unfreezes all financial writes |
| Delete a document | document delete (`docs_delete`) | Irreversible |
| Message a real client | `/api/sylora/reply`, `/api/sylora/autoreply`, client-message replies | Sends to an actual person |
| Inject integration events | `POST /api/integrations/event` | Can fabricate payments and alerts |
| Trigger a backup or restore | `POST /api/backups`, `/api/restore/log-attempt` | Heavy, and restore is destructive |

**Rule of thumb:** the agent may record what has already happened (a payment that arrived, an
expense that was incurred) and read anything. Anything that *causes* something to happen in
the world — money moving, a service going dark, a message reaching a person, an account being
created — goes to Boss as a recommendation.

---

## 4. Operational gotchas

- **Closed months block financial writes.** `assertMonthOpen()` guards payments, invoices and
  expenses. If the month is closed you get **`423`** with
  `"Accounting month YYYY-MM is closed. Owner must reopen it first."` That is not a bug and
  not retryable — tell Boss.
- **Everything is audited.** `activity_log` records user id, action, entity, IP, and
  before/after values. Actions appear as `jakisai-agent`, distinct from Boss's own — which is
  the point of a separate account. Assume every write is attributable.
- **Large expenses self-flag.** An expense at or above `large_expense_alert` (default
  ₱10,000) raises an alert automatically. Expect it; don't treat it as an error.
- **Payments are idempotent per invoice**, so retrying a timed-out payment is safe. Nothing
  else is guaranteed idempotent — especially `POST /api/expenses`, which will happily
  duplicate.
- **Use `/api/business-status?token=…` for monitoring, not this login.** Polling with the
  session is wasteful and burns the login rate limit. The login is for actions.

---

## 5. Two things Boss should know about this account

Raised once, for the record — Boss has decided, and these are the consequences to own.

1. **`owner` grants more than section access.** Full access to all 21 sections was available
   from a non-owner role with explicit permissions. `owner` was chosen deliberately, and adds
   exactly two abilities nothing else can: **approving payout requests** (`PATCH
   /api/payout-requests/{id}` is hardcoded `role !== 'owner'` → `403`) and the blanket
   permission bypass. Both are listed in §3 as off-limits by convention — but convention is
   now the only thing enforcing them.
2. **Write access makes displayed text an input.** The agent reads client names, notes,
   message bodies and document titles, some of which originate outside the business (a
   submitted form, an inbound DM). With write access, text from those fields sits in front of
   an agent that can act on it. Keep §3 in the agent's standing instructions, not just in
   this file, and prefer `/api/business-status` for routine monitoring so the agent spends
   most of its time nowhere near a writable session.
