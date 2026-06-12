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
relabel status     # что есть сейчас и что уже замаскировано
relabel apply      # применить маскировку (имена из names.conf)
relabel restore    # откатить к исходным именам
relabel ps         # показать процессы внутри контейнеров
```

> Без установки можно и напрямую: `./relabel.sh status` из каталога репы.

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

## Что НЕ входит (пока)

- **Имена образов** (колонка `IMAGE` в `docker ps` — там видно
  `remnawave/node`). Маскируется ретегом образов — отдельным шагом.
- **Имена процессов** внутри контейнеров (`xray`, `caddy`, node-агент).
  Их видно через `./relabel.sh ps` или `docker top`. Маскировка процессов
  инвазивна (подмена бинаря / argv[0]) и может ломать обновления —
  выносится отдельно.

## Просмотр процессов

```bash
./relabel.sh ps                 # процессы по каждому контейнеру
docker top app-backend          # процессы конкретного контейнера
ps -ef                          # все процессы хоста
pstree -p                       # дерево процессов
```
