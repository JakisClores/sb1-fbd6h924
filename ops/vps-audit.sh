#!/usr/bin/env bash
# VPS cleanup audit — READ ONLY. Reports findings, deletes nothing.
# Usage: bash vps-audit.sh 2>&1 | tee /tmp/vps-audit.txt
set -uo pipefail
h(){ printf '\n\n===== %s =====\n' "$1"; }

h "1. DISK: biggest directories"
du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -30

h "2. DISK: biggest individual files (>50M)"
find / -xdev -type f -size +50M -printf '%10s  %TY-%Tm-%Td  %p\n' 2>/dev/null \
  | sort -rn | head -30

h "3. STRAY SENSITIVE/BACKUP FILES IN WEBROOTS  << review closely"
# nginx already blocks these extensions, which implies they exist
find /var/www /opt /srv -type f \
  \( -name '*.bak' -o -name '*.bak-*' -o -name '*.old' -o -name '*.orig' \
     -o -name '*.save' -o -name '*.swp' -o -name '*~' \
     -o -name '*.sqlite' -o -name '*.db' -o -name '.env*' -o -name '*.sql' \) \
  -printf '%10s  %TY-%Tm-%Td  %p\n' 2>/dev/null | sort -k3 | head -60

h "4. LOGS: journal + nginx + app"
journalctl --disk-usage 2>/dev/null
du -sh /var/log 2>/dev/null
du -ah /var/log 2>/dev/null | sort -rh | head -20

h "5. SYSTEMD: failed / dead / enabled-but-not-running  << orphan services"
systemctl --failed --no-pager --no-legend 2>/dev/null
echo "--- enabled units with no running process ---"
for u in $(systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^jakis|^mcp'); do
  st=$(systemctl is-active "$u" 2>/dev/null)
  [ "$st" != "active" ] && printf '%-40s %s\n' "$u" "$st"
done

h "6. NGINX: vhosts, dangling symlinks, available-but-not-enabled"
ls -la /etc/nginx/sites-enabled/ 2>/dev/null
echo "--- dangling symlinks ---"
find /etc/nginx/sites-enabled/ -xtype l 2>/dev/null
echo "--- in available but NOT enabled (dormant configs) ---"
comm -23 <(ls /etc/nginx/sites-available/ 2>/dev/null | sort) \
         <(ls /etc/nginx/sites-enabled/ 2>/dev/null | sort)
nginx -t 2>&1 | tail -5

h "7. CERTS: expiry + orphans (cert with no matching vhost)"
for d in /etc/letsencrypt/live/*/; do
  n=$(basename "$d")
  e=$(openssl x509 -in "$d/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
  g=$(grep -rl "$n" /etc/nginx/sites-enabled/ 2>/dev/null | head -1)
  printf '%-45s %-28s %s\n' "$n" "$e" "${g:-<< NO VHOST REFERENCES THIS}"
done

h "8. CRON: all entries (87 reported — expect duplicates)"
for u in $(cut -f1 -d: /etc/passwd); do
  c=$(crontab -l -u "$u" 2>/dev/null | grep -vE '^\s*#|^\s*$')
  [ -n "$c" ] && { echo "--- user: $u ---"; echo "$c"; }
done
echo "--- system cron dirs ---"
ls -la /etc/cron.d/ 2>/dev/null
echo "--- cron scripts pointing at MISSING files ---"
crontab -l 2>/dev/null | grep -oE '/[^ ]+\.(sh|py|js)' | sort -u | while read -r f; do
  [ -f "$f" ] || echo "MISSING TARGET: $f"
done

h "9. CACHES: safe to clear, usually large"
du -sh /var/cache/apt /root/.cache /root/.npm ~/.cache 2>/dev/null
echo "--- node_modules (size + age) ---"
find / -xdev -type d -name node_modules -prune -printf '%TY-%Tm-%Td  %p\n' 2>/dev/null | head -20
echo "--- __pycache__ count ---"
find / -xdev -type d -name __pycache__ 2>/dev/null | wc -l

h "10. LISTENING PORTS (75 reported) -> owning unit"
ss -tlnp 2>/dev/null | awk 'NR>1{print}' | sed 's/users:/\n    users:/' 

h "11. STALE DIRS: untouched >90 days under /opt /srv /var/www /root"
find /opt /srv /var/www /root -maxdepth 2 -type d -mtime +90 \
  -printf '%TY-%Tm-%Td  %p\n' 2>/dev/null | sort | head -40

h "12. GIT REPOS: uncommitted work (do NOT delete these)"
find / -xdev -type d -name .git -maxdepth 5 2>/dev/null | while read -r g; do
  r=$(dirname "$g")
  s=$(git -C "$r" status --porcelain 2>/dev/null | wc -l)
  [ "$s" -gt 0 ] && echo "$s uncommitted  $r"
done

h "DONE — nothing was deleted."
