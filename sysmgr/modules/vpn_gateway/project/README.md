# 🚀 VPN Gateway Project

Простой gateway для VPN-лендинга: поставил, заполнил пару полей в `gateway.yml`, запустил — готово.

---

## ✅ Проект готов к установке?

**Да.**
Сейчас проект уже в рабочем состоянии и рассчитан на быстрый запуск:

1. Один конфиг: `config/gateway.yml`
2. Один запуск: `./scripts/run-prod.sh`
3. Проверка: `curl` + тесты

---

## ⚡ Быстрый старт (5–10 минут)

### Вариант 0 (самый быстрый): единая интерактивная решала

```bash
cd /opt/vpn-gateway-project
./scripts/gatewayctl.sh
```

Откроется интерактивное меню со всеми базовыми операциями:
- install (автоустановка и проверки);
- run (запуск production-стека);
- test (тесты и проверки);
- certs (выпуск/обновление/cron);
- uninstall (безопасные режимы удаления).

Также можно запускать в командном режиме (под будущий модуль Sysmgr):

```bash
./scripts/gatewayctl.sh install
./scripts/gatewayctl.sh run
./scripts/gatewayctl.sh test
./scripts/gatewayctl.sh uninstall-dry
```

Для встраивания в основной скрипт решалы добавлены служебные команды:

```bash
./scripts/gatewayctl.sh manifest
./scripts/gatewayctl.sh list-actions
```

Для безопасного non-interactive режима:

```bash
./scripts/gatewayctl.sh uninstall --non-interactive --yes
./scripts/gatewayctl.sh uninstall-purge --non-interactive --yes-purge
```

Что делает install автоматически:
- проверяет зависимости (`python3`, `docker`, `docker-compose`);
- проверяет/создает `config/gateway.yml` из шаблона;
- валидирует обязательные поля в `quick_setup`;
- прогоняет тесты `pytest`;
- запускает прод-стек;
- проверяет контейнеры, health endpoint и редирект `/start`.

Если `config/gateway.yml` ещё не заполнен, скрипт сам подскажет что отредактировать и завершится без поломок.

### Удаление проекта (безопасно, через единый скрипт)

Предпросмотр удаления:

```bash
./scripts/gatewayctl.sh uninstall-dry
```

Реальное удаление контейнеров/сети (с интерактивным подтверждением):

```bash
./scripts/gatewayctl.sh uninstall
```

Реальное удаление + очистка локальных данных edge (`certs`, `logs`, `.env.edge`) (с отдельным подтверждением):

```bash
./scripts/gatewayctl.sh uninstall-purge
```


### 1) Перейти в проект

```bash
cd /opt/vpn-gateway-project
```

### 2) Скопировать шаблон и заполнить только нужный блок

```bash
cp config/gateway.example.yml config/gateway.yml
nano config/gateway.yml
```

Редактируйте блок:
- `quick_setup.public_domain`
- `quick_setup.origin_domain`
- `quick_setup.origin_scheme`
- `quick_setup.default_offer` ← **это ваш оффер, не обязательно `wl-lte`**
- `quick_setup.acme_email` (если включаете ACME)
- `quick_setup.acme_enabled`

В конфиге уже есть яркие секции:
- ✅ `БЛОК ДЛЯ РЕДАКТИРОВАНИЯ`
- ⛔ `НЕ РЕДАКТИРОВАТЬ БЕЗ ПОНИМАНИЯ`

### 3) Запустить

```bash
./scripts/run-prod.sh
```

### 4) Быстрая проверка

```bash
curl -kI https://127.0.0.1/
curl -kI 'https://127.0.0.1/start?target=your-offer'
```

---

## 💳 Платежки и `return`

В проекте включено скрытие `return` для платежных сценариев, чтобы не светить внутреннюю структуру ссылок.
Логика включается параметром:

```yaml
security:
  hide_payment_return: true
```

---

## 🧪 Проверка тестов

```bash
cd /opt/vpn-gateway-project
.venv/bin/python -m pytest -q
```

---

## 📘 Техническая документация

Подробная техничка вынесена в:

- `docs/TECHNICAL.md`

---

## Важно

- `wl-lte` в конфиге — это просто пример.
- Вы можете использовать любой свой `default_offer`.
- Проект автоматически подставляет его в ключевые места маршрутизации.
