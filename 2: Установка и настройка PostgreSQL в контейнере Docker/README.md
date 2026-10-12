# ДЗ №2. Установка и настройка PostgreSQL в контейнере Docker

**Цель:** развернуть PostgreSQL 14 в Docker-контейнере с данными на хосте, подключиться к нему из контейнера-клиента и с ноутбука, убедиться, что данные переживают пересоздание контейнера.

## Содержание

- [Итог](#итог)
- [Окружение](#окружение)
- [Шаг 1. Виртуальная машина](#шаг-1-виртуальная-машина)
- [Шаг 2. Установка Docker Engine](#шаг-2-установка-docker-engine)
  - [Проблема №1: пакеты из security.debian.org отдают 404](#проблема-1-пакеты-из-securitydebianorg-отдают-404)
- [Шаг 3. Каталог /var/lib/postgres](#шаг-3-каталог-varlibpostgres)
- [Шаг 4. Контейнер с сервером PostgreSQL 14](#шаг-4-контейнер-с-сервером-postgresql-14)
- [Шаг 5. Контейнер с клиентом, создание таблицы](#шаг-5-контейнер-с-клиентом-создание-таблицы)
  - [Проблема №2: клиент не находит сервер по имени](#проблема-2-клиент-не-находит-сервер-по-имени)
  - [Проблема №3: `docker run -i` «съел» остаток скрипта](#проблема-3-docker-run--i-съел-остаток-скрипта)
- [Шаг 6. Подключение с ноутбука](#шаг-6-подключение-с-ноутбука)
  - [Проблема №4: на ноутбуке не было ни psql, ни работающего Docker](#проблема-4-на-ноутбуке-не-было-ни-psql-ни-работающего-docker)
- [Шаг 7. Удаление и пересоздание контейнера с сервером](#шаг-7-удаление-и-пересоздание-контейнера-с-сервером)
- [Шаг 8. Проверка данных](#шаг-8-проверка-данных)
- [Дополнительно: что будет без монтирования каталога](#дополнительно-что-будет-без-монтирования-каталога)
- [Наблюдения и выводы](#наблюдения-и-выводы)
- [Файлы](#файлы)

## Итог

| # | Шаг задания | Результат |
|---|---|---|
| 1 | ВМ с Ubuntu 20.04 или аналогом | ✅ Локальная ВМ в UTM, **Debian 11 (bullseye) arm64** |
| 2 | Установить Docker Engine | ✅ Docker CE 29.8.0 из официального репозитория (после исправления apt-источников) |
| 3 | Создать `/var/lib/postgres` | ✅ |
| 4 | Контейнер PostgreSQL 14 с `/var/lib/postgres` | ✅ `postgres:14` (14.24), bind mount в `/var/lib/postgresql/data` |
| 5 | Контейнер с клиентом | ✅ `psql` из образа `postgres:14` в пользовательской сети `pg-net` |
| 6 | Создать таблицу `shipments` из клиента | ✅ 10 строк |
| 7 | Подключиться с ноутбука | ✅ `psql` 18.6 на macOS → `192.168.64.3:5432` |
| 8 | Удалить и пересоздать контейнер с сервером | ✅ новый container ID, `Skipping initialization` |
| 9 | Проверить, что данные на месте | ✅ 10 строк, сумма `quantity` = 8800 |

## Окружение

```
                    ┌──────────────────────── ВМ debian (192.168.64.3) ────────────────────────┐
 macOS (ноутбук)    │                                                                           │
 psql 18.6  ────────┼──► :5432 (docker-proxy / iptables DNAT)                                   │
 192.168.64.1       │          │                                                                │
                    │          ▼            docker network "pg-net" (172.18.0.0/16)             │
                    │   ┌──────────────┐                 ┌──────────────┐                       │
                    │   │  pg-server   │◄── pg-server ───│  pg-client   │ (postgres:14, --rm)   │
                    │   │ postgres:14  │     :5432       │  psql 14.24  │                       │
                    │   └──────┬───────┘                 └──────────────┘                       │
                    │          │ bind mount                                                     │
                    │          ▼                                                                │
                    │   /var/lib/postgres  ⇄  /var/lib/postgresql/data (PGDATA)                 │
                    └───────────────────────────────────────────────────────────────────────────┘
```

| Компонент | Значение |
|---|---|
| Хост (ноутбук) | macOS 27.0.1, Apple Silicon, гипервизор UTM |
| ВМ | Debian GNU/Linux 11 (bullseye), ядро 5.10.0-18-arm64, 4 vCPU, 1 ГБ RAM, 19 ГБ диск |
| Docker | Docker Engine - Community 29.8.0, containerd v2.3.4, runc 1.5.1 |
| Образ | `postgres:14` → PostgreSQL 14.24 (Debian 14.24-1.pgdg13+2), linux/arm64 |
| Клиент на ноутбуке | `psql (PostgreSQL) 18.6` из Homebrew `libpq` |

## Шаг 1. Виртуальная машина

Вместо Яндекс.Облака я использовал локальную ВМ в UTM: задание разрешает «аналоги», а локальная ВМ бесплатна и быстрее поднимается. Вместо Ubuntu 20.04 на ней стоит **Debian 11**. Для этого задания разница минимальная: Docker ставится из того же официального репозитория, меняется только путь `linux/debian` вместо `linux/ubuntu`.

Подключение по SSH-ключу:

```bash
ssh -i ~/ai_advent_deploy_key debian@192.168.64.3
```

```
$ cat /etc/os-release | head -4; uname -a; nproc; free -h; df -h /
PRETTY_NAME="Debian GNU/Linux 11 (bullseye)"
NAME="Debian GNU/Linux"
VERSION_ID="11"
VERSION="11 (bullseye)"
Linux debian 5.10.0-18-arm64 #1 SMP Debian 5.10.140-1 (2022-09-02) aarch64 GNU/Linux
4
               total        used        free      shared  buff/cache   available
Mem:           974Mi       347Mi       329Mi        10Mi       297Mi       544Mi
Swap:          950Mi          0B       950Mi
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda2        19G  2.3G   15G  13% /
```

> **Мелкие проблемы на старте:**
> 1. Первая попытка SSH завершилась `No route to host`, хотя `ping` проходил: ВМ ещё загружалась, и `sshd` не успел подняться. Повторное подключение через несколько секунд прошло.
> 2. `sudo` требовал пароль, а все шаги выполнялись неинтерактивно, скриптами по SSH. Для учебной ВМ я разрешил пользователю `debian` выполнять sudo без пароля: файл `/etc/sudoers.d/90-debian-nopasswd` со строкой `debian ALL=(ALL) NOPASSWD:ALL`. На продуктивных серверах так делать не стоит.

## Шаг 2. Установка Docker Engine

Docker ставлю по официальной инструкции (<https://docs.docker.com/engine/install/debian/>): GPG-ключ, apt-репозиторий `download.docker.com`, пакеты `docker-ce`, `docker-ce-cli`, `containerd.io`, плагины buildx и compose. Пакет `docker.io` из репозитория Debian не беру: в bullseye он устаревший.

### Проблема №1: пакеты из security.debian.org отдают 404

Первая попытка сразу упала ([logs/01-docker-install-failed.log](logs/01-docker-install-failed.log)):

```
+ sudo apt-get install -y -qq ca-certificates curl gnupg
E: Failed to fetch http://security.debian.org/debian-security/pool/updates/main/g/gnupg2/gpg_2.2.27-2%2bdeb11u3_arm64.deb  404  Not Found [IP: 151.101.66.132 80]
...
E: Failed to fetch http://security.debian.org/debian-security/pool/updates/main/c/curl/curl_7.74.0-1.3%2bdeb11u16_arm64.deb  404  Not Found [IP: 151.101.66.132 80]
E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
+ curl -fsSL https://download.docker.com/linux/debian/gpg
bash: line 7: curl: command not found
+ sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
gpg: no valid OpenPGP data found.
...
E: The repository 'https://download.docker.com/linux/debian bullseye InRelease' is not signed.
E: Unable to locate package containerd.io
```

Ошибки тянутся цепочкой: не установился `curl`, поэтому не скачался GPG-ключ Docker, поэтому apt отверг репозиторий как неподписанный, и пакетов Docker не нашлось. Исправлять нужно первое звено.

**Диагностика** ([logs/02-apt-diag.log](logs/02-apt-diag.log)):

```
$ apt-cache policy curl
curl:
  Installed: (none)
  Candidate: 7.74.0-1.3+deb11u16
  Version table:
     7.74.0-1.3+deb11u16 500
        500 http://security.debian.org/debian-security bullseye-security/main arm64 Packages
     7.74.0-1.3+deb11u13 500
        500 http://deb.debian.org/debian bullseye/main arm64 Packages
```

Индекс `bullseye-security` на `security.debian.org` ещё отдаётся (`Hit`), и apt выбирает из него версию `deb11u16`. А файлов этих пакетов в пуле уже нет. Я проверил зеркала с ноутбука:

```
http://security.debian.org/debian-security/dists/bullseye-security/Release -> 200
http://archive.debian.org/debian-security/dists/bullseye-security/Release -> 200
http://archive.debian.org/debian-security/pool/updates/main/c/curl/curl_7.74.0-1.3%2bdeb11u16_arm64.deb -> 200
```

**Причина:** Debian 11 вышел из LTS-поддержки (август 2026), и его пакеты перенесли на `archive.debian.org`. На основном зеркале остался индекс, а `.deb`-файлы удалены. Получилась рассинхронизация: apt «видит» пакет, но скачать его не может. С Ubuntu 20.04 из задания, кстати, похожая история: её стандартная поддержка закончилась в 2025 году.

**Решение:** переключить `/etc/apt/sources.list` на архив ([logs/03-apt-fix.log](logs/03-apt-fix.log)). Старый файл я сохранил в `/etc/apt/sources.list.bak`.

```bash
sudo tee /etc/apt/sources.list <<'SRC'
deb http://archive.debian.org/debian bullseye main
deb http://archive.debian.org/debian bullseye-updates main
deb http://archive.debian.org/debian-security bullseye-security main
SRC
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
```

```
Get:8 http://archive.debian.org/debian-security bullseye-security/main arm64 Packages [471 kB]
Fetched 15.2 MB in 13s (1,186 kB/s)
...
curl 7.74.0 (aarch64-unknown-linux-gnu) libcurl/7.74.0 OpenSSL/1.1.1n ...
```

После этого Docker установился штатно ([logs/04-docker-install.log](logs/04-docker-install.log)):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bullseye stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker debian     # чтобы не писать sudo перед docker
```

```
Created symlink /etc/systemd/system/multi-user.target.wants/docker.service → /lib/systemd/system/docker.service.
+ systemctl is-active docker
active
+ systemctl is-enabled docker
enabled
+ sudo docker version
Client: Docker Engine - Community
 Version:           29.8.0
 API version:       1.56
 OS/Arch:           linux/arm64
Server: Docker Engine - Community
 Engine:
  Version:          29.8.0
 containerd:
  Version:          v2.3.4
 runc:
  Version:          1.5.1
+ sudo docker run --rm hello-world
Hello from Docker!
This message shows that your installation appears to be working correctly.
...
 2. The Docker daemon pulled the "hello-world" image from the Docker Hub.
    (arm64v8)
```

Членство в группе `docker` применяется только к новым сессиям. Поэтому в текущей сессии я вызывал docker через `sudo`, а все следующие шаги выполнял в новом SSH-подключении, где `id` уже показывает группу `docker`:

```
uid=1000(debian) gid=1000(debian) groups=1000(debian),...,27(sudo),...,997(docker)
```

> ⚠️ Группа `docker` фактически даёт root-доступ к хосту: можно смонтировать `/` в контейнер. На учебной ВМ это допустимо.

## Шаг 3. Каталог /var/lib/postgres

```
$ sudo mkdir -p /var/lib/postgres
$ ls -ld /var/lib/postgres
drwxr-xr-x 2 root root 4096 Oct 12 08:25 /var/lib/postgres
```

Владельца и права вручную я не менял: entrypoint образа `postgres` сам делает `chown`/`chmod 700` на `PGDATA`, потому что стартует от root. Результат видно в шаге 4.

## Шаг 4. Контейнер с сервером PostgreSQL 14

Сначала создаю отдельную пользовательскую сеть. Во встроенной сети `bridge` контейнеры не находят друг друга по имени, а в пользовательской сети работает встроенный DNS Docker (подробнее в проблеме №2).

```bash
docker network create pg-net
docker pull postgres:14
```

Проверяю, что образ есть под arm64 и какая в нём версия:

```
$ docker image inspect postgres:14 --format '{{.Architecture}} {{.Os}} ...'
arm64 linux
PG_VERSION=14.24-1.pgdg13+2
PGDATA=/var/lib/postgresql/data
```

Запуск сервера:

```bash
docker run -d --name pg-server --network pg-net \
  -e POSTGRES_PASSWORD=otus_pass \
  -p 5432:5432 \
  -v /var/lib/postgres:/var/lib/postgresql/data \
  --restart unless-stopped \
  postgres:14
```

| Параметр | Зачем |
|---|---|
| `--network pg-net` | клиентский контейнер будет обращаться к серверу по имени `pg-server` |
| `-e POSTGRES_PASSWORD` | без него образ не стартует; заданный пароль становится паролем суперпользователя `postgres` |
| `-p 5432:5432` | публикует порт на всех интерфейсах ВМ, чтобы подключаться с ноутбука |
| `-v /var/lib/postgres:/var/lib/postgresql/data` | **bind mount** каталога хоста в `PGDATA` контейнера, отсюда и сохранность данных |
| `--restart unless-stopped` | сервер поднимется сам после перезагрузки ВМ или падения процесса |

Результат ([logs/05-pg-server.log](logs/05-pg-server.log)):

```
$ docker ps
NAMES       IMAGE         STATUS         PORTS
pg-server   postgres:14   Up 8 seconds   0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp

$ docker logs pg-server | tail
PostgreSQL init process complete; ready for start up.

2026-10-12 15:27:11.122 UTC [1] LOG:  starting PostgreSQL 14.24 (Debian 14.24-1.pgdg13+2) on aarch64-unknown-linux-gnu, compiled by gcc (Debian 14.2.0-19) 14.2.0, 64-bit
2026-10-12 15:27:11.122 UTC [1] LOG:  listening on IPv4 address "0.0.0.0", port 5432
2026-10-12 15:27:11.122 UTC [1] LOG:  listening on IPv6 address "::", port 5432
2026-10-12 15:27:11.127 UTC [1] LOG:  database system is ready to accept connections
```

Каталог на хосте после первого старта (`initdb` отработал прямо в `/var/lib/postgres`):

```
$ sudo ls -la /var/lib/postgres
drwx------ 19 systemd-timesync root              4096 Oct 12 08:27 .
drwx------  5 systemd-timesync systemd-timesync  4096 Oct 12 08:27 base
drwx------  2 systemd-timesync systemd-timesync  4096 Oct 12 08:27 global
-rw-------  1 systemd-timesync systemd-timesync  4821 Oct 12 08:27 pg_hba.conf
-rw-------  1 systemd-timesync systemd-timesync     3 Oct 12 08:27 PG_VERSION
drwx------  3 systemd-timesync systemd-timesync  4096 Oct 12 08:27 pg_wal
-rw-------  1 systemd-timesync systemd-timesync 28921 Oct 12 08:27 postgresql.conf
-rw-------  1 systemd-timesync systemd-timesync    94 Oct 12 08:27 postmaster.pid
...
```

> **Наблюдение: «почему владелец systemd-timesync?»** Файлы на хосте принадлежат не `postgres`, а `systemd-timesync`. Ничего не сломалось: ядро хранит только числовой UID. Внутри контейнера пользователь `postgres` имеет UID 999, а на хосте UID 999 случайно занят системным пользователем `systemd-timesync`, и `ls` показывает его имя. Права `drwx------` (700) выставил entrypoint образа. Это важно: PostgreSQL откажется стартовать, если `PGDATA` доступен группе или остальным.

## Шаг 5. Контейнер с клиентом, создание таблицы

Отдельный образ для клиента не нужен: в `postgres:14` уже есть `psql`. Контейнер-клиент запускаю с `--rm`: это одноразовый процесс, после выхода он удаляется.

### Проблема №2: клиент не находит сервер по имени

Первая попытка без указания сети ([logs/06-client.log](logs/06-client.log)):

```
$ docker run --rm -e PGPASSWORD=otus_pass postgres:14 psql -h pg-server -U postgres -c 'select 1'
psql: error: could not translate host name "pg-server" to address: Name or service not known
```

**Причина:** без `--network` контейнер попадает в сеть по умолчанию `bridge`, а в ней нет встроенного DNS по именам контейнеров. Сервер к тому же вообще находится в другой сети, `pg-net`.

**Решение:** запускать клиента в той же пользовательской сети `pg-net`. Тогда имя `pg-server` разрешается встроенным DNS Docker (`127.0.0.11`):

```
$ docker run --rm --name pg-client --network pg-net -e PGPASSWORD=otus_pass postgres:14 \
    psql -h pg-server -U postgres -c 'select version();' -c '\conninfo'
                                                          version
----------------------------------------------------------------------------------------------------------------------------
 PostgreSQL 14.24 (Debian 14.24-1.pgdg13+2) on aarch64-unknown-linux-gnu, compiled by gcc (Debian 14.2.0-19) 14.2.0, 64-bit
(1 row)

You are connected to database "postgres" as user "postgres" on host "pg-server" (address "172.18.0.2") at port "5432".
```

Создание таблицы и данных. SQL из задания лежит в [shipments.sql](shipments.sql); файл монтируется в клиентский контейнер только для чтения, `-e` выводит каждую команду:

```
$ docker run --rm -i --name pg-client --network pg-net -e PGPASSWORD=otus_pass \
    -v /home/debian/shipments.sql:/tmp/shipments.sql:ro postgres:14 \
    psql -h pg-server -U postgres -e -f /tmp/shipments.sql
create table shipments(id serial, product_name text, quantity int, destination text);
CREATE TABLE
insert into shipments(product_name, quantity, destination) values('bananas', 1000, 'Europe');
INSERT 0 1
insert into shipments(product_name, quantity, destination) values('bananas', 1500, 'Asia');
INSERT 0 1
insert into shipments(product_name, quantity, destination) values('bananas', 2000, 'Africa');
INSERT 0 1
insert into shipments(product_name, quantity, destination) values('coffee', 500, 'USA');
INSERT 0 1
insert into shipments(product_name, quantity, destination) values('coffee', 700, 'Canada');
INSERT 0 1
insert into shipments(product_name, quantity, destination) values('coffee', 300, 'Japan');
INSERT 0 1
insert into shipments(product_name, quantity, destination) values('sugar', 1000, 'Europe');
INSERT 0 1
insert into shipments(product_name, quantity, destination) values('sugar', 800, 'Asia');
INSERT 0 1
insert into shipments(product_name, quantity, destination) values('sugar', 600, 'Africa');
INSERT 0 1
insert into shipments(product_name, quantity, destination) values('sugar', 400, 'USA');
INSERT 0 1
```

### Проблема №3: `docker run -i` «съел» остаток скрипта

Шаги выполнялись так: `ssh ... 'bash -s' <<EOF ... EOF`, то есть скрипт подаётся в `bash` через stdin. Команда с проверкой (`select * from shipments`), стоявшая после загрузки, **не выполнилась вовсе**, причём без всякой ошибки.

**Причина:** флаг `-i` (interactive) привязывает stdin контейнера к stdin процесса. Этот stdin общий с `bash -s`, поэтому `docker run -i` вычитал остаток скрипта как будто это ввод для `psql`. `psql -f` его проигнорировал, а `bash` после этого нечего было выполнять.

**Решение:** для неинтерактивных запусков не указывать `-i` или явно отдавать `</dev/null`. В следующих шагах я делаю именно так. Проверка из клиентского контейнера ([logs/07-client-select.log](logs/07-client-select.log)):

```
$ docker run --rm --network pg-net -e PGPASSWORD=otus_pass postgres:14 \
    psql -h pg-server -U postgres -c '\dt' -c 'select * from shipments order by id;'
           List of relations
 Schema |   Name    | Type  |  Owner
--------+-----------+-------+----------
 public | shipments | table | postgres
(1 row)

 id | product_name | quantity | destination
----+--------------+----------+-------------
  1 | bananas      |     1000 | Europe
  2 | bananas      |     1500 | Asia
  3 | bananas      |     2000 | Africa
  4 | coffee       |      500 | USA
  5 | coffee       |      700 | Canada
  6 | coffee       |      300 | Japan
  7 | sugar        |     1000 | Europe
  8 | sugar        |      800 | Asia
  9 | sugar        |      600 | Africa
 10 | sugar        |      400 | USA
(10 rows)
```

## Шаг 6. Подключение с ноутбука

Для удалённого подключения должны выполняться три условия:

1. **Порт опубликован:** `-p 5432:5432`, то есть `0.0.0.0:5432` на ВМ, это видно в `docker ps`.
2. **PostgreSQL слушает не только localhost.** В официальном образе `listen_addresses = '*'` уже стоит (в логе: `listening on IPv4 address "0.0.0.0"`).
3. **pg_hba.conf пускает внешние адреса.** Entrypoint образа при `initdb` добавляет строку `host all all all scram-sha-256` (когда задан `POSTGRES_PASSWORD`).

Файрвола на ВМ нет. Сначала проверяю сетевую доступность порта с ноутбука:

```
$ nc -vz -G 3 192.168.64.3 5432
Connection to 192.168.64.3 port 5432 [tcp/postgresql] succeeded!
```

### Проблема №4: на ноутбуке не было ни psql, ни работающего Docker

Первая идея была запустить на Mac тот же `postgres:14` как клиент, но Docker-демон (Colima) на ноутбуке не был запущен:

```
$ docker run --rm -e PGPASSWORD=otus_pass postgres:14 psql -h 192.168.64.3 -U postgres ...
failed to connect to the docker API at unix:///Users/dmitry/.colima/default/docker.sock; check if the path is correct and if the daemon is running: dial unix /Users/dmitry/.colima/default/docker.sock: connect: no such file or directory
```

**Решение:** поставить нативный клиент. Поднимать целую Linux-ВМ ради одного `psql` незачем. Пакет `libpq` из Homebrew устанавливается keg-only, то есть не меняет `PATH` и не конфликтует с другими установками PostgreSQL:

```bash
brew install libpq
/opt/homebrew/opt/libpq/bin/psql --version
# psql (PostgreSQL) 18.6
```

Клиент 18-й версии без проблем подключается к серверу 14-й: протокол v3 совместим. Только некоторые `\d`-команды могут показывать предупреждение о версиях.

Подключение ([logs/08-laptop.log](logs/08-laptop.log)):

```
$ PGPASSWORD=otus_pass psql -h 192.168.64.3 -U postgres \
    -c '\conninfo' \
    -c "select inet_server_addr(), inet_client_addr(), current_setting('server_version');" \
    -c 'select product_name, sum(quantity) total from shipments group by 1 order by 1;'
       Connection Information
      Parameter       |    Value
----------------------+--------------
 Database             | postgres
 Client User          | postgres
 Host                 | 192.168.64.3
 Server Port          | 5432
 Protocol Version     | 3.0
 Password Used        | true
 SSL Connection       | false
 Superuser            | on
 Hot Standby          | off
(12 rows)

 inet_server_addr | inet_client_addr |         current_setting
------------------+------------------+---------------------------------
 172.18.0.2       | 192.168.64.1     | 14.24 (Debian 14.24-1.pgdg13+2)
(1 row)

 product_name | total
--------------+-------
 bananas      |  4500
 coffee       |  1500
 sugar        |  2800
(3 rows)
```

Что видно из вывода:
- `inet_server_addr = 172.18.0.2`: сервер видит соединение на своём адресе внутри сети `pg-net`, а не на `192.168.64.3`. Docker пробрасывает порт через DNAT.
- `inet_client_addr = 192.168.64.1`: это адрес Mac на мосту `bridge100` UTM. NAT сохранил исходный адрес клиента, поэтому правила `pg_hba.conf` по подсети работали бы корректно.
- Аутентификация по паролю действительно работает. С неверным паролем:

```
$ PGPASSWORD=wrong psql -h 192.168.64.3 -U postgres -c 'select 1'
psql: error: connection to server at "192.168.64.3", port 5432 failed: FATAL:  password authentication failed for user "postgres"
```

> ⚠️ `SSL Connection: false`: пароль и данные идут открытым текстом. Внутри локальной сети UTM это допустимо, но в облаке с публичным IP так оставлять нельзя. Нужно либо ограничить доступ к 5432 security group'ой или файрволом, либо подключаться через SSH-туннель (`ssh -L 5432:localhost:5432 ...`), либо включить SSL.

## Шаг 7. Удаление и пересоздание контейнера с сервером

([logs/09-recreate.log](logs/09-recreate.log))

```
$ docker ps -a
CONTAINER ID   NAMES       STATUS
eaa231a7c8ef   pg-server   Up About a minute

$ docker stop pg-server && docker rm pg-server
pg-server
pg-server

$ docker ps -a
CONTAINER ID   NAMES     STATUS
                                        ← контейнеров нет
$ docker volume ls
DRIVER    VOLUME NAME
                                        ← и docker volume'ов нет: данные только в каталоге хоста
$ sudo du -sh /var/lib/postgres
42M	/var/lib/postgres
```

`docker stop` отправляет SIGTERM и даёт PostgreSQL штатно завершиться (smart/fast shutdown с checkpoint). Это лучше, чем `docker rm -f`: тот шлёт SIGKILL, и при следующем старте понадобится crash recovery.

Создаю контейнер заново той же командой:

```
$ docker run -d --name pg-server --network pg-net \
    -e POSTGRES_PASSWORD=otus_pass -p 5432:5432 \
    -v /var/lib/postgres:/var/lib/postgresql/data \
    --restart unless-stopped postgres:14
9ff3786077f07c9d9e97c18fb4dcd8df271d4268f2402cec2f5a902cad439cf6

$ docker ps
CONTAINER ID   NAMES       STATUS         PORTS
9ff3786077f0   pg-server   Up 5 seconds   0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp
```

Container ID новый (`9ff3786077f0` вместо `eaa231a7c8ef`). Ключевая строка в логе:

```
$ docker logs pg-server

PostgreSQL Database directory appears to contain a database; Skipping initialization

2026-10-12 15:28:32.277 UTC [1] LOG:  starting PostgreSQL 14.24 (Debian 14.24-1.pgdg13+2) on aarch64-unknown-linux-gnu ...
2026-10-12 15:28:32.280 UTC [27] LOG:  database system was shut down at 2026-10-12 15:28:31 UTC
2026-10-12 15:28:32.281 UTC [1] LOG:  database system is ready to accept connections
```

- `Skipping initialization`: entrypoint нашёл `PG_VERSION` в смонтированном каталоге и не стал запускать `initdb`.
- `database system was shut down at ...` (а не `was interrupted`): предыдущий экземпляр остановился чисто, recovery не потребовался.
- Важное следствие: при повторном старте **`POSTGRES_PASSWORD` больше ни на что не влияет**. Пароль хранится в самой базе (`pg_authid`), и смена переменной окружения его не изменит. На этом часто попадаются.

## Шаг 8. Проверка данных

Из нового клиентского контейнера:

```
$ docker run --rm --network pg-net -e PGPASSWORD=otus_pass postgres:14 psql -h pg-server -U postgres \
    -c "select pg_postmaster_start_time();" -c 'select count(*) from shipments;' -c 'select * from shipments order by id;'
   pg_postmaster_start_time
------------------------------
 2026-10-12 15:28:32.27954+00          ← сервер только что перезапущен
(1 row)

 count
-------
    10
(1 row)

 id | product_name | quantity | destination
----+--------------+----------+-------------
  1 | bananas      |     1000 | Europe
  2 | bananas      |     1500 | Asia
  3 | bananas      |     2000 | Africa
  4 | coffee       |      500 | USA
  5 | coffee       |      700 | Canada
  6 | coffee       |      300 | Japan
  7 | sugar        |     1000 | Europe
  8 | sugar        |      800 | Asia
  9 | sugar        |      600 | Africa
 10 | sugar        |      400 | USA
(10 rows)
```

И с ноутбука ([logs/10-laptop-after.log](logs/10-laptop-after.log)):

```
$ PGPASSWORD=otus_pass psql -h 192.168.64.3 -U postgres -c 'select count(*), sum(quantity) from shipments;'
 count | sum
-------+------
    10 | 8800
(1 row)
```

**Данные на месте** ✅

## Дополнительно: что будет без монтирования каталога

Чтобы показать, от чего защищает bind mount, я запустил контейнер без `-v` ([logs/11-no-volume-demo.log](logs/11-no-volume-demo.log)):

```
$ docker run -d --name pg-ephemeral --network pg-net -e POSTGRES_PASSWORD=otus_pass postgres:14
$ psql -h pg-ephemeral ... -c "create table t(x int); insert into t values (42);" -c 'select * from t;'
 x
----
 42

$ docker inspect pg-ephemeral --format '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}}{{end}}'
volume 39cc3def66e45c832c7b91e562a3372b1c06ef957d8cef4d9998b680d1a3b2b3 -> /var/lib/postgresql/data

$ docker rm -f pg-ephemeral
$ docker run -d --name pg-ephemeral --network pg-net -e POSTGRES_PASSWORD=otus_pass postgres:14
$ psql -h pg-ephemeral ... -c 'select * from t;'
ERROR:  relation "t" does not exist

$ docker rm -fv pg-ephemeral && docker volume prune -f
Deleted Volumes:
39cc3def66e45c832c7b91e562a3372b1c06ef957d8cef4d9998b680d1a3b2b3
Total reclaimed space: 43.53MB
```

Нюанс: даже без `-v` данные на самом деле не пишутся в слой контейнера. В Dockerfile образа `postgres` объявлен `VOLUME /var/lib/postgresql/data`, поэтому Docker создаёт **анонимный том**. После `docker rm -f` (без `-v`) этот том остаётся на диске, но новый контейнер получает *другой* анонимный том с пустым кластером. Данные формально не удалены, а осиротели: найти и подключить их можно только по хешу. Это видно по `docker volume prune`, который удалил первый том на 43 МБ. Именованный том (`-v pgdata:/var/lib/postgresql/data`) или bind mount, как в этом задании, решает проблему.

## Наблюдения и выводы

1. **Bind mount `/var/lib/postgres` → `PGDATA`** отделяет жизненный цикл данных от жизненного цикла контейнера. Контейнер можно удалить, обновить минорную версию образа (`14.x` → `14.y`) или пересоздать с другими параметрами, и кластер подхватится. Мажорное обновление (14 → 15+) так не сработает: понадобится `pg_upgrade` или dump/restore.
2. **Пользовательская сеть** нужна для обращения между контейнерами по имени. В дефолтной `bridge` DNS по именам нет.
3. **Порт, опубликованный через `-p`, открыт на всех интерфейсах** (`0.0.0.0`) и обходит правила `ufw`/`iptables INPUT`, потому что Docker пишет свои правила в цепочку `DOCKER`. Если внешний доступ не нужен, лучше `-p 127.0.0.1:5432:5432`.
4. **Переменные `POSTGRES_*` применяются только при инициализации** пустого каталога.
5. **UID внутри и снаружи контейнера совпадают численно**, отсюда «странный» владелец файлов на хосте. Если нужен другой UID, можно запускать с `--user` (каталог тогда нужно заранее подготовить с правильным владельцем и правами 700).
6. **EOL-дистрибутивы** (Debian 11, Ubuntu 20.04) требуют переключения apt на архивные зеркала. Для новых стендов лучше брать актуальный LTS.

## Файлы

| Файл | Описание |
|---|---|
| [README.md](README.md) | этот отчёт |
| [shipments.sql](shipments.sql) | SQL из задания |
| [commands.sh](commands.sh) | все команды одним скриптом для воспроизведения на чистой ВМ |
| [logs/](logs/) | полный вывод консоли по каждому шагу (`set -x`), включая неудачные попытки |

Пароль `otus_pass` используется только на изолированной учебной ВМ.
