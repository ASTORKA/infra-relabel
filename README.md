# infra-relabel

> ## Что в репозитории и что ставит (тезисно)
>
> Один репозиторий + команда `relabel` для подготовки VPN-ноды Remnawave.
> **Всё вендорено внутрь** (внешних tool-зависимостей нет — чужие репо могут
> закрыть, у нас останется рабочая копия), всё ставится одной командой
> `relabel all-with-accelerator`:
>
> - **Маскировка ноды** (`relabel all`) — переименование контейнеров, образов,
>   compose-проектов/каталогов/сетей, host-путей логов и процесса ядра
>   (`rw-core`/`xray` → `netd`) под нейтральные имена. Обратимо.
> - **selfsteal** — маскирующий сайт-заглушка (Caddy). Из форка ASTORKA.
> - **`accelerator/`** — оптимизация ядра/сети (XanMod+BBRv3, sysctl, RPS) +
>   nftables-firewall (antiscan/anti-flood/CrowdSec) + диагностика.
>   Де-брендирован под `sys-*` / `sysguard`.
> - **`mobile443/`** — фильтр VPN-портов в **block-only** режиме (без Telegram):
>   дропает IP из blocklist'ов (гос-сети, антисканеры). Легитимных юзеров не режет.
> - **`sysmgr/`** — TUI-фреймворк управления нодой/флотом (дашборд, шейпер
>   трафика, security, gateway). Вендорен, де-брендирован, самообновление выкл.
>
> Подробности по каждому — ниже.

---

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

> ⚠️ Если сам `git clone` виснет на «Cloning into…» — это DPI-блокировка
> github.com на сервере. Тяни репо архивом через прокси (git-протокол не
> участвует):
>
> ```bash
> rm -rf /opt/infra-relabel && mkdir -p /opt/infra-relabel
> curl -fL --ipv4 https://gh-proxy.com/https://codeload.github.com/ASTORKA/infra-relabel/tar.gz/refs/heads/main \
>   | tar -xz --strip-components=1 -C /opt/infra-relabel
> ```

### Обход DPI-блокировок GitHub (`GH_PROXY`)

На заблокированных сетях (типичный VPS в РФ) скрипты, которые в рантайме тянут
код/данные с GitHub (selfsteal, шаблоны сайтов, blocklist'ы, geoip, RealiTLScanner
и т.д.), упрутся в DPI. Поэтому **все обращения к GitHub идут через прокси-префикс**
`GH_PROXY` (по умолчанию `https://gh-proxy.com/`). Это касается и `raw`, и `api`,
и `git clone`, и релизов; для внешнего `selfsteal.sh` его внутренние github-ссылки
переписываются на прокси на лету перед запуском.

```bash
# по умолчанию — через gh-proxy.com, ничего делать не надо
relabel all-with-accelerator --no-block

# сменить зеркало (если gh-proxy.com недоступен):
GH_PROXY="https://ghfast.top/" relabel all-with-accelerator --no-block

# отключить прокси (сеть без блокировок — ходить на github напрямую):
GH_PROXY= relabel all-with-accelerator --no-block
```

`GH_PROXY` экспортируется в дочерние скрипты (`accelerator`, `mobile443`) и
вшивается в генерируемые юниты (например, ежедневный рефреш blocklist'ов
`mobile443`), так что прокси работает и после установки. Формат префикса —
`<proxy>/` + полный исходный URL (с `https://`).

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
`protect` (nftables-firewall) → **mobile443** (block-only фильтр портов) →
`diagnose` → **sysmgr** (управляющий фреймворк).

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

## Всё с нуля одной командой, но БЕЗ переименований (`--no-mask`)

Если маскировка не нужна (или ломает текущую конфигурацию) — флаг `--no-mask`
ставит **всё то же самое, но НИЧЕГО не переименовывает**: selfsteal → `optimize`
→ `protect` → `mobile443` → `diagnose` → `sysmgr`, **без** шага маскировки
(контейнеры/образы/проекты/ядро остаются с исходными именами `remnanode`/`xray`).

Скопировать репо, поставить команду и применить всё одним вызовом. **От root.**
Подставь СВОИ порты и IP панели:

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel \
  && cd /opt/infra-relabel && ./install.sh \
  && SSH_PORT=22 TCP_PORTS="443 8443" UDP_PORTS="443 8443" WHITELIST="IP_ПАНЕЛИ" \
     NONINTERACTIVE=1 ./relabel.sh all-with-accelerator --no-mask
```

**Сначала прогон вхолостую** (ничего не меняет, покажет все команды):

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel \
  && cd /opt/infra-relabel && ./relabel.sh all-with-accelerator --dry-run --no-mask
```

**Безопасный вариант — без `NONINTERACTIVE`** (`protect` сам спросит порты):

```bash
cd /opt/infra-relabel && ./install.sh && relabel all-with-accelerator --no-mask
```

> ⚠️ Те же предупреждения по портам, что и выше: `TCP_PORTS`/`UDP_PORTS` должны
> включать ВСЕ порты ноды (`ss -tulnp`), `WHITELIST` — IP панели, `SSH_PORT` —
> твой SSH. selfsteal спросит домен интерактивно. `optimize` ставит XanMod —
> нужен `reboot`.

## Только ускорение/защита — БЕЗ переименований и БЕЗ заглушки (`--no-mask --no-selfsteal`)

Если заглушка selfsteal у тебя **уже стоит** (или не нужна) и переименования тоже
не нужны — комбинируй флаги. Ставится только: `optimize` → `protect` →
`mobile443` → `diagnose` → `sysmgr`. **Ничего не переименовывается и заглушка не
трогается.**

Одной командой с нуля (**от root**, подставь свои порты и IP):

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel \
  && cd /opt/infra-relabel && ./install.sh \
  && SSH_PORT=22 TCP_PORTS="443" UDP_PORTS="443" WHITELIST="IP_ПАНЕЛИ,IP_КАСКАД-НОДЫ" \
     NONINTERACTIVE=1 ./relabel.sh all-with-accelerator --no-mask --no-selfsteal
```

Предпросмотр (ничего не меняет):

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel \
  && cd /opt/infra-relabel \
  && ./relabel.sh all-with-accelerator --dry-run --no-mask --no-selfsteal
```

Безопасный вариант — без `NONINTERACTIVE` (`protect` сам спросит порты):

```bash
cd /opt/infra-relabel && ./install.sh \
  && relabel all-with-accelerator --no-mask --no-selfsteal
```

Флаги можно применять и по отдельности:
`--no-mask` (не переименовывать) или `--no-selfsteal` (не ставить заглушку).

> ⚠️ Порты — строго те, где слушает нода (`ss -tulnp`); loopback-порт заглушки
> (напр. 9443) в фаервол НЕ добавляй. В `WHITELIST` — IP панели и IP каскад-ноды
> (иначе per-IP лимиты порежут трафик, идущий с одного IP на 200 юзеров).

## Ускорение + заглушка, БЕЗ блокировщиков трафика (`--no-block`)

Если нужны **только ускорители и selfsteal-заглушка**, но **без блокировщиков**
(`protect` — nftables-фаервол — и `mobile443` — фильтр портов, которые дропают
трафик), используй флаг `--no-block`. Он выключает оба блокировщика; ставится:
selfsteal → маскировка → `optimize` → `diagnose` → `sysmgr`. **Ничего не
блокирует и не фильтрует порты** — фаервол и порт-фильтр не трогаются.

Так как блокировщиков нет, `TCP_PORTS`/`UDP_PORTS`/`WHITELIST`/`SSH_PORT` **не
нужны** (их использует только `protect`). Скопировать репо, поставить команду и
применить всё одним вызовом. **От root:**

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel \
  && cd /opt/infra-relabel && ./install.sh \
  && NONINTERACTIVE=1 ./relabel.sh all-with-accelerator --no-block
```

> selfsteal спросит домен интерактивно (`NONINTERACTIVE=1` на него не влияет).
> `optimize` ставит XanMod-ядро — после него нужен `reboot` (BBRv3 заработает).

**Предпросмотр** (ничего не меняет, покажет все команды):

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel \
  && cd /opt/infra-relabel && ./relabel.sh all-with-accelerator --dry-run --no-block
```

Чаще всего вместе с `--no-block` нужен и **`--no-mask`** (заглушка + ускорение
без переименований контейнеров):

```bash
cd /opt/infra-relabel && ./install.sh \
  && NONINTERACTIVE=1 ./relabel.sh all-with-accelerator --no-block --no-mask
```

Флаги комбинируются свободно: `--no-block` (без блокировщиков), `--no-mask` (без
переименований), `--no-selfsteal` (без заглушки).

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

## Откат и удаление

```bash
relabel restore-all --dry-run   # предпросмотр отката МАСКИРОВКИ
relabel restore-all             # вернуть имена/образы/проекты/ядро как было

relabel uninstall --dry-run     # предпросмотр ПОЛНОГО удаления
relabel uninstall               # снести всё, что ставил репозиторий, + откат маскировки
```

`uninstall` (полное удаление, в обратном порядке установки):

1. `mobile443` — `asn.sh remove` (снимает фильтр, ipset, systemd-таймер);
2. `accelerator` — `rollback all` (убирает nftables-firewall и тюнинг);
3. `sysmgr` — удаляет `/opt/sysmgr`, команду, лог, базу флота, alias;
4. **размаскировка** — `restore-all` (контейнеры/образы/проекты/ядро как было);
5. снимает команду `relabel` (`/usr/local/bin/relabel`).

> Что `uninstall` НЕ трогает (по соображениям безопасности): **selfsteal-сайт**
> (рабочая заглушка — снимай отдельно его инсталлятором) и **каталог репо**
> (`rm -rf /opt/infra-relabel` вручную). Модули sysmgr, включённые вручную из
> TUI (geoblock/shaper), снимай заранее в самом `sysmgr`. Требует root.

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
| `relabel mobile443` | block-only фильтр портов (дроп blocklist'ов, root) |
| `relabel ps` | показать процессы внутри контейнеров |
| `relabel all` | вся маскировка сразу (A→B→C→D) |
| `relabel all-with-accelerator` | selfsteal + маскировка + `optimize` + `protect` + `mobile443` + `sysmgr` (root). Флаги: `--no-mask` (без переименований), `--no-selfsteal` (без заглушки), `--no-block` (без блокировщиков `protect`/`mobile443`) |
| `relabel uninstall` | ПОЛНОЕ удаление: снять все сервисы + откат маскировки + команду (root) |

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

## Фильтр портов (`mobile443/`, block-only)

В каталоге [`mobile443/`](mobile443/) — **вендоренный** фильтр VPN-портов
(`asn.sh`). Ставим его в режиме **block-only** (**без Telegram** и без
Remnawave-интеграции): на указанных портах **дропаются IP из blocklist'ов**
traffic-guard (гос-сети + антисканеры). Mobile-allowlist в этом режиме
**выключен**, поэтому обычные пользователи НЕ блокируются — режется только
известный «плохой» трафик (сканеры/гос-сети).

```bash
relabel mobile443                       # установить (root): спросит листы и порты
PORTS="443 8443" relabel mobile443      # подсказать порты (по умолчанию 443)
```

`install` интерактивный (спросит, какие листы включить и порты — можно нажать
Enter, тогда возьмутся `PORTS`/443). Если уже установлен — `relabel mobile443`
делает **update** (рефреш blocklist'ов, неинтерактивно). Артефакты:
`/opt/mobile443`, systemd `mobile443-update.timer` (ежедневный рефреш листов),
ipset `traf_guard_*`, iptables-цепочки.

> Блоклист-данные тянутся из стороннего репо `traffic-guard-lists` (это
> **динамические данные**, а не код — их вендорить нет смысла, они обновляются).
> Сам инструмент (`asn.sh`) вендорен — от репо автора не зависим.
> Имена `mobile443`/`*_443` функциональные (де-бренд не запрашивался) — при
> желании переименуем отдельно.
