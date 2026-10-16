# certbot-hoster.by

DNS-хук для certbot: wildcard-сертификаты Let's Encrypt для доменов, чей DNS
обслуживает **hoster.by**, без ручных TXT-записей. Хук сам создаёт и удаляет
`_acme-challenge` через REST API hoster.by и ждёт распространения записи —
`certbot renew` работает полностью без человека.

```bash
certbot certonly --manual --preferred-challenges dns \
  -d example.by -d '*.example.by' \
  --manual-auth-hook "/etc/letsencrypt/hooks/hoster-dns-hook.sh auth" \
  --manual-cleanup-hook "/etc/letsencrypt/hooks/hoster-dns-hook.sh cleanup" \
  --manual-public-ip-logging-ok \
  -m you@example.by --agree-tos --non-interactive
```

## Как работает

```
certbot certonly --manual …
 │
 ├─ auth-хук (вызывается на каждое имя: example.by и *.example.by)
 │    1. Access-Key/Secret-Key → Access-Token (токен новый на каждый запуск)
 │    2. orderId → GET /dns/orders по CERTBOT_DOMAIN (или HOSTER_ORDER_ID)
 │    3. TXT _acme-challenge:
 │         записи нет  → POST (создать)
 │         запись есть → PATCH (дописать второе значение, кейс apex+wildcard)
 │    4. ждать, пока TXT виден на 1.1.1.1 / 8.8.8.8 (до 300 с)
 │    5. если значение ДОПИСЫВАЛИ → пауза TTL+20 c (~10,5 минут)*
 │
 ├─ certbot отправляет челлендж на валидацию в Let's Encrypt
 │
 └─ cleanup-хук: DELETE _acme-challenge
```

\* Зачем пауза: резолверы, опросившие зону между созданием первого значения и
дописыванием второго, держат в кэше старый набор ещё TTL (600 с). Если отдать
управление certbot сразу, часть валидаторов Let's Encrypt увидит только старое
значение и авторизация упадёт с `Incorrect TXT record`. Пауза даёт таким кэшам
протухнуть — в логе это выглядит как долгое ожидание на шаге 5, это нормально,
не зависание. Для обычного домена без связки apex+wildcard паузы нет.

## Требования

- certbot (проверено на старых 0.x/1.x — пойдёт почти на любом Debian/Ubuntu);
- `curl`, `python3`, `dig` или `nslookup`;
- ключи сервисного API-аккаунта hoster.by (личный кабинет → раздел API →
  создать ключи с доступом к услуге DNS).

## Установка

```bash
# 1) хук
mkdir -p /etc/letsencrypt/hooks
cp hoster-dns-hook.sh /etc/letsencrypt/hooks/
chown root:root /etc/letsencrypt/hooks/hoster-dns-hook.sh
chmod 700 /etc/letsencrypt/hooks/hoster-dns-hook.sh

# 2) конфиг (пароли внутри — читаем только под root)
cp hoster.env.example /etc/letsencrypt/hoster.env
chown root:root /etc/letsencrypt/hoster.env
chmod 600 /etc/letsencrypt/hoster.env
nano /etc/letsencrypt/hoster.env             # вписать ACCESS_KEY / SECRET_KEY

# 3) выпуск сертификата — команда выше (для уже существующего серта
#    добавить --force-renewal, чтобы перезаписать его конфиг хуками)

# 4) проверка автопродления (гоняет хуки через staging-сервер LE)
certbot renew --dry-run

# 5) крон (если у certbot нет своего systemd-таймера)
echo '17 4 * * * root certbot renew --quiet' > /etc/cron.d/certbot-renew
```

Хуки сохраняются в `/etc/letsencrypt/renewal/<домен>.conf`, поэтому все
последующие продления идут сами.

## Конфиг `/etc/letsencrypt/hoster.env`

| Переменная | Обязательна | Описание |
|---|---|---|
| `ACCESS_KEY`, `SECRET_KEY` | да* | ключи сервисного аккаунта hoster.by; токен создаётся на каждый запуск |
| `ACCESS_TOKEN` | нет | готовый токен вместо ключей (если у вас long-lived) |
| `HOSTER_ORDER_ID` | нет | зафиксировать orderId DNS-услуги; иначе хук сам находит его в `GET /dns/orders` по `CERTBOT_DOMAIN` |

## Проверка хука руками (без certbot)

```bash
CERTBOT_DOMAIN=example.by CERTBOT_VALIDATION=test-hook-123 \
  /etc/letsencrypt/hooks/hoster-dns-hook.sh auth
dig +short TXT _acme-challenge.example.by @1.1.1.1   # увидим "test-hook-123"
CERTBOT_DOMAIN=example.by /etc/letsencrypt/hooks/hoster-dns-hook.sh cleanup
```

## Отладка

Хук печатает в stderr пошаговый лог; при любом не-200 ответе — HTTP-код и тело
ответа API (там hoster пишет конкретную причину валидации). Для полной трассировки:

```bash
bash -x /etc/letsencrypt/hooks/hoster-dns-hook.sh auth
```

## Лицензия

GPL-3.0
