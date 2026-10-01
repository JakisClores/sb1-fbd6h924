# `/api/business-status` — read-only business monitoring endpoint

Built 2026-10-01 so Boss's Muse agent can see business state without a dashboard login.
The Command Center cannot grant read-only access (its permissions are section-scoped, not
verb-scoped — same check guards GET and PATCH), so no account was created.

## What is deployed

| Path on the VPS | Role |
|---|---|
| `/usr/local/sbin/jakisai-business-collect` | The collector (this repo's copy is the source of truth) |
| `/etc/systemd/system/jakisai-business.{service,timer}` | Every 10 min, hardened oneshot |
| `/var/lib/jakisai-status/business.json` | Output, ~9 KB, written atomically |
| `/etc/nginx/conf.d/jakisai-status.conf` | `$jakisai_business_auth` map + `jakisai_business` rate zone |
| `/etc/nginx/sites-enabled/ops.jakisai.com` | `location = /api/business-status` |
| `/root/nginx-backup-20261001-business/` | Pre-change nginx backups |

## Safety properties

- **Cannot write.** The database is opened `file:...?mode=ro`; SQLite refuses writes
  (`attempt to write a readonly database`). Not a convention — an engine-level guarantee.
- **Cannot write elsewhere.** `ProtectSystem=strict` with `ReadWritePaths` limited to
  `/var/lib/jakisai-status`.
- **No secrets in the output.** No password hashes; `must_change_password` is a 0/1 flag.
  Client emails, phones and document contents are excluded by design.
- **Header-only auth**, so the token never reaches an access log.
- **Per-check isolation.** Each check is wrapped: a schema change degrades that one check
  to `unknown` instead of emptying the file.

## Updating the collector

Edit the copy here, then deploy and verify:

```bash
# copy to /usr/local/sbin/jakisai-business-collect, then:
python3 -m py_compile /usr/local/sbin/jakisai-business-collect
systemctl start jakisai-business.service
systemctl show jakisai-business.service -p Result --value    # expect: success
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(cat /root/.secrets/jakisai-status-token)" \
  https://ops.jakisai.com/api/business-status                # expect: 200
```

## Gotcha worth remembering

The nginx map entry must be a **regex** (`"~^Bearer <token>$"`), not a literal. A literal
64-character key overflows the default `map_hash_bucket_size: 64` and `nginx -t` fails with
`could not build map_hash`.
