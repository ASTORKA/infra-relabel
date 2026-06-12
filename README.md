# infra-relabel

Скрипт, который переименовывает docker-контейнеры VPN-ноды под нейтральные
имена, чтобы хостинг в `docker ps` и метках compose не видел характерных
названий (`remnanode`, `caddy-selfsteal`, `remnawave-node-agent`).

Делает это **без простоя**: правит `container_name:` в compose-файле
(с бэкапом) и переименовывает живой контейнер через `docker rename`.
Полностью обратимо.

## Установка на сервер

```bash
git clone https://github.com/ASTORKA/infra-relabel /opt/infra-relabel
cd /opt/infra-relabel
./install.sh            # ставит команду `relabel` в /usr/local/bin
```

После этого скрипт вызывается из любого каталога просто как `relabel`.
`install.sh` создаёт симлинк `/usr/local/bin/relabel → relabel.sh`; конфиг
(`names.conf`) и состояние (`.state/`) остаются в каталоге репозитория.

Можно поставить в другой каталог: `PREFIX=$HOME/bin ./install.sh`.
Удалить: `rm -f /usr/local/bin/relabel`.

## Использование

```bash
relabel status                    # что есть сейчас и что уже замаскировано
relabel apply                     # шаг A1: имена контейнеров (из names.conf)
relabel restore                   # откат имён контейнеров
relabel images                    # шаг A2: имена образов (ретег + пересоздание)
relabel images-restore            # откат имён образов
relabel project [--dry-run]       # шаг B: проект+каталог+сеть compose
relabel project-restore [--dry-run]  # откат проектов/каталогов
relabel ps                        # показать процессы внутри контейнеров
```

> Без установки можно и напрямую: `./relabel.sh status` из каталога репы.

Рекомендуемый порядок: `apply` → проверить `docker ps` → `images` → `project`.

## Маскировка образов (`relabel images`)

`docker ps` показывает не только имя контейнера, но и образ (`remnawave/node`,
`caddy`). Команда `images`:

1. перетегирует образ в нейтральное имя (`app-backend:latest` и т.п. — берётся
   из той же карты `names.conf`, тег сохраняется);
2. правит `image:` в compose-файле (с бэкапом);
3. **пересоздаёт сервис** этим же compose-файлом (`docker compose up -d --no-deps`).

> Пересоздание = короткий рестарт контейнера. Запускайте в спокойное время.
> Откат — `relabel images-restore` (вернёт `image:`, пересоздаст, снимет
> decoy-тег). Сам образ при этом не удаляется — остаётся под исходным именем.

После `apply` проверьте:

```bash
docker ps --format '{{.Names}}\t{{.Image}}'
```

## Карта имён

Редактируется в [`names.conf`](names.conf). Слева — текущее имя, справа —
маскирующее:

```
remnanode            = app-backend
remnawave-node-agent = app-worker
caddy-selfsteal      = web-frontend
```

Можно поменять правые значения на любые свои. После правки — `./relabel.sh apply`.

## Как это работает

1. По имени контейнера скрипт читает docker-метки compose
   (`com.docker.compose.project.config_files` / `working_dir`) и находит
   его `docker-compose.yml`.
2. Делает бэкап файла в `.state/backups/`.
3. Меняет в файле `container_name: <старое>` → `container_name: <новое>`
   (если поля не было — добавляет под нужный сервис).
4. Переименовывает уже запущенный контейнер: `docker rename`.

Файл и живой контейнер остаются согласованными, поэтому при следующем
`docker compose up -d` имя **не откатится**.

Карта отката и бэкапы лежат в `.state/` (в git не попадают).

## Маскировка проекта и каталога (`relabel project`)

После шага A в `docker inspect` (и в `docker ps --format {{.Label ...}}`)
остаются исходные имена compose-проекта, каталога деплоя и сети
(`remnanode`, `/opt/remnanode`, `remnawave-node-agent_default`). Команда
`project` для каждого контейнера:

1. `docker compose down` (старый проект, тома сохраняются);
2. переименовывает каталог деплоя (`/opt/remnanode` → `/opt/app-backend`);
3. переписывает абсолютные ссылки на каталог внутри compose-файлов;
4. `docker compose up -d` с новым именем проекта → новые проект, каталог и
   сеть (`app-backend_default`).

**Защита данных.** Проекты с именованными томами **пропускаются** — чтобы не
осиротить тома (например TLS-сертификаты Caddy). Их имена при необходимости
меняются отдельно, с переносом данных.

> ⚠️ `project` делает `down`+`up` — короткий простой контейнера.
> **Всегда сначала** `relabel project --dry-run` — он покажет точные команды,
> ничего не меняя. Откат — `relabel project-restore`.
>
> Перед запуском проверьте внешние ссылки на каталог (systemd-юниты, скрипты
> обновления ноды): после переименования управлять сервисом нужно из нового
> каталога (`cd /opt/app-backend && docker compose ...`). Скрипт предупреждает
> о найденных ссылках в `/etc/systemd`.

## Процессы (шаг D) — осознанно НЕ маскируем

Remnawave уже сам де-брендирует процессы, поэтому в `ps`/`top` палева почти нет:

| Процесс | comm | Вывод |
|---------|------|-------|
| `caddy run --config ...`          | `caddy`      | обычный веб-сервер, не VPN |
| `node dist/src/main`              | `MainThread` | безликий node-процесс |
| `/usr/local/bin/rw-core -config …`| `rw-core`    | ядро (бывший xray) уже переименовано |

Единственный остаточный след — в аргументах `rw-core` виден путь сокета
`remnawave-internal-*.sock`. Чтобы его убрать, нужно патчить код агента
(имя сокета генерится приложением, не настраивается) — это запекается в образ,
**ломается при каждом обновлении** и рискует уронить ноду ради сокрытия одной
строки. ROI отрицательный → процессы оставляем как есть.

`comm` (имя в `top`) берётся из имени бинаря и меняется только переименованием
файла внутри образа; argv (`ps aux`) — обёрткой `exec -a`. Ни то ни другое для
этой ноды не оправдано.

## Остаточный след: /var/log/remnanode (ручной шаг C)

Агент монтирует пустой каталог `/var/log/remnanode:ro`, видимый в `ls /var/log`.
Маскируется заменой host-пути (контейнер внутри путь не меняет):

```bash
mkdir -p /var/log/app-backend
sed -i.bak 's#/var/log/remnanode:/var/log/remnanode:ro#/var/log/app-backend:/var/log/remnanode:ro#' \
  /opt/app-worker/docker-compose.yml
cd /opt/app-worker && docker compose up -d
rmdir /var/log/remnanode 2>/dev/null
```

## Просмотр процессов

```bash
./relabel.sh ps                 # процессы по каждому контейнеру
docker top app-backend          # процессы конкретного контейнера
ps -ef                          # все процессы хоста
pstree -p                       # дерево процессов
```
