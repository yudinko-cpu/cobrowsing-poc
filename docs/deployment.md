# Deployment: VPS bootstrap + CI/CD

Разворачиваем cobrowsing-poc на VPS с автодеплоем из GitHub. Чек-лист от
голого сервера до "push в main → продовское обновление за 2 минуты".

**Скоуп:** PoC. Никаких HA, staging, secret manager'ов. Один VPS, одна ветка,
`.env` файлом на диске. Кому надо enterprise-grade — переписывать всё.

## Компоненты

- **GHA workflow** (`.github/workflows/deploy.yml`) — билд + пуш в GHCR + SSH-деплой
- **VPS** — Hetzner CX22 (Ubuntu 22.04, публичный IPv4)
- **GHCR** — приватные образы `ghcr.io/<owner>/cobrowsing-poc-{backend,web-agent}`
- **Compose стек** — `infra/docker-compose.yml` (LiveKit + backend + web-agent + Redis + Caddy)

## Часть 1. VPS bootstrap (делается один раз)

### 1.1 Создать VPS

Hetzner Cloud → Servers → New:

- Location: любой, ближе к клиентам
- Image: Ubuntu 22.04
- Type: CX22 (2 vCPU / 4GB / €4.5)
- SSH key: свой публичный ключ (~/.ssh/id_ed25519.pub)
- Cloud firewall: пропустить, настроим через ufw

Записать выданный IPv4 — это `PUBLIC_IP` для всего дальнейшего.

### 1.2 DNS

Три A-записи в вашем DNS-провайдере:

```
livekit.example.com          A    <PUBLIC_IP>
api.cobrowse.example.com     A    <PUBLIC_IP>
agent.cobrowse.example.com   A    <PUBLIC_IP>
```

Подождать пропагации (`dig +short livekit.example.com` должен вернуть ваш IP).
Let's Encrypt провалит ACME challenge, если DNS не доехал.

### 1.3 Первый SSH и обновления

```bash
ssh root@<PUBLIC_IP>
apt update && apt upgrade -y
apt install -y ufw git curl ca-certificates
```

### 1.4 Firewall

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 7881/tcp                # LiveKit TCP fallback
ufw allow 50000:60000/udp         # LiveKit media
ufw enable
ufw status verbose                # проверка
```

Redis (6379) и backend (4000) наружу НЕ открываем — они на 127.0.0.1 через
compose ports mapping.

### 1.5 Docker

```bash
# Официальный installer от Docker
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
docker compose version            # должно быть >=2.20
```

### 1.6 Deploy-пользователь (для GHA SSH)

Не даём GHA рутовый доступ. Отдельный юзер с sudo на нужные команды.

```bash
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh

# Сгенерируйте ЛОКАЛЬНО отдельный SSH-ключ для GHA (не переиспользуйте личный):
#   ssh-keygen -t ed25519 -f ~/.ssh/cobrowsing_deploy -C "gha-deploy"
# Публичную часть кладём на VPS:
echo "<содержимое ~/.ssh/cobrowsing_deploy.pub>" > /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
```

Проверить с локальной машины: `ssh -i ~/.ssh/cobrowsing_deploy deploy@<PUBLIC_IP>`.

### 1.7 Склонировать репо на VPS

```bash
sudo -u deploy -H bash -c '
  cd ~
  git clone https://github.com/<owner>/cobrowsing-poc.git /opt/cobrowsing 2>/dev/null || \
    git clone https://github.com/<owner>/cobrowsing-poc.git ~/cobrowsing-tmp
'
# Если /opt/cobrowsing уже занят или прав не хватило — clone упадёт, положить
# репо туда вручную и chown -R deploy:deploy /opt/cobrowsing.
```

Проще (одной командой из root):

```bash
mkdir -p /opt/cobrowsing
chown deploy:deploy /opt/cobrowsing
sudo -u deploy git clone https://github.com/<owner>/cobrowsing-poc.git /opt/cobrowsing
```

### 1.8 Заполнить infra/.env

```bash
sudo -u deploy -H bash
cd /opt/cobrowsing/infra
cp .env.example .env

# Сгенерировать LiveKit ключи
echo "LIVEKIT_API_KEY=API$(openssl rand -hex 8)"
echo "LIVEKIT_API_SECRET=$(openssl rand -base64 32)"

# Вписать в .env: PUBLIC_IP, домены, LiveKit ключи, GHCR_OWNER
$EDITOR .env
```

### 1.9 Синхронизировать livekit.yaml с ключами

Пока не автоматизировано (см. TODO в infra/livekit.yaml).

```bash
cd /opt/cobrowsing/infra
source .env
sed -i "s/APIxxxxxxxxxxxx:.*/${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}/" livekit.yaml
```

### 1.10 Логин в GHCR

Пакеты в GHCR по умолчанию приватные — надо разово залогинить docker
на VPS от имени deploy-пользователя.

Создайте GitHub Personal Access Token (Fine-grained) с scope `read:packages`:
https://github.com/settings/tokens?type=beta

```bash
sudo -u deploy -H bash
echo "<PAT>" | docker login ghcr.io -u <github-username> --password-stdin
# Креды сохраняются в ~/.docker/config.json — переживают перезагрузку.
```

### 1.11 Первый ручной деплой

Первый раз образы ещё не собраны в GHCR — нужно либо запушить workflow, либо
сбилдить локально.

**Вариант A (проще):** запушить любой коммит в main → GHA соберёт образы →
запустится SSH-деплой автоматически, и compose поднимется сам. Пропустить
пункт 1.11 и идти в раздел "Часть 2".

**Вариант B (без GHA):** собрать на VPS локально:

```bash
cd /opt/cobrowsing/infra
docker compose --env-file .env build backend
# web-agent требует NEXT_PUBLIC_API_URL как build-arg — проще запустить GHA
docker compose --env-file .env up -d livekit redis backend caddy
```

### 1.12 Проверка (все контейнеры Up)

```bash
cd /opt/cobrowsing/infra
docker compose ps                           # все должны быть running/healthy
curl -fsS http://127.0.0.1:4000/health      # backend внутри
curl -fsS https://api.cobrowse.example.com/health   # backend через Caddy + TLS
curl -I  https://livekit.example.com/       # 200 + X-LiveKit-Version
```

Если TLS-цикл ретраится — DNS ещё не пропагирован, `docker compose logs caddy`.

## Часть 2. Настройка GitHub (GHA секреты и переменные)

Settings → Secrets and variables → Actions.

### 2.1 Secrets

| Имя | Значение |
|---|---|
| `VPS_SSH_HOST` | `<PUBLIC_IP>` или `api.cobrowse.example.com` |
| `VPS_SSH_USER` | `deploy` |
| `VPS_SSH_KEY` | Приватный ключ (`~/.ssh/cobrowsing_deploy`, целиком включая BEGIN/END) |
| `VPS_SSH_PORT` | (опционально) кастомный SSH порт, дефолт 22 |

### 2.2 Variables

| Имя | Значение |
|---|---|
| `NEXT_PUBLIC_API_URL` | `https://api.cobrowse.example.com` |

`GITHUB_TOKEN` для push в GHCR предоставляется автоматически, отдельно не заводится.

### 2.3 Разрешения на packages

Первый раз GHA создаст пакеты в GHCR приватными. Settings → Packages → выбрать
пакет → Package settings → Manage Actions access → добавить сам репо с "Write".
Без этого второй пуш упадёт с 403.

## Часть 3. Первый автодеплой

```bash
git checkout main
git commit --allow-empty -m "trigger first deploy"
git push
```

Actions tab → workflow "deploy" → ~2 минуты на билд + пуш → SSH-шаг → smoke-check.

Успех = зелёный workflow + `curl https://api.cobrowse.example.com/health` возвращает `{"ok":true}`.

## Rollback

Каждый образ в GHCR тегируется полным git SHA. Откат — просто перезапуск с
предыдущим тегом:

```bash
ssh deploy@<PUBLIC_IP>
cd /opt/cobrowsing/infra

# Список последних тегов backend'а:
docker image ls | grep cobrowsing-poc

# Указать конкретный SHA:
sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=<good-sha>|" .env
docker compose --env-file .env pull
docker compose --env-file .env up -d
```

## E2E acceptance (P0-1)

- [ ] `docker compose ps` — 5 контейнеров `Up (healthy)` через ~60с
- [ ] `curl https://livekit.example.com/` → 200 + `X-LiveKit-Version`
- [ ] `curl https://api.cobrowse.example.com/health` → `{"ok":true}`
- [ ] `curl -I https://agent.cobrowse.example.com/` → 200
- [ ] `nmap <PUBLIC_IP>` извне: открыты только 22, 80, 443, 7881; порт 6379 и 4000 закрыты
- [ ] iOS с реального iPhone → продовский `api.cobrowse.example.com` → оператор
      на `agent.cobrowse.example.com` → видео идёт, mic toggle работает (secure context ✓)
- [ ] `git push` в main → через ~2 мин `/health` отдаёт свежий build

## Что дальше (не PoC)

- Автосинк livekit.yaml с .env через envsubst или init-container
- Prometheus scrape для LiveKit (`:6789/metrics`) + Grafana / Uptime Kuma
- fail2ban + автоматические security-updates (`unattended-upgrades`)
- Отдельный staging environment (второй VPS + `deploy-staging.yml` из ветки `staging`)
- Secrets из Vault / SOPS, а не `.env` на диске
- Обратно включить TURN (см. livekit.yaml) когда появятся клиенты за CGNAT
