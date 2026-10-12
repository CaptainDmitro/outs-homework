# ДЗ №2. Установка и настройка PostgreSQL в контейнере Docker

## 1. Создание инстанса

Вместо инстанса в Яндекс.Облаке использовал локальную ВМ в UTM (аналог) с Debian 11 вместо Ubuntu 20.04. Подключение по SSH:

```bash
ssh debian@192.168.64.3
```

```
$ cat /etc/os-release | head -4; uname -a
PRETTY_NAME="Debian GNU/Linux 11 (bullseye)"
NAME="Debian GNU/Linux"
VERSION_ID="11"
VERSION="11 (bullseye)"
Linux debian 5.10.0-18-arm64 #1 SMP Debian 5.10.140-1 (2022-09-02) aarch64 GNU/Linux
```

## 2. Установка Docker Engine

Установил Docker Engine из официального репозитория ([logs/04-docker-install.log](logs/04-docker-install.log)):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bullseye stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker debian
```

```
$ systemctl is-active docker
active
$ sudo docker version
Client: Docker Engine - Community
 Version:           29.8.0
...
Server: Docker Engine - Community
 Engine:
  Version:          29.8.0
$ sudo docker run --rm hello-world
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

## 3. Создание каталога /var/lib/postgres

```
$ sudo mkdir -p /var/lib/postgres
$ ls -ld /var/lib/postgres
drwxr-xr-x 2 root root 4096 Oct 12 08:25 /var/lib/postgres
```

## 4. Контейнер с PostgreSQL 14

Создал сеть, чтобы контейнер с клиентом обращался к серверу по имени, и запустил сервер с каталогом `/var/lib/postgres`, смонтированным в каталог данных PostgreSQL ([logs/05-pg-server.log](logs/05-pg-server.log)):

```bash
docker network create pg-net
docker run -d --name pg-server --network pg-net \
  -e POSTGRES_PASSWORD=otus_pass \
  -p 5432:5432 \
  -v /var/lib/postgres:/var/lib/postgresql/data \
  --restart unless-stopped \
  postgres:14
```

```
$ docker ps
NAMES       IMAGE         STATUS         PORTS
pg-server   postgres:14   Up 8 seconds   0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp

$ docker logs pg-server | tail -3
2026-10-12 15:27:11.122 UTC [1] LOG:  starting PostgreSQL 14.24 (Debian 14.24-1.pgdg13+2) on aarch64-unknown-linux-gnu, compiled by gcc (Debian 14.2.0-19) 14.2.0, 64-bit
2026-10-12 15:27:11.122 UTC [1] LOG:  listening on IPv4 address "0.0.0.0", port 5432
2026-10-12 15:27:11.127 UTC [1] LOG:  database system is ready to accept connections

$ sudo ls -la /var/lib/postgres
drwx------ 19 systemd-timesync root              4096 Oct 12 08:27 .
drwx------  5 systemd-timesync systemd-timesync  4096 Oct 12 08:27 base
drwx------  2 systemd-timesync systemd-timesync  4096 Oct 12 08:27 global
-rw-------  1 systemd-timesync systemd-timesync  4821 Oct 12 08:27 pg_hba.conf
-rw-------  1 systemd-timesync systemd-timesync     3 Oct 12 08:27 PG_VERSION
drwx------  3 systemd-timesync systemd-timesync  4096 Oct 12 08:27 pg_wal
-rw-------  1 systemd-timesync systemd-timesync 28921 Oct 12 08:27 postgresql.conf
...
```

## 5. Контейнер с клиентом PostgreSQL

В качестве клиента запустил контейнер из того же образа `postgres:14`, в нём уже есть `psql` ([logs/06-client.log](logs/06-client.log)).

**Проблема:** клиент не находил сервер по имени:

```
$ docker run --rm -e PGPASSWORD=otus_pass postgres:14 psql -h pg-server -U postgres -c 'select 1'
psql: error: could not translate host name "pg-server" to address: Name or service not known
```

**Решение:** без `--network` контейнер попадает в сеть `bridge` по умолчанию, где нет DNS по именам контейнеров. Запустил клиента в сети `pg-net`:

```
$ docker run --rm --name pg-client --network pg-net -e PGPASSWORD=otus_pass postgres:14 \
    psql -h pg-server -U postgres -c 'select version();' -c '\conninfo'
                                                          version
----------------------------------------------------------------------------------------------------------------------------
 PostgreSQL 14.24 (Debian 14.24-1.pgdg13+2) on aarch64-unknown-linux-gnu, compiled by gcc (Debian 14.2.0-19) 14.2.0, 64-bit
(1 row)

You are connected to database "postgres" as user "postgres" on host "pg-server" (address "172.18.0.2") at port "5432".
```

## 6. Подключение из клиента и создание таблицы

SQL из задания сохранил в [shipments.sql](shipments.sql) и выполнил из контейнера с клиентом ([logs/06-client.log](logs/06-client.log)):

```
$ docker run --rm -i --name pg-client --network pg-net -e PGPASSWORD=otus_pass \
    -v /home/debian/shipments.sql:/tmp/shipments.sql:ro postgres:14 \
    psql -h pg-server -U postgres -e -f /tmp/shipments.sql
create table shipments(id serial, product_name text, quantity int, destination text);
CREATE TABLE
insert into shipments(product_name, quantity, destination) values('bananas', 1000, 'Europe');
INSERT 0 1
...
insert into shipments(product_name, quantity, destination) values('sugar', 400, 'USA');
INSERT 0 1
```

**Проблема:** из-за флага `-i` проверочная команда, стоявшая в скрипте следом, не выполнилась. `docker run -i` прочитал остаток скрипта, который передавался по SSH через stdin (`bash -s`).

**Решение:** выполнил проверку отдельной командой без `-i` ([logs/07-client-select.log](logs/07-client-select.log)):

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

## 7. Подключение с ноутбука

Порт 5432 опубликован на ВМ (`-p 5432:5432`), а образ `postgres` по умолчанию слушает все адреса и разрешает вход по паролю с любых адресов.

```
$ PGPASSWORD=otus_pass /opt/homebrew/opt/libpq/bin/psql -h 192.168.64.3 -U postgres \
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
 ...
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

## 8. Удаление и пересоздание контейнера с сервером

([logs/09-recreate.log](logs/09-recreate.log))

```
$ docker stop pg-server && docker rm pg-server
pg-server
pg-server

$ docker ps -a
CONTAINER ID   NAMES     STATUS

$ docker run -d --name pg-server --network pg-net \
    -e POSTGRES_PASSWORD=otus_pass -p 5432:5432 \
    -v /var/lib/postgres:/var/lib/postgresql/data \
    --restart unless-stopped postgres:14
9ff3786077f07c9d9e97c18fb4dcd8df271d4268f2402cec2f5a902cad439cf6

$ docker logs pg-server
PostgreSQL Database directory appears to contain a database; Skipping initialization
...
2026-10-12 15:28:32.281 UTC [1] LOG:  database system is ready to accept connections
```

Новый контейнер нашёл существующий кластер в `/var/lib/postgres` и не стал инициализировать его заново.

## 9. Проверка данных

Из контейнера с клиентом ([logs/09-recreate.log](logs/09-recreate.log)):

```
$ docker run --rm --network pg-net -e PGPASSWORD=otus_pass postgres:14 \
    psql -h pg-server -U postgres -c "select pg_postmaster_start_time();" -c 'select count(*) from shipments;' -c 'select * from shipments order by id;'
   pg_postmaster_start_time
------------------------------
 2026-10-12 15:28:32.27954+00
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

С ноутбука ([logs/10-laptop-after.log](logs/10-laptop-after.log)):

```
$ PGPASSWORD=otus_pass /opt/homebrew/opt/libpq/bin/psql -h 192.168.64.3 -U postgres -c 'select count(*), sum(quantity) from shipments;'
 count | sum
-------+------
    10 | 8800
(1 row)
```

Данные сохранились после удаления и пересоздания контейнера.
