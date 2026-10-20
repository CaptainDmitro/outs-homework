# ДЗ №8. Managed Service for PostgreSQL

## 1. Создать кластер. Ресурсы: 1 vCPU, 1 ГБ RAM

Кластер создавал через Yandex Cloud CLI (`yc` 1.34.0) с Mac.

**Проблема:** в первом облаке единственный каталог `default` находился в статусе `DELETING`. Создать в нём сеть не удалось (`PermissionDenied: Operation is not permitted in the folder`), новый каталог тоже (`Permission denied`) ([logs/01-network-failed.log](logs/01-network-failed.log), [logs/02-folder-failed.log](logs/02-folder-failed.log), [logs/03-network-failed.log](logs/03-network-failed.log)).

**Решение:** создал новое облако `cloud-captain-dmitro-otushw` и заново выполнил `yc init` в его каталоге `default`. Сеть `default` с подсетями во всех зонах там создаётся автоматически.

**Проблема:** класса хостов 1 vCPU / 1 ГБ в Managed Service for PostgreSQL нет. Самые маленькие классы — `b2.medium` и `c3-c2-m4` (2 vCPU, 4 ГБ), оба только в зонах `ru-central1-d` и `ru-central1-e`:

```
$ yc postgres resource-preset list --limit 1000 --format json | python3 -c '...memory<=4GB...'
b2.medium 2 4.0 ['ru-central1-d', 'ru-central1-e']
c3-c2-m4 2 4.0 ['ru-central1-d', 'ru-central1-e']
```

**Решение:** взял минимальный `b2.medium`: 2 vCPU с гарантированной долей 50%, 4 ГБ RAM. Один хост, без реплик, диск `network-ssd` 10 ГБ (минимум).

Сначала создал группу безопасности для доступа с моего IP (п. 2), затем кластер ([logs/08-cluster-create.log](logs/08-cluster-create.log)):

```bash
yc postgres cluster create \
  --name otus-pg \
  --environment production \
  --network-name default \
  --security-group-ids enp4g2tqhtcnub933ujh \
  --host zone-id=ru-central1-e,subnet-name=default-ru-central1-e,assign-public-ip=true \
  --postgresql-version 17 \
  --resource-preset b2.medium \
  --disk-type network-ssd \
  --disk-size 10 \
  --disk-size-autoscaling planned-usage-threshold=80,emergency-usage-threshold=90,disk-size-limit=21474836480 \
  --maintenance-window type=weekly,day=SUN,hour=3 \
  --user name=banana,password=otus_pass_8 \
  --database name=bananaflow,owner=banana
```

```
...done (9m47s)
id: c9qssrecqhfgosn3jo9b
name: otus-pg
environment: PRODUCTION
config:
  version: "17"
...
```

**Проблема:** первые две попытки отклонил API ([logs/05-cluster-create-failed.log](logs/05-cluster-create-failed.log), [logs/06-cluster-create-failed.log](logs/06-cluster-create-failed.log)), третья не прошла разбор аргументов ([logs/07-cluster-create-failed.log](logs/07-cluster-create-failed.log)):

```
ERROR: rpc error: code = InvalidArgument desc = if planned usage threshold is set maintenance window must be specified
ERROR: rpc error: code = InvalidArgument desc = disk size limit must be more than disk size
ERROR: invalid argument "20GB" for "disk-size-limit" property: strconv.ParseInt: parsing "20GB": invalid syntax
```

**Решение:** плановое увеличение диска (`planned-usage-threshold`) выполняется в окно обслуживания, поэтому добавил `--maintenance-window type=weekly,day=SUN,hour=3`. `disk-size-limit` задаётся в байтах (в отличие от `--disk-size` в ГБ): `20` означало 20 байт. Указал 20 ГБ = `21474836480`.

Параметры созданного кластера ([logs/09-cluster-params.log](logs/09-cluster-params.log)):

```
$ yc postgres cluster get otus-pg --format json | jq '{name, environment, status, health, version: .config.version, resources: .config.resources, disk_size_autoscaling: .config.disk_size_autoscaling, access: .config.access, maintenance_window, security_group_ids}'
{
  "name": "otus-pg",
  "environment": "PRODUCTION",
  "status": "RUNNING",
  "health": null,
  "version": "17",
  "resources": {
    "resource_preset_id": "b2.medium",
    "disk_size": "10737418240",
    "disk_type_id": "network-ssd"
  },
  "disk_size_autoscaling": {
    "planned_usage_threshold": "80",
    "emergency_usage_threshold": "90",
    "disk_size_limit": "21474836480"
  },
  "access": {},
  "maintenance_window": {
    "weekly_maintenance_window": {
      "day": "SUN",
      "hour": "3"
    }
  },
  "security_group_ids": [
    "enp4g2tqhtcnub933ujh"
  ]
}

$ yc postgres user list --cluster-name otus-pg
+--------+-------------+----------------------+------------+
|  NAME  | PERMISSIONS |    CONNECTION ID     | CONN LIMIT |
+--------+-------------+----------------------+------------+
| banana | bananaflow  | a59k8iqmoecptiq5us03 |         50 |
+--------+-------------+----------------------+------------+

$ yc postgres database list --cluster-name otus-pg
+------------+----------------------+--------+------------+---------+------------+-------------------+
|    NAME    |      CLUSTER ID      | OWNER  | LC COLLATE | LC TYPE | EXTENSIONS | TEMPLATE DATABASE |
+------------+----------------------+--------+------------+---------+------------+-------------------+
| bananaflow | c9qssrecqhfgosn3jo9b | banana | C          | C       |            |                   |
+------------+----------------------+--------+------------+---------+------------+-------------------+
```

## 2. Разрешить доступ с вашего IP

Хост кластера получил публичный адрес (`assign-public-ip=true`). Входящий доступ ограничен группой безопасности `otus-pg-sg`: открыт только TCP 6432 (порт пулера Odyssey, через который Managed PostgreSQL принимает подключения) и только с моего IP. Сначала добавил те адреса, которые показал `ifconfig.me`; он попеременно отдавал два ([logs/04-network.log](logs/04-network.log)):

```bash
yc vpc security-group create --name otus-pg-sg --network-name default \
  --rule "description=psql from my IP,direction=ingress,port=6432,protocol=tcp,v4-cidrs=[95.85.249.52/32,95.85.243.6/32]"
```

**Проблема:** psql не смог подключиться ([logs/10-psql-failed.log](logs/10-psql-failed.log)), повторная попытка завершилась `timeout expired`:

```
psql: error: connection to server at "rc1e-6gbc9ajfe68rdr30.mdb.yandexcloud.net" (153.51.113.144), port 6432 failed: server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
```

**Решение:** на Mac работает VPN-клиент (туннель `utun13`), который отправляет российские адреса напрямую, а остальные через VPN. `ifconfig.me` показывает IP выхода VPN, а кластер в Yandex Cloud видит прямой адрес провайдера, `85.172.184.54`. Узнал его через сервис Яндекса и заменил правило в группе безопасности ([logs/11-allow-ip.log](logs/11-allow-ip.log)):

```
$ curl -s https://ifconfig.me
95.85.249.52
$ curl -s https://yandex.ru/internet/api/v0/ip
"85.172.184.54"

$ yc vpc security-group update-rules otus-pg-sg \
  --delete-rule-id enpavn9kefjq26883aem \
  --add-rule "description=psql from my IP,direction=ingress,port=6432,protocol=tcp,v4-cidrs=[85.172.184.54/32]"
...
rules:
  - id: enpafu8qqotu1p7eqqoh
    description: psql from my IP
    direction: INGRESS
    ports:
      from_port: "6432"
      to_port: "6432"
    protocol_name: TCP
    cidr_blocks:
      v4_cidr_blocks:
        - 85.172.184.54/32
```

## 3. Подключиться через psql

Клиент: `psql` 18.6 из Homebrew (`libpq`). Подключение по SSL с проверкой сертификата сервера (`sslmode=verify-full`), поэтому сначала скачал корневой сертификат Yandex Cloud:

```bash
mkdir -p ~/.postgresql
curl -sS https://storage.yandexcloud.net/cloud-certs/CA.pem -o ~/.postgresql/root.crt
chmod 0655 ~/.postgresql/root.crt
```

Команда подключения ([logs/12-psql.log](logs/12-psql.log)):

```bash
export PGPASSWORD=otus_pass_8
psql "host=rc1e-6gbc9ajfe68rdr30.mdb.yandexcloud.net port=6432 sslmode=verify-full dbname=bananaflow user=banana target_session_attrs=read-write"
```

```
bananaflow=> \conninfo
                      Connection Information
      Parameter       |                   Value
----------------------+-------------------------------------------
 Database             | bananaflow
 Client User          | banana
 Host                 | rc1e-6gbc9ajfe68rdr30.mdb.yandexcloud.net
 Host Address         | 153.51.113.144
 Server Port          | 6432
...
 SSL Connection       | true
 SSL Library          | OpenSSL
 SSL Protocol         | TLSv1.3
 SSL Cipher           | TLS_AES_256_GCM_SHA384
...
 Superuser            | off

bananaflow=> select version();
 PostgreSQL 17.11 (Ubuntu 17.11-201-yandex.60286.5a0f49380c) on x86_64-pc-linux-gnu, compiled by gcc (Ubuntu 11.4.0-1ubuntu1~22.04.3) 11.4.0, 64-bit
```

## 4. Проверить работоспособность кластера

Состояние кластера и хоста в Yandex Cloud ([logs/13-health.log](logs/13-health.log)):

```
$ yc postgres cluster list
+----------------------+---------+---------------------+--------+---------+
|          ID          |  NAME   |     CREATED AT      | HEALTH | STATUS  |
+----------------------+---------+---------------------+--------+---------+
| c9qssrecqhfgosn3jo9b | otus-pg | 2026-10-20 16:09:30 | ALIVE  | RUNNING |
+----------------------+---------+---------------------+--------+---------+

$ yc postgres host list --cluster-name otus-pg
+-------------------------------------------+----------------------+--------+--------+---------------+-----------+--------------------+
|                   NAME                    |      CLUSTER ID      |  ROLE  | HEALTH |    ZONE ID    | PUBLIC IP | REPLICATION SOURCE |
+-------------------------------------------+----------------------+--------+--------+---------------+-----------+--------------------+
| rc1e-6gbc9ajfe68rdr30.mdb.yandexcloud.net | c9qssrecqhfgosn3jo9b | MASTER | ALIVE  | ru-central1-e | true      |                    |
+-------------------------------------------+----------------------+--------+--------+---------------+-----------+--------------------+
```

Запись и чтение в той же сессии psql ([logs/12-psql.log](logs/12-psql.log)):

```
bananaflow=> select inet_client_addr(), current_user, current_database(), pg_is_in_recovery();
 inet_client_addr | current_user | current_database | pg_is_in_recovery
------------------+--------------+------------------+-------------------
 127.0.0.1        | banana       | bananaflow       | f

bananaflow=> create table shipments (id bigserial primary key, cargo text not null, weight_kg numeric(8,2), created_at timestamptz default now());
CREATE TABLE
bananaflow=> insert into shipments (cargo, weight_kg) values ('bananas', 1200.50), ('mangoes', 340.00), ('pineapples', 815.25);
INSERT 0 3
bananaflow=> select id, cargo, weight_kg from shipments order by id;
 id |   cargo    | weight_kg
----+------------+-----------
  1 | bananas    |   1200.50
  2 | mangoes    |    340.00
  3 | pineapples |    815.25

bananaflow=> select count(*), sum(weight_kg) from shipments;
 count |   sum
-------+---------
     3 | 2355.75

bananaflow=> select pg_size_pretty(pg_database_size(current_database()));
 pg_size_pretty
----------------
 7758 kB
```

`pg_is_in_recovery() = f`: подключение идёт к мастеру. `inet_client_addr()` равен `127.0.0.1`, потому что клиент подключается к пулеру Odyssey на хосте, а тот уже к PostgreSQL.

## 5. Задокументировать шаги

- Параметры кластера: п. 1 (`otus-pg`, PostgreSQL 17, `b2.medium` 2 vCPU 50% / 4 ГБ, `network-ssd` 10 ГБ, один хост в `ru-central1-e` с публичным IP).
- Команда подключения: п. 3.
- Пример выполненного запроса: п. 4.

## ⭐ Автомасштабирование

Managed Service for PostgreSQL не умеет автоматически менять класс хоста (vCPU/RAM). Автоматически растёт только размер диска, и его я включил при создании кластера (п. 1):

- `planned-usage-threshold=80`: при заполнении диска на 80% он увеличивается в ближайшее окно обслуживания (воскресенье, 03:00 UTC);
- `emergency-usage-threshold=90`: при 90% диск увеличивается сразу;
- `disk-size-limit=21474836480`: до 20 ГБ максимум.

```
  "disk_size_autoscaling": {
    "planned_usage_threshold": "80",
    "emergency_usage_threshold": "90",
    "disk_size_limit": "21474836480"
  },
```

Кластер создан, подключение через psql по SSL работает, запросы на запись и чтение выполняются.
