# TECHNICAL.md

## Назначение

Техническая документация по проекту `vpn-gateway-project`: архитектура, структура, конфиг, эксплуатация и диагностика.

---

## 1) Архитектура

Проект работает как gateway-слой между публичным трафиком и upstream-кабинетом.

Основные роли:

1. **Host nginx (внешний)**
   - принимает 80/443;
   - проксирует на edge-контейнер.

2. **Edge nginx (контейнер `vpn-edge-nginx`)**
   - TLS termination;
   - security headers, лимиты, фильтры;
   - проксирование в `vpn-gateway`.

3. **Application gateway (`vpn-gateway`, FastAPI)**
   - маршрутизация по `config/gateway.yml`;
   - mirror/health логика;
   - переписывание ответов для сокрытия origin.

4. **Upstream cabinet/origin**
   - реальный источник данных/платежных потоков.

---

## 2) Ключевая логика сокрытия origin

В режиме reverse proxy приложение:

- переписывает `Location`-заголовки (`origin_domain -> public_domain`);
- переписывает текстовые ответы (`text/*`, `json`, `js`, `xml`) для исключения утечек origin;
- сохраняет поведение маршрутов `/start`, `/buy/*`, `/api/*` по конфигу.

Это критично для payment/return-сценариев.

---

## 3) Структура проекта

```text
/opt/vpn-gateway-project
├── app/
│   ├── main.py
│   ├── config.py
│   ├── router_logic.py
│   ├── mirror_manager.py
│   ├── proxy.py
│   ├── url_utils.py
│   └── templates/landing.html
├── config/gateway.yml
├── tests/
├── edge/
│   ├── nginx/nginx.conf
│   ├── nginx/templates/default.conf.template
│   ├── certs/
│   ├── logs/
│   └── fail2ban/
├── scripts/
│   ├── run-prod.sh
│   ├── ensure-certs.sh
│   ├── renew-certs.sh
│   ├── install-renew-cron.sh
│   └── full-test.sh
├── docker-compose.yml
└── docker-compose.edge.yml
```

---

## 4) Конфигурация

Единая точка управления: `config/gateway.yml`.

Критичные блоки:

- `quick_setup.public_domain`
- `quick_setup.origin_domain`
- `quick_setup.origin_scheme`
- `project.mode` (`reverse_proxy`/`redirect`)
- `project.public_domain`
- `routing.routes`
- `upstreams.*`
- `landing.*`
- `security.*`
- `edge.http_port`, `edge.https_port`

---

## 5) Запуск и эксплуатация

Базовый прод-запуск:

```bash
cd /opt/vpn-gateway-project
./scripts/run-prod.sh
```

Проверка тестов:

```bash
cd /opt/vpn-gateway-project
.venv/bin/python -m pytest -q
```

Проверка контейнеров:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

---

## 6) Проверка на утечки origin

Рекомендуемый подход:

1. Прогнать тесты (`pytest -q`).
2. Проверить runtime-маршруты через edge.
3. Убедиться, что в `Location`, body, `return` нет `origin_domain`.
4. Проверить логи nginx/gateway на отсутствие origin-строки.

Пример поисковой проверки в access.log:

```bash
grep -n 'cabinet.example.com' /var/log/nginx/access.log
```

Ожидаемый результат: пусто.

---

## 7) Типовые симптомы и причины

### 502 Bad Gateway

Частая причина — mismatch по `Host` между внешним nginx и edge vhost.

Проверять:

- `server_name` во внешнем nginx;
- какой `Host` передаётся в proxy;
- доступность edge на целевом порту;
- актуальность перезагрузки `nginx -t && systemctl reload nginx`.

---

## 8) Логи

- Host nginx: `/var/log/nginx/access.log`, `/var/log/nginx/error.log`
- Edge container: `docker logs vpn-edge-nginx`
- App container: `docker logs vpn-gateway`

---

## 9) Безопасность

Точки усиления:

- edge default-host deny;
- ограничение методов;
- rate-limit для чувствительных роутов;
- скрытие технических заголовков upstream;
- fail2ban фильтры в `edge/fail2ban/`.

---

## 10) Примечание по compose

На этом сервере используется **legacy-команда**:

```bash
docker-compose
```

Команда `docker compose` не используется в рабочих процедурах данного проекта.
