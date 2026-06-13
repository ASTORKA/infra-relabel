# infra-relabel

Маскирует VPN-ноду **Remnawave** на сервере под обычный веб-стек, чтобы хостинг
по `docker ps` / `ps` / `ls /opt` / меткам compose не опознавал VPN-сервис.

Делает это **обратимо** и по возможности без простоя: правит `container_name`,
теги образов, имя compose-проекта, каталог деплоя, сеть, host-пути логов и имя
процесса ядра. Каждый шаг можно откатить.

```
remnanode            → app-backend     (контейнер, проект, /opt/app-backend)
remnawave-node-agent → app-worker      (контейнер, проект, /opt/app-worker)
caddy-selfsteal      → web-frontend    (контейнер; проект caddy не трогаем — нейтрален)
образ remnawave/node → app-backend:latest
процесс rw-core/xray → netd
```

## Установка

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel
cd /opt/infra-relabel
./install.sh          # ставит команду `relabel` в /usr/local/bin
```

После этого `relabel` доступна из любого каталога. Карта имён (`names.conf`) и
состояние (`.state/`) остаются в каталоге репозитория.

## Всё с нуля одной командой (clone + маскировка + ускорение + защита)

Скопировать репо, поставить команду и применить **всё** (переименования +
optimize + protect) одним вызовом. **От root.** Перед боевым запуском
подставь СВОИ значения портов и IP панели:

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel \
  && cd /opt/infra-relabel && ./install.sh \
  && SSH_PORT=22 TCP_PORTS=443 UDP_PORTS=443 WHITELIST="IP_ПАНЕЛИ" NONINTERACTIVE=1 \
     ./relabel.sh all-with-accelerator
```

Что делает по порядку: **selfsteal** (маскирующий сайт — если ещё не стоит) →
маскировка `all` (A→B→C→D) → `optimize` (XanMod+BBRv3, sysctl) →
`protect` (nftables-firewall) → `diagnose` → **sysmgr** (управляющий фреймворк).

> selfsteal ставится первым (его контейнер `caddy-selfsteal` тут же
> переименуется в `web-frontend` шагом маскировки) и **спросит домен**
> интерактивно — `NONINTERACTIVE=1` на него не влияет (это для protect/optimize).
> Если selfsteal уже установлен — шаг пропускается.

> ⚠️ **Критично — порты firewall.** `TCP_PORTS`/`UDP_PORTS` должны включать
> ВСЕ порты, на которых нода принимает трафик (Reality/VLESS, Hysteria2/TUIC),
> иначе `protect` их **заблокирует и нода уйдёт в офлайн**. Посмотри реальные:
> `ss -tulnp`. `WHITELIST` — IP панели/мониторинга (никогда не банятся).
> `SSH_PORT` — твой SSH, иначе рискуешь потерять доступ (есть сейфти-таймер
> `sys-fw-safety`, который откатит firewall через 5 мин без подтверждения).

**Сначала прогон вхолостую** (ничего не меняет, покажет все команды):

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel \
  && cd /opt/infra-relabel && ./relabel.sh all-with-accelerator --dry-run
```

**Безопасный вариант — без `NONINTERACTIVE`:** тогда `protect` сам спросит порты
интерактивно (труднее ошибиться):

```bash
cd /opt/infra-relabel && ./install.sh && relabel all-with-accelerator
```

> `optimize` ставит XanMod-ядро — после него нужен `reboot` (BBRv3 заработает).

## Быстрый старт — только маскировка

```bash
relabel all --dry-run     # 1) ПРЕДПРОСМОТР: показывает все команды, ничего не меняя
relabel all               # 2) применить всё (A→B→C→D) в правильном порядке
```

`all` выполняет по порядку: имена контейнеров → образы → проект/каталог/сеть →
маскировка ядра → host-пути логов. Команда **идемпотентна** — повторный запуск
пропускает уже сделанное.

После `all` обязательно проверь:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}'
docker top app-backend -eo pid,comm,args | grep -i netd   # ядро = netd, не rw-core/xray
```
И — главное — **нода ОНЛАЙН в панели Remnawave** (значит ядро поднялось).

> ⚠️ `all` пересоздаёт контейнеры (`down`/`up`) — короткий простой ноды.
> Запускай в спокойное время и сначала всегда `--dry-run`.

## Откат

```bash
relabel restore-all --dry-run   # предпросмотр отката
relabel restore-all             # вернуть всё как было (в обратном порядке)
```

## Команды по шагам

| Команда | Что делает |
|---------|------------|
| `relabel status` | текущее состояние маскировки |
| `relabel apply` | A1: имена контейнеров (из `names.conf`) |
| `relabel images` | A2: теги образов (ретег + пересоздание) |
| `relabel project` | B: имя проекта + каталог + сеть compose |
| `relabel hostpaths` | C: host-пути логов (`/var/log/remnanode` → `/var/log/app-backend`) |
| `relabel core` | D: имя процесса ядра (`rw-core`/`xray` → `netd`) |
| `relabel selfsteal` | установить selfsteal-сайт из форка ASTORKA (если не стоит) |
| `relabel sysmgr` | установить управляющий фреймворк sysmgr (TUI, root) |
| `relabel ps` | показать процессы внутри контейнеров |
| `relabel all` | вся маскировка сразу (A→B→C→D) |
| `relabel all-with-accelerator` | маскировка + `optimize` + `protect` + `diagnose` (root) |

Откат по шагам: `restore`, `images-restore`, `project-restore`,
`hostpaths-restore`, `core-restore`, `restore-all`.
**Все команды принимают `--dry-run`.**

## Карта имён

Редактируется в [`names.conf`](names.conf) — слева текущее имя, справа маска:

```
remnanode            = app-backend
remnawave-node-agent = app-worker
caddy-selfsteal      = web-frontend
```

## Как это работает (кратко)

- **A1 `apply`** — `docker rename` + правка `container_name:` в compose
  (с бэкапом), чтобы имя не вернулось при пересоздании.
- **A2 `images`** — `docker tag` в нейтральное имя + правка `image:` + пересоздание.
- **B `project`** — `down` → `mv` каталога → правка путей в compose → `up` с новым
  именем проекта. **Проекты с именованными томами пропускаются** (защита данных:
  напр. TLS-сертификаты Caddy).
- **C `hostpaths`** — host-путь bind-монтирования, чьё имя совпадает с VPN-именем
  из карты, переносится в нейтральный; путь **внутри** контейнера не меняется.
- **D `core`** — производный образ (`FROM` текущего + один слой): реальный бинарь
  `xray` → `netd`, симлинк `rw-core` → скрипт-обёртка `exec /usr/local/bin/netd`.
  В `ps`/`top` процесс становится `netd`.

Бэкапы compose-файлов и карты отката — в `.state/` (в git не попадают).

## Просмотр логов после маскировки

Контейнер ноды теперь называется **`app-backend`** (а не `remnanode`). Путь к
логу внутри контейнера не менялся, поэтому меняется только имя контейнера:

```bash
# было:
docker exec -it remnanode    tail -n +1 -f /var/log/supervisor/xray.out.log
# стало:
docker exec -it app-backend  tail -n +1 -f /var/log/supervisor/xray.out.log
```

Если имя лог-файла отличается — посмотреть, что есть:
```bash
docker exec -it app-backend ls /var/log/supervisor/
```

Прочие удобные команды (новые имена):
```bash
docker logs -f app-backend                 # лог супервайзера ноды
docker top  app-backend -eo pid,comm,args  # процессы (ядро = netd)
cd /opt/app-backend && docker compose ps    # управление нодой из нового каталога
cd /opt/app-worker  && docker compose ps    # агент
```

## Эксплуатация после маскировки

- Управляй сервисами из **новых** каталогов: `/opt/app-backend`, `/opt/app-worker`.
- **После обновления образа ноды** заново наложи слой ядра: `relabel core`
  (производный `:core` не переживает обновление).
- `relabel images` ломает `docker compose pull` (тег `app-backend:latest`
  локальный) — обновляй через исходный образ, затем `relabel images && relabel core`.

## Чего маскировка НЕ убирает (предел метода)

- В аргументах процесса `netd` остаётся путь сокета `remnawave-internal-*.sock` —
  его имя генерит код агента, без патча приложения (ломался бы при обновлениях)
  не меняется. Единственный остаточный «remnawave» в `ps aux`.
- Проект `caddy` и тома `caddy_caddy_*` — `caddy` нейтрален, тома с TLS не трогаем.
- Открытые порты и трафик — это уровень DPI, маскировкой имён не скрывается.

## Ускорение/защита ноды (`accelerator/`)

В каталоге [`accelerator/`](accelerator/) — **полностью вендоренный** и
**де-брендированный** форк стороннего MIT-инструмента (копирайт — в
[`accelerator/LICENSE`](accelerator/LICENSE)): оптимизация ядра/сети
(XanMod+BBRv3, sysctl, RPS/RFS), nftables-фаервол (antiscan, anti-flood,
CrowdSec) и read-only диагностика ноды. Внешних зависимостей при запуске нет —
код целиком лежит у нас, апстрим-репозиторий для работы не нужен.

Он работает на уровне хоста (не трогает имена контейнеров), но создавал свои
host-видимые артефакты с брендингом — они переименованы под нашу нейтральную
схему, чтобы не вскрывать VPN, который прячет `relabel`:

| Артефакт | Было | Стало |
|---|---|---|
| systemd-юниты | `na-firewall`, `na-fleet-sync`, … | `sys-firewall`, `sys-peers-sync`, `sys-blocklist`, `sys-ctguard`, `sys-rps` |
| Description юнита | «node-accelerator … Remnawave /api/nodes» | «system firewall», «peer allowlist sync» |
| nftables-таблица | `inet na_filter`, сеты `na_fleet_*` | `inet sysguard`, `sys_peers_*` |
| пути | `/etc/node-accelerator`, `/var/lib/…` | `/etc/sysguard`, `/var/lib/sysguard` |
| env / файл | `REMNAWAVE_URL/TOKEN`, `fleet.env` | `PANEL_URL/PANEL_TOKEN`, `peers.env` |
| sbin-утилиты | `na-fw-status`, … | `sys-fw-status`, `sys-fw-top-talkers` |

Запуск (на сервере ноды, от root):

```bash
cd /opt/infra-relabel/accelerator
sudo bash install.sh                 # интерактивное меню
sudo bash install.sh diagnose        # 🩺 read-only отчёт (безопасно начать с него)
sudo bash install.sh optimize        # ⚡ XanMod+BBRv3 + sysctl (нужен reboot)
sudo bash install.sh protect         # 🛡 nftables + CrowdSec
sudo bash install.sh rollback all    # полный откат
```

> ⚠️ `protect` ставит firewall с авто-сейфти-таймером (`sys-fw-safety`) от
> самоблокировки SSH; `optimize` ставит XanMod-ядро (нужна перезагрузка).
> Подробности и все ENV-параметры — в [accelerator/README.md](accelerator/README.md).

## Управляющий фреймворк (`sysmgr/`)

В каталоге [`sysmgr/`](sysmgr/) — **полностью вендоренный** и **де-брендированный**
TUI-фреймворк управления нодой/флотом (дашборд, управление флотом, шейпер
трафика per-user, security, gateway). Замороженная копия стороннего инструмента:
самообновление отключено, внешних зависимостей при запуске нет.

Host-видимые артефакты под нейтральной схемой: каталог `/opt/sysmgr`, команда
`sysmgr`, лог `/var/log/sysmgr.log`, systemd/cron `sysmgr-*`, SSH-ключи
`id_ed25519_sysmgr_*`.

```bash
relabel sysmgr        # установить (root): код → /opt/sysmgr, команда sysmgr
sudo sysmgr           # запустить TUI-управление
```

`install` неинтерактивный (копирует код и выходит); TUI открывается командой
`sysmgr`. Поэтому `sysmgr` встроен и в `all-with-accelerator` без пауз.

> Что осознанно НЕ убрано: имена модулей `modules/remnawave/` и
> `modules/bot_bedolaga/` внутри `/opt/sysmgr` (функциональные, видны только при
> глубоком `ls`) и TUI-баннер (виден лишь оператору, не хостингу). Подробности —
> в [sysmgr/README.md](sysmgr/README.md).
