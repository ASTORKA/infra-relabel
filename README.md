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

## Быстрый старт — одной командой

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
| `relabel ps` | показать процессы внутри контейнеров |
| `relabel all` | всё сразу (A→B→C→D) |

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

В каталоге [`accelerator/`](accelerator/) — вендоренный и **де-брендированный**
форк [jestivald/node-accelerator](https://github.com/jestivald/node-accelerator):
оптимизация ядра/сети (XanMod+BBRv3, sysctl, RPS/RFS), nftables-фаервол
(antiscan, anti-flood, CrowdSec) и read-only диагностика ноды.

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
