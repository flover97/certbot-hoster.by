#!/usr/bin/env bash
# DNS-хук для certbot --manual: wildcard-сертификаты через REST API hoster.by.
#
#   hoster-dns-hook.sh auth     — --manual-auth-hook:   создать TXT _acme-challenge и дождаться DNS
#   hoster-dns-hook.sh cleanup  — --manual-cleanup-hook: удалить TXT _acme-challenge
#
# Конфиг: /etc/letsencrypt/hoster.env (пример — hoster.env.example).
# Зависимости: curl, python3, dig или nslookup.
set -euo pipefail

CONFIG="${HOSTER_DNS_CONFIG:-/etc/letsencrypt/hoster.env}"
# shellcheck disable=SC1090
if [ -f "$CONFIG" ]; then . "$CONFIG"; fi

API="https://serviceapi.hoster.by"
DOMAIN="${CERTBOT_DOMAIN:?CERTBOT_DOMAIN is empty}"
LABEL="_acme-challenge"
FQDN="$LABEL.$DOMAIN."
TTL=600           # минимум hoster.by (допустимый диапазон 600..604800)
POLL_TIMEOUT=300  # сколько секунд ждём появления записи в публичном DNS

log() { echo "hoster-dns[$DOMAIN]: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# --- Access-Token (создаётся на каждый запуск) -----------------------------
if [ -n "${ACCESS_TOKEN:-}" ]; then
  TOKEN="$ACCESS_TOKEN"
else
  [ -n "${ACCESS_KEY:-}" ] && [ -n "${SECRET_KEY:-}" ] \
    || die "не заданы ACCESS_KEY/SECRET_KEY (или ACCESS_TOKEN) — см. $CONFIG"
  RESP="$(curl -sS -X POST "$API/service/account/create/token" \
        -H "Access-Key: $ACCESS_KEY" -H "Secret-Key: $SECRET_KEY" 2>&1 || true)"
  TOKEN="$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("payload",{}).get("accessToken",""))' 2>/dev/null || true)"
  [ -n "$TOKEN" ] || { log "ответ API: ${RESP:-<пусто>}"; die "не получил Access-Token — проверь ключи в $CONFIG"; }
fi

# api METHOD PATH [BODY] — тело 200-ответа в stdout, при ошибке — лог и return 1.
# QUIET=1 подавляет лог ошибки (для попыток с fallback'ом).
api() {
  local m="$1" p="$2" b="${3:-}" out
  if [ -n "$b" ]; then
    out="$(curl -sS -w '\n%{http_code}' -X "$m" "$API$p" \
        -H "Access-Token: $TOKEN" -H 'Content-Type: application/json' -d "$b" 2>&1 || true)"
  else
    out="$(curl -sS -w '\n%{http_code}' -X "$m" "$API$p" -H "Access-Token: $TOKEN" 2>&1 || true)"
  fi
  local code="${out##*$'\n'}" body="${out%$'\n'*}"
  if [ "$code" = "200" ]; then
    printf '%s' "$body"
  else
    [ -z "${QUIET:-}" ] && { log "HTTP $code: $m $p"; log "ответ API: ${body:-<пусто>}"; }
    return 1
  fi
}

# --- orderId для домена ------------------------------------------------------
ORDERS_JSON="$(api GET /dns/orders)" || die "не смог получить список DNS-заказов"
ORDER_ID="${HOSTER_ORDER_ID:-$(printf '%s' "$ORDERS_JSON" | DOMAIN="$DOMAIN" python3 -c '
import json, os, sys
for o in json.load(sys.stdin).get("payload", {}).get("orders", []):
    if str(o.get("domainName", "")).lower() == os.environ["DOMAIN"].lower():
        print(o["id"]); break
')}"
[ -n "$ORDER_ID" ] || die "DNS-заказ для $DOMAIN не найден в GET /dns/orders"

# JSON текущей записи _acme-challenge (пусто, если записи нет)
acme_record_json() {
  api GET "/dns/orders/$ORDER_ID/records/txt" | LABEL="$LABEL" python3 -c '
import json, os, sys
for r in json.load(sys.stdin).get("payload", {}).get("records", []):
    n = str(r.get("name", "")).lower()
    if n == os.environ["LABEL"] or n.startswith(os.environ["LABEL"] + "."):
        print(json.dumps(r)); break
'
}

urlenc() { printf '%s' "$1" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=""))'; }

# POST добавления записи; $1 — name, $2 — content
try_add() {
  local BODY
  BODY="$(NAME="$1" VAL2="$2" TTL="$TTL" python3 -c '
import json, os
print(json.dumps({"name": os.environ["NAME"], "ttl": int(os.environ["TTL"]),
                  "records": [{"content": os.environ["VAL2"], "disabled": False}]}))')" || return 1
  api POST "/dns/orders/$ORDER_ID/records/txt" "$BODY" >/dev/null
}

# Действие над записью: имя пробуем в трёх написаниях (как в списке / FQDN / лейбл),
# формат имени у API не задокументирован.
api_txt() { # METHOD ENC_NAME [BODY]
  local base="/dns/orders/$ORDER_ID/records/txt"
  api "$1" "$base/$2" "${3:-}" >/dev/null \
    || api "$1" "$base/$FQDN" "${3:-}" >/dev/null \
    || api "$1" "$base/$LABEL" "${3:-}" >/dev/null
}

# true, если TXT $FQDN содержит значение $1 в ответах публичных резолверов.
# grep БЕЗ -q: с -q он закрывает пайп после совпадения, второй dig ловит SIGPIPE,
# и set -o pipefail превращает это в ложный провал проверки.
dns_has() {
  if command -v dig >/dev/null 2>&1; then
    { dig +short TXT "$FQDN" @1.1.1.1; dig +short TXT "$FQDN" @8.8.8.8; } 2>/dev/null \
      | grep -F -- "$1" >/dev/null
  else
    nslookup -type=TXT "$FQDN" 1.1.1.1 2>/dev/null | grep -F -- "$1" >/dev/null
  fi
}

case "${1:?usage: $0 auth|cleanup}" in
  auth)
    VAL="${CERTBOT_VALIDATION:?CERTBOT_VALIDATION is empty}"
    APPENDED=0
    CUR="$(acme_record_json)"

    if [ -n "$CUR" ]; then
      # apex + wildcard: второе значение под тем же именем — PATCH по списку contents
      NAME="$(CUR_JSON="$CUR" python3 -c 'import json,os; print(json.loads(os.environ["CUR_JSON"])["name"])')"
      BODY="$(CUR_JSON="$CUR" VAL="$VAL" TTL="$TTL" python3 -c '
import json, os
r = json.loads(os.environ["CUR_JSON"])
vals = [c.get("content") for c in r.get("records", []) if isinstance(c, dict) and c.get("content")]
quoted = bool(vals) and vals[0].startswith("\"")
newv = "\"" + os.environ["VAL"] + "\"" if quoted else os.environ["VAL"]
vals = [v for v in vals if v not in (os.environ["VAL"], newv)] + [newv]
print(json.dumps({"ttl": r.get("ttl") or int(os.environ["TTL"]),
                  "records": [{"content": v, "disabled": False} for v in vals]}))')"
      if api_txt PATCH "$(urlenc "$NAME")" "$BODY"; then
        log "значение дописано в запись $NAME"
        APPENDED=1
      else
        die "не удалось дописать значение в существующую запись"
      fi
    else
      # формат записи API не документирует — пробуем комбинации, пока не примет
      if try_add "$FQDN" "\"$VAL\""; then log "TXT создан (FQDN, в кавычках)"
      elif try_add "$FQDN" "$VAL"; then log "TXT создан (FQDN)"
      elif try_add "$LABEL" "\"$VAL\""; then log "TXT создан (лейбл, в кавычках)"
      elif try_add "$LABEL" "$VAL"; then log "TXT создан (лейбл)"
      else die "API отклонил все варианты формата записи — см. ответы выше"
      fi
    fi

    # ждём видимости записи (LE валидирует с разных точек)
    VISIBLE=0
    for (( t = 0; t < POLL_TIMEOUT; t += 5 )); do
      if dns_has "$VAL"; then VISIBLE=1; break; fi
      sleep 5
    done
    [ "$VISIBLE" = "1" ] || die "TXT не увиден в публичном DNS за ${POLL_TIMEOUT} с"
    log "TXT виден в публичном DNS"

    if [ "$APPENDED" = "1" ]; then
      # кэши резолверов, опросивших зону между созданием первого значения и
      # дописыванием второго, держат старый набор ещё TTL — даём протухнуть,
      # иначе часть валидаторов LE видит только старое значение
      log "пауза $((TTL + 20)) с: ждём протухания кэшей со старым набором значений"
      sleep $((TTL + 20))
    fi
    ;;

  cleanup)
    CUR="$(acme_record_json || true)"
    if [ -z "$CUR" ]; then
      log "запись _acme-challenge не найдена — удалять нечего"
      exit 0
    fi
    NAME="$(CUR_JSON="$CUR" python3 -c 'import json,os; print(json.loads(os.environ["CUR_JSON"])["name"])')"
    if QUIET=1 api_txt DELETE "$(urlenc "$NAME")"; then
      log "удалена TXT $NAME"
    else
      log "WARN: удалить не удалось — проверь вручную GET /dns/orders/$ORDER_ID/records/txt"
    fi
    ;;

  *)
    die "usage: $0 auth|cleanup"
    ;;
esac
