#!/usr/bin/env bash
# smoke-sync.sh — D1 senkron ekosistemi uçtan uca duman testi (prod'a karşı).
# Akış: register → QR alias create/poll/confirm → accounts list/switch →
#       provider connect/connected/usage/disconnect → scrape + oauth → admin REST.
# Not: Geçici kullanıcı silinmez (delete endpoint yok) — smoke-*@dots-smoke.test kalır.
#
# Admin REST (adım 8) token kaynakları (öncelik sırası):
#   1) SMOKE_ADMIN_TOKEN + SMOKE_SUPERADMIN_TOKEN
#   2) SMOKE_SUPERADMIN_EMAIL + SMOKE_SUPERADMIN_PASSWORD (+ superadmin smoke user'ı admin yapar)
#   3) SMOKE_D1_BOOTSTRAP=1 (varsayılan): wrangler ile smoke kullanıcı rolü admin/superadmin
# Opsiyonel: scripts/.smoke-credentials.local (gitignore'a ekleyin)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$SCRIPT_DIR/.smoke-credentials.local" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.smoke-credentials.local"
fi

BASE="${SMOKE_BASE_URL:-https://dotsherness-unified-backend.workers.dev}"
TS=$(date +%s)
EMAIL="smoke-${TS}@dots-smoke.test"
PASS="Smoke-${TS}-Pass1!"

jqpy() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"; }

fail() { echo "❌ $1" >&2; exit 1; }
ok() { echo "✅ $1"; }

smoke_login() {
  local email="$1" pass="$2"
  local resp
  resp=$(curl -sf -X POST "$BASE/api/auth/login" -H 'content-type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$pass\"}") || fail "login ($email)"
  local tok
  tok=$(echo "$resp" | jqpy "['access_token']")
  [ -n "$tok" ] || fail "login: access_token yok ($email)"
  echo "$tok"
}

d1_set_role() {
  local uid="$1" role="$2"
  (cd "$CF_DIR" && zsh -ic "wr-dotsherness d1 execute dotsherness-db --remote --config wrangler.jsonc \
    --command \"UPDATE users SET role='$role', updated_at=datetime('now') WHERE id='$uid'\"") \
    >/dev/null 2>&1 || fail "d1_set_role $role ($uid)"
}

d1_set_role_soft() {
  local uid="$1" role="$2"
  (cd "$CF_DIR" && zsh -ic "wr-dotsherness d1 execute dotsherness-db --remote --config wrangler.jsonc \
    --command \"UPDATE users SET role='$role', updated_at=datetime('now') WHERE id='$uid'\"") \
    >/dev/null 2>&1
}

resolve_admin_tokens() {
  local user_id="$1"
  local user_token="$2"
  ADMIN_TOKEN="${SMOKE_ADMIN_TOKEN:-}"
  SA_TOKEN="${SMOKE_SUPERADMIN_TOKEN:-}"

  if [[ -n "$ADMIN_TOKEN" && -n "$SA_TOKEN" ]]; then
    ok "admin tokens (env)"
    return
  fi

  if [[ -n "${SMOKE_SUPERADMIN_EMAIL:-}" && -n "${SMOKE_SUPERADMIN_PASSWORD:-}" ]]; then
    SA_TOKEN=$(smoke_login "$SMOKE_SUPERADMIN_EMAIL" "$SMOKE_SUPERADMIN_PASSWORD")
    if [[ -z "$ADMIN_TOKEN" ]]; then
      if d1_set_role_soft "$user_id" "admin"; then
        ADMIN_TOKEN=$(smoke_login "$EMAIL" "$PASS")
      else
        ADMIN_TOKEN="$user_token"
        ok "admin write test → smoke user (D1 admin rolü yok)"
      fi
    fi
    ok "admin tokens (superadmin login)"
    return
  fi

  if [[ "${SMOKE_D1_BOOTSTRAP:-1}" != "1" ]]; then
    fail "SMOKE_ADMIN_TOKEN+SMOKE_SUPERADMIN_TOKEN veya SMOKE_SUPERADMIN_EMAIL/PASSWORD veya SMOKE_D1_BOOTSTRAP=1 gerekli"
  fi

  ADMIN_TOKEN="${ADMIN_TOKEN:-$user_token}"
  if [[ -z "$SA_TOKEN" ]]; then
    d1_set_role "$user_id" "superadmin"
    SA_TOKEN=$(smoke_login "$EMAIL" "$PASS")
  fi
  ok "admin tokens (smoke user + d1 superadmin bootstrap)"
}

# 1) Register
REG=$(curl -sf -X POST "$BASE/api/auth/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"name\":\"Smoke\"}") || fail "register"
TOKEN=$(echo "$REG" | jqpy "['access_token']")
USER_ID=$(echo "$REG" | jqpy "['user']['id']")
[ -n "$TOKEN" ] || fail "register: access_token yok"
[ -n "$USER_ID" ] || fail "register: user.id yok"
ok "register ($EMAIL)"

AUTH=(-H "Authorization: Bearer $TOKEN")

# 2) QR alias (eski watch/mobil path'i — /api'siz)
QR=$(curl -sf -X POST "$BASE/auth/qr/create") || fail "qr create (alias)"
SID=$(echo "$QR" | jqpy "['sessionId']")
SECRET=$(echo "$QR" | jqpy "['pollSecret']")
[ -n "$SID" ] || fail "qr create: sessionId yok"
[ -n "$SECRET" ] || fail "qr create: pollSecret yok"
STATUS=$(curl -sf "$BASE/auth/qr/poll?sid=$SID" | jqpy "['status']")
[ "$STATUS" = "pending" ] || fail "qr poll (no secret): pending bekleniyordu, geldi: $STATUS"
STATUS_BAD=$(curl -sf "$BASE/auth/qr/poll?sid=$SID&secret=wrong-secret" | jqpy "['status']")
[ "$STATUS_BAD" = "pending" ] || fail "qr poll (wrong secret): pending bekleniyordu, geldi: $STATUS_BAD"
ok "qr alias create+poll secret guard"

# 3) QR confirm (Bearer) + poll → confirmed
curl -sf -X POST "$BASE/api/auth/qr/confirm" "${AUTH[@]}" -H 'content-type: application/json' \
  -d "{\"sessionId\":\"$SID\"}" >/dev/null || fail "qr confirm"
POLL=$(curl -sf "$BASE/auth/qr/poll?sid=$SID&secret=$SECRET")
[ "$(echo "$POLL" | jqpy "['status']")" = "confirmed" ] || fail "qr poll: confirmed değil"
[ -n "$(echo "$POLL" | jqpy "['access_token']")" ] || fail "qr poll: token yok"
ok "qr confirm → confirmed + token"

# 4) Accounts list + switch
ACC=$(curl -sf "$BASE/api/user/accounts?email=$EMAIL" "${AUTH[@]}") || fail "accounts list"
ACCOUNT_ID=$(echo "$ACC" | jqpy "['accounts'][0]['account_id']")
ACTIVE=$(echo "$ACC" | jqpy "['active_account_id']")
[ -n "$ACCOUNT_ID" ] && [ "$ACTIVE" != "None" ] || fail "accounts: boş"
SWITCH=$(curl -sf -X POST "$BASE/api/user/accounts/switch" "${AUTH[@]}" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"account_id\":\"$ACCOUNT_ID\"}") || fail "accounts switch"
[ "$(echo "$SWITCH" | jqpy "['user']['active_account_id']")" = "$ACCOUNT_ID" ] || fail "switch: active_account_id eşleşmedi"
ok "accounts list + switch ($ACCOUNT_ID)"

# 4b) Bearer'sız istek 401 dönmeli
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/user/accounts")
[ "$CODE" = "401" ] || fail "accounts auth'suz 401 dönmedi: $CODE"
ok "bearer zorunlu (401)"

# 5) Provider connect → connected → usage → disconnect
curl -sf -X POST "$BASE/api/provider/connect" "${AUTH[@]}" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"provider\":\"minimax\",\"api_key\":\"sk-smoke-test-key\"}" >/dev/null || fail "provider connect"
CONN=$(curl -sf "$BASE/api/provider/connected" "${AUTH[@]}")
echo "$CONN" | grep -q '"minimax"' || fail "connected listesinde minimax yok: $CONN"
ok "provider connect + connected"

USAGE=$(curl -sf "$BASE/api/user/usage?email=$EMAIL" "${AUTH[@]}") || fail "user usage"
echo "$USAGE" | grep -q '"minimax"' || fail "usage'da minimax placeholder yok"
ok "usage minimax içeriyor"

FETCH=$(curl -sf -X POST "$BASE/api/provider/fetch-usage" "${AUTH[@]}" -H 'content-type: application/json' -d "{}")
echo "$FETCH" | grep -q '"results"' || fail "fetch-usage results yok"
ok "fetch-usage cevap verdi"

curl -sf -X POST "$BASE/api/provider/disconnect" "${AUTH[@]}" -H 'content-type: application/json' \
  -d "{\"provider\":\"minimax\"}" >/dev/null || fail "provider disconnect"
CONN2=$(curl -sf "$BASE/api/provider/connected" "${AUTH[@]}")
echo "$CONN2" | grep -q '"minimax"' && fail "disconnect sonrası minimax hâlâ listede" || true
ok "provider disconnect"

# 6) Scrape browser session (create → status pending → confirm → logged_in)
SCR=$(curl -sf -X POST "$BASE/api/scrape/browser/create" "${AUTH[@]}" -H 'content-type: application/json' \
  -d '{"provider":"claude","target_url":"https://claude.ai/settings/usage"}') || fail "scrape create"
SCR_SID=$(echo "$SCR" | jqpy "['session_id']")
[ -n "$(echo "$SCR" | jqpy "['login_url']")" ] || fail "scrape: login_url yok"
[ "$(curl -sf "$BASE/api/scrape/browser/status?session_id=$SCR_SID" "${AUTH[@]}" | jqpy "['status']")" = "pending" ] || fail "scrape status pending değil"
curl -sf -X POST "$BASE/api/scrape/browser/confirm" "${AUTH[@]}" -H 'content-type: application/json' \
  -d "{\"session_id\":\"$SCR_SID\"}" >/dev/null || fail "scrape confirm"
[ "$(curl -sf "$BASE/api/scrape/browser/status?session_id=$SCR_SID" "${AUTH[@]}" | jqpy "['logged_in']")" = "True" ] \
  || [ "$(curl -sf "$BASE/api/scrape/browser/status?session_id=$SCR_SID" "${AUTH[@]}" | jqpy "['status']")" = "logged_in" ] \
  || fail "scrape logged_in olmadı"
ok "scrape session create→confirm→logged_in"

# 7) Provider OAuth session (start → status pending)
OAUTH=$(curl -sf -X POST "$BASE/api/provider/oauth/start" "${AUTH[@]}" -H 'content-type: application/json' \
  -d '{"provider":"claude"}') || fail "oauth start"
[ -n "$(echo "$OAUTH" | jqpy "['url']")" ] || fail "oauth: url yok"
[ "$(curl -sf "$BASE/api/provider/oauth/status?provider=claude" "${AUTH[@]}" | jqpy "['status']")" = "pending" ] || fail "oauth status pending değil"
ok "oauth start + status"

# 8) Admin REST matrix (admin read + admin PATCH read-only + superadmin PATCH)
echo ""
echo "--- Admin REST matrix ---"
resolve_admin_tokens "$USER_ID" "$TOKEN"
ADMIN_AUTH=(-H "Authorization: Bearer $ADMIN_TOKEN")
SA_AUTH=(-H "Authorization: Bearer $SA_TOKEN")

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/rest/providers?limit=1" "${ADMIN_AUTH[@]}")
[ "$CODE" = "200" ] || fail "non-superadmin GET providers: 200 bekleniyordu, geldi: $CODE"
ok "non-superadmin GET /api/rest/providers (200)"

PROV=$(curl -sf "$BASE/api/rest/providers?id=eq.minimax" "${ADMIN_AUTH[@]}")
SORT_ORDER=$(echo "$PROV" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['sort_order'] if isinstance(d,list) and d else '')")
[ -n "$SORT_ORDER" ] || fail "minimax sort_order alınamadı"

PATCH_BODY=$(printf '{"sort_order":%s}' "$SORT_ORDER")
PATCH_RESP=$(mktemp)
CODE=$(curl -s -o "$PATCH_RESP" -w "%{http_code}" -X PATCH "$BASE/api/rest/providers/minimax" \
  "${ADMIN_AUTH[@]}" -H 'content-type: application/json' -d "$PATCH_BODY")
[ "$CODE" = "400" ] || fail "non-superadmin PATCH providers: 400 bekleniyordu, geldi: $CODE"
grep -qi 'read-only' "$PATCH_RESP" || fail "non-superadmin PATCH: read-only mesajı yok"
ok "non-superadmin PATCH providers → 400 read-only"

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/rest/providers?limit=1" "${SA_AUTH[@]}")
[ "$CODE" = "200" ] || fail "superadmin GET providers: 200 bekleniyordu, geldi: $CODE"
ok "superadmin GET /api/rest/providers (200)"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH "$BASE/api/rest/providers/minimax" \
  "${SA_AUTH[@]}" -H 'content-type: application/json' -d "$PATCH_BODY")
[[ "$CODE" = "204" || "$CODE" = "200" ]] || fail "superadmin PATCH providers: 204/200 bekleniyordu, geldi: $CODE"
ok "superadmin PATCH providers → $CODE"
rm -f "$PATCH_RESP"

echo ""
echo "🎉 SMOKE PASSED — tüm senkron endpointleri + admin REST çalışıyor ($BASE)"
