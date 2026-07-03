# Self-hosted LiveKit deployment

Инструкция для разворачивания на одном VPS (Hetzner, DigitalOcean, AWS EC2 t3.medium).

## Требования

- Linux-сервер с публичным IPv4 (Ubuntu 22.04+)
- Docker + Docker Compose plugin
- 3 поддомена с DNS A-записями на IP сервера:
  - `livekit.example.com` — WebSocket signaling
  - `api.cobrowse.example.com` — token server
  - `agent.cobrowse.example.com` — web dashboard для агентов
- Открытые порты: см. `docs/architecture.md` секцию "Сетевые требования"

## Шаги развёртывания

### 1. Подготовить ключи

```bash
# API key (16 байт hex)
echo "LIVEKIT_API_KEY=API$(openssl rand -hex 8)"

# API secret (32+ байт base64)
echo "LIVEKIT_API_SECRET=$(openssl rand -base64 32)"
```

### 2. Настроить firewall

```bash
# ufw пример
sudo ufw allow 22/tcp                    # SSH
sudo ufw allow 80,443/tcp                # Caddy (HTTPS + ACME challenge)
sudo ufw allow 7881/tcp                  # LiveKit TCP fallback (для сетей без UDP)
sudo ufw allow 50000:60000/udp           # WebRTC media
sudo ufw enable
```

TURN отключён на POC. Порты 3478/UDP и 5349/TCP не нужны. См. секцию
"Когда включать TURN" ниже и комментарий в `livekit.yaml`.

### 3. Заполнить .env

```bash
cp .env.example .env
$EDITOR .env  # вписать PUBLIC_IP, DOMAIN, API_DOMAIN, AGENT_DOMAIN, LIVEKIT_API_KEY, LIVEKIT_API_SECRET
```

### 4. Прописать ключ в livekit.yaml

```bash
# Заменить APIxxxxxxxxxxxx и secret в секции keys: на значения из .env
sed -i "s/APIxxxxxxxxxxxx:.*/$LIVEKIT_API_KEY: $LIVEKIT_API_SECRET/" livekit.yaml
```

(Альтернативно — использовать envsubst или config templating через init-container.)

### 5. Запустить

```bash
docker compose up -d
docker compose logs -f livekit  # убедиться, что сервер стартовал без ошибок
```

### 6. Проверка

```bash
# WebSocket endpoint должен отвечать 200 OK на handshake
curl -i https://$DOMAIN/

# Token API health
curl https://$API_DOMAIN/health

# LiveKit CLI диагностика (опционально)
docker run --rm livekit/livekit-cli load-test \
  --url wss://$DOMAIN \
  --api-key $LIVEKIT_API_KEY \
  --api-secret $LIVEKIT_API_SECRET \
  --duration 30s
```

## Что мониторить в проде

- LiveKit Prometheus metrics: `:6789/metrics` (включить в `livekit.yaml`)
- Caddy access logs: `docker compose exec caddy cat /data/livekit-access.log`
- Redis memory usage: `redis-cli INFO memory`
- Port allocation: `ss -tunap | grep -c ESTAB`

## Troubleshooting

**Видео не идёт, signaling работает:** проверить UDP firewall (50000-60000). 90% случаев.

**WebRTC падает на TCP fallback (тормоза):** проверить `use_external_ip: true` и что `--node-ip` передан правильно.

**TLS-ошибки:** Caddy логи в `docker compose logs caddy`. Чаще всего — DNS ещё не пропагировался или порт 80 заблокирован (ACME challenge не проходит).

**OOM redis:** уменьшить retention для session-кодов до 5 минут в `backend/server.js`.

## Когда включать TURN

Для POC TURN не включён. Клиенты подключаются к LiveKit напрямую по UDP
(порты 50000-60000) или, если UDP заблокирован, — по TCP fallback (порт 7881).

Включать TURN обратно, если:

- Клиент застревает в state `.connecting`, не переходит в `.streaming`
- В логах LiveKit видно `no compatible ICE candidates` или `ICE gathering timeout`
- Работает на одной сети (Wi-Fi), не работает на другой (LTE у конкретного оператора)
- Пилот в enterprise-заказчике, где разрешён только TCP/443

**Как включить:**

1. В `livekit.yaml` раскомментировать секцию `turn:` (там есть готовый шаблон)
2. Обновить firewall:
   ```bash
   sudo ufw allow 3478/udp    # TURN STUN
   sudo ufw allow 5349/tcp    # TURN TLS
   ```
3. Смонтировать Let's Encrypt cert от Caddy в volume LiveKit
   (добавить `- caddy-data:/certs:ro` в `docker-compose.yml` для сервиса livekit,
   указать путь к fullchain.pem/privkey.pem в `livekit.yaml`)
4. Перезапустить: `docker compose up -d livekit`
