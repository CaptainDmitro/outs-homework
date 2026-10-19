# ДЗ №4. Высокая доступность: развертывание Patroni

## 1. 3 виртуальные машины для etcd и 3 для Patroni

Стенд: удалённый VDS с Ubuntu 24.04, 4 vCPU и 8 ГБ RAM. Сам VDS работает под KVM, а вложенной виртуализации нет: в `/proc/cpuinfo` нет флагов `vmx`/`svm`, `/dev/kvm` отсутствует ([logs/00-host.log](logs/00-host.log)). Поэтому вместо полноценных ВМ использовал системные контейнеры LXD. У каждого свой systemd, hostname, сеть и IP, то есть для кластера это отдельные «машины». Седьмой узел, `haproxy`, нужен для балансировщика.

Установка LXD ([logs/01-lxd-install.log](logs/01-lxd-install.log)):

```bash
sudo snap install lxd
sudo lxd init --auto
```

Создание узлов со статическими адресами в сети `lxdbr0` (10.48.221.0/24), лимиты 1 vCPU и 1 ГБ RAM ([logs/02-create-vms.log](logs/02-create-vms.log)):

```bash
for n in etcd1:11 etcd2:12 etcd3:13 pg1:21 pg2:22 pg3:23 haproxy:30; do
  name=${n%%:*}; ip=10.48.221.${n##*:}
  sudo lxc init ubuntu:24.04 $name -c limits.cpu=1 -c limits.memory=1GiB </dev/null
  sudo lxc config device override $name eth0 ipv4.address=$ip
  sudo lxc start $name
done
```

```
$ sudo lxc list -c ns4tM
+---------+---------+---------------------+-----------+---------------+
|  NAME   |  STATE  |        IPV4         |   TYPE    | MEMORY USAGE% |
+---------+---------+---------------------+-----------+---------------+
| etcd1   | RUNNING | 10.48.221.11 (eth0) | CONTAINER | 4.1%          |
| etcd2   | RUNNING | 10.48.221.12 (eth0) | CONTAINER | 4.1%          |
| etcd3   | RUNNING | 10.48.221.13 (eth0) | CONTAINER | 4.1%          |
| haproxy | RUNNING | 10.48.221.30 (eth0) | CONTAINER | 12.3%         |
| pg1     | RUNNING | 10.48.221.21 (eth0) | CONTAINER | 4.2%          |
| pg2     | RUNNING | 10.48.221.22 (eth0) | CONTAINER | 4.2%          |
| pg3     | RUNNING | 10.48.221.23 (eth0) | CONTAINER | 4.2%          |
+---------+---------+---------------------+-----------+---------------+
```

## 2. HA-кластер PostgreSQL на Patroni

### etcd

На `etcd1..3` установил `etcd-server` из репозитория Ubuntu (3.4.30) и прописал в `/etc/default/etcd` начальный состав кластера ([logs/03-etcd-failed.log](logs/03-etcd-failed.log)):

```
ETCD_NAME=etcd1
ETCD_DATA_DIR=/var/lib/etcd/default
ETCD_LISTEN_PEER_URLS=http://10.48.221.11:2380
ETCD_LISTEN_CLIENT_URLS=http://10.48.221.11:2379,http://127.0.0.1:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=http://10.48.221.11:2380
ETCD_ADVERTISE_CLIENT_URLS=http://10.48.221.11:2379
ETCD_INITIAL_CLUSTER=etcd1=http://10.48.221.11:2380,etcd2=http://10.48.221.12:2380,etcd3=http://10.48.221.13:2380
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=bananaflow-etcd
ETCD_ENABLE_V2=true
```

**Проблема:** скрипт, переданный по `ssh ... 'bash -s'`, оборвался сразу после `sudo lxc exec etcd1 -- cat /etc/default/etcd`: etcd не запустился, проверки не выполнились.

**Решение:** `lxc exec` по умолчанию пробрасывает stdin в контейнер, и `cat` прочитал оставшуюся часть скрипта как свой ввод. Добавил `</dev/null` ко всем `lxc exec` и повторил запуск отдельно. Пакетный `etcd` после установки остановлен, а старый `data-dir` удалён, чтобы узлы стартовали с новым `INITIAL_CLUSTER` ([logs/04-etcd-start.log](logs/04-etcd-start.log)):

```
$ etcdctl --endpoints=http://10.48.221.11:2379,http://10.48.221.12:2379,http://10.48.221.13:2379 member list -w table
+------------------+---------+-------+--------------------------+--------------------------+------------+
|        ID        | STATUS  | NAME  |        PEER ADDRS        |       CLIENT ADDRS       | IS LEARNER |
+------------------+---------+-------+--------------------------+--------------------------+------------+
|  89f0705da6de2fd | started | etcd3 | http://10.48.221.13:2380 | http://10.48.221.13:2379 |      false |
| 787e985b4b1141a4 | started | etcd1 | http://10.48.221.11:2380 | http://10.48.221.11:2379 |      false |
| 7eccf9e030dd604d | started | etcd2 | http://10.48.221.12:2380 | http://10.48.221.12:2379 |      false |
+------------------+---------+-------+--------------------------+--------------------------+------------+
$ etcdctl --endpoints=... endpoint health
http://10.48.221.11:2379 is healthy: successfully committed proposal: took = 4.616569ms
http://10.48.221.13:2379 is healthy: successfully committed proposal: took = 5.800743ms
http://10.48.221.12:2379 is healthy: successfully committed proposal: took = 5.153154ms
```

### Patroni

На `pg1..3` установил `postgresql-16` и `patroni` (3.2.2) из репозитория Ubuntu. Затем удалил пакетный кластер `16/main` и отключил `postgresql.service`, потому что запускать PostgreSQL должен Patroni ([logs/05-patroni-install.log](logs/05-patroni-install.log)):

```bash
apt-get install -y postgresql-16 patroni && pg_dropcluster 16 main --stop && systemctl disable --now postgresql
```

`/etc/patroni/config.yml` (на `pg2`/`pg3` отличаются только `name` и адреса) ([logs/06-patroni-config.log](logs/06-patroni-config.log)):

```yaml
scope: bananaflow
namespace: /service/
name: pg1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.48.221.21:8008

etcd3:
  hosts: 10.48.221.11:2379,10.48.221.12:2379,10.48.221.13:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: on
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: on
        shared_buffers: 128MB
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host replication replicator 10.48.221.0/24 scram-sha-256
    - host all all 10.48.221.0/24 scram-sha-256
    - host all all 127.0.0.1/32 scram-sha-256

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.48.221.21:5432
  data_dir: /var/lib/postgresql/16/patroni
  bin_dir: /usr/lib/postgresql/16/bin
  pgpass: /var/lib/postgresql/.pgpass_patroni
  authentication:
    superuser:
      username: postgres
      password: otus_pass
    replication:
      username: replicator
      password: repl_pass
    rewind:
      username: rewind_user
      password: rewind_pass
...
```

Синхронизацию данных между узлами обеспечивают:
- `synchronous_mode: true`. Patroni держит одну реплику синхронной (`synchronous_standby_names`), и коммит на лидере подтверждается только после записи WAL на неё. При failover лидером может стать только синхронная реплика, поэтому подтверждённые транзакции не теряются.
- `use_slots: true`. Слоты репликации не дают лидеру удалить WAL, который ещё нужен репликам.
- `use_pg_rewind: true` и `wal_log_hints: on`. Бывший лидер после возврата перематывается `pg_rewind` и становится репликой без полного переклонирования.

Сначала запустил `pg1`: он выполнил `initdb` и захватил лидерский ключ в etcd. Затем `pg2` и `pg3`: они склонировались с лидера через `pg_basebackup`. Проверка ([logs/07-patroni-sync.log](logs/07-patroni-sync.log)):

```
$ patronictl -c /etc/patroni/config.yml list
+ Cluster: bananaflow (7698472439337094871) -------+----+-----------+
| Member | Host         | Role         | State     | TL | Lag in MB |
+--------+--------------+--------------+-----------+----+-----------+
| pg1    | 10.48.221.21 | Leader       | running   |  1 |           |
| pg2    | 10.48.221.22 | Sync Standby | streaming |  1 |         0 |
| pg3    | 10.48.221.23 | Replica      | streaming |  1 |         0 |
+--------+--------------+--------------+-----------+----+-----------+

$ psql -h 10.48.221.21 -U postgres -c "select application_name, client_addr, state, sync_state from pg_stat_replication" -c "show synchronous_standby_names"
 application_name | client_addr  |   state   | sync_state
------------------+--------------+-----------+------------
 pg2              | 10.48.221.22 | streaming | sync
 pg3              | 10.48.221.23 | streaming | async

 synchronous_standby_names
---------------------------
 pg2
```

**Проблема:** в журнале `pg1` во время подключения реплик были ошибки `Failed to create physical replication slot 'pg2'` (и `'pg3'`).

**Решение:** причина была в `canceling statement due to statement timeout` ([logs/11-slot-error.log](logs/11-slot-error.log)). Сразу после bootstrap запрос на создание слота не уложился в `statement_timeout` служебного соединения Patroni. Patroni повторил создание слота на следующем цикле, и реплики подключились по слотам (`START_REPLICATION SLOT "pg2"`). Ничего менять не потребовалось: сейчас слоты активны.

## 3. HAProxy для балансировки нагрузки

На узле `haproxy` установил `haproxy` (2.8) и `postgresql-client`. Узел, на который направлять трафик, HAProxy выбирает по REST API Patroni (порт 8008): `/primary` отвечает 200 только на лидере, `/replica` только на работающей реплике ([logs/08-haproxy.log](logs/08-haproxy.log)):

```
listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /

listen primary
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg1 10.48.221.21:5432 maxconn 100 check port 8008
    server pg2 10.48.221.22:5432 maxconn 100 check port 8008
    server pg3 10.48.221.23:5432 maxconn 100 check port 8008

listen replicas
    bind *:5001
    balance roundrobin
    option httpchk GET /replica
    ...
```

Порт 5000 принимает запись и всегда ведёт на лидера. Порт 5001 принимает чтение и распределяет запросы round-robin по репликам:

```
$ echo 'show stat' | socat - /run/haproxy/admin.sock 2>/dev/null | cut -d, -f1,2,18 | grep -v '^#'; curl -s 'http://127.0.0.1:7000/;csv' | cut -d, -f1,2,18 | grep pg
primary,pg1,UP
primary,pg2,DOWN
primary,pg3,DOWN
replicas,pg1,DOWN
replicas,pg2,UP
replicas,pg3,UP

$ psql -h 127.0.0.1 -p 5000 -U postgres -Atc "select 5000 as port, inet_server_addr(), pg_is_in_recovery()"
5000|10.48.221.21|f
$ psql -h 127.0.0.1 -p 5001 ...   # 4 раза
5001|10.48.221.22|t
5001|10.48.221.23|t
5001|10.48.221.22|t
5001|10.48.221.23|t
```

## 4. Проверка отказоустойчивости: сбой одного узла

Через HAProxy создал таблицу заказов и запустил на узле `haproxy` «писателя»: 90 вставок по одной в секунду через порт 5000. Через 10 секунд жёстко остановил узел-лидер `pg1` командой `lxc stop --force`, что аналогично выключению питания ([logs/09-failover.log](logs/09-failover.log)):

```bash
psql -h 127.0.0.1 -p 5000 -U postgres -c "create table orders(id serial primary key, supplier text, tons int, created_at timestamptz default now())" -c "insert into orders(supplier, tons) values ('GreenBanana Co.', 10)"
...
sudo lxc stop pg1 --force      # 20:07:39
```

Журнал «писателя»:

```
20:07:38 6 7|10.48.221.21
20:07:39 7 8|10.48.221.21
20:07:53 8 psql: error: connection to server at "127.0.0.1", port 5000 failed: server closed the connection unexpectedly
20:08:06 9 psql: error: ...
...
20:08:12 15 psql: error: ...
20:08:13 16 34|10.48.221.22
20:08:14 17 35|10.48.221.22
```

Состояние после сбоя:

```
$ patronictl -c /etc/patroni/config.yml list
+ Cluster: bananaflow (7698472439337094871) -------+----+-----------+
| Member | Host         | Role         | State     | TL | Lag in MB |
+--------+--------------+--------------+-----------+----+-----------+
| pg2    | 10.48.221.22 | Leader       | running   |  2 |           |
| pg3    | 10.48.221.23 | Sync Standby | streaming |  2 |         0 |
+--------+--------------+--------------+-----------+----+-----------+

$ curl -s 'http://127.0.0.1:7000/;csv' | cut -d, -f1,2,18 | grep pg
primary,pg1,DOWN
primary,pg2,UP
primary,pg3,DOWN
replicas,pg1,DOWN
replicas,pg2,DOWN
replicas,pg3,UP

$ psql -h 127.0.0.1 -p 5000 -U postgres -c "select inet_server_addr(), count(*), max(id) from orders" -c "select * from orders where supplier='GreenBanana Co.'"
 inet_server_addr | count | max
------------------+-------+-----
 10.48.221.22     |    83 | 108

 id |    supplier     | tons |          created_at
----+-----------------+------+-------------------------------
  1 | GreenBanana Co. |   10 | 2026-10-19 20:07:29.219388+00
```

Итоги проверки:
- Ключ лидера в etcd истёк через `ttl: 30`, синхронная реплика `pg2` стала лидером (таймлайн 2), а `pg3` стала новой синхронной репликой. Запись была недоступна около 34 секунд (20:07:39 → 20:08:13). Приложение продолжило работать через тот же адрес HAProxy без перенастройки.
- Данные не потеряны: 83 строки = 1 исходная + 7 до сбоя + 75 после переключения. Пропуск `id` с 8 на 34 нормален: последовательность записывает в WAL значения на 32 вперёд, и новый лидер продолжил с предзаписанного значения.

Возврат узла: запустил `pg1` снова ([logs/10-node-return.log](logs/10-node-return.log), [logs/11-slot-error.log](logs/11-slot-error.log)). Patroni увидел, что лидер теперь `pg2`, перемотал данные через `pg_rewind` и подключил `pg1` репликой:

```
INFO: running pg_rewind from pg2
INFO:  stderr=pg_rewind: servers diverged at WAL location 0/407A140 on timeline 1
pg_rewind: rewinding from last common checkpoint at 0/2000148 on timeline 1
pg_rewind: Done!
INFO: starting as a secondary

$ patronictl -c /etc/patroni/config.yml list
| pg1    | 10.48.221.21 | Replica      | streaming |  2 |         0 |
| pg2    | 10.48.221.22 | Leader       | running   |  2 |           |
| pg3    | 10.48.221.23 | Sync Standby | streaming |  2 |         0 |

$ psql -h 127.0.0.1 -U postgres -Atc "select pg_is_in_recovery(), count(*) from orders"   # на pg1
t|83
```

## 5. Дополнительно: бэкапы с WAL-G

WAL-G v3.0.9: официальный релиз `wal-g-pg-24.04-amd64` с GitHub, контрольная сумма sha256 совпала. Хранилище: каталог хоста `/srv/walg`, примонтированный во все три узла как `/backup`. Так WAL и бэкапы доступны любому узлу, который станет лидером ([logs/12-walg-install.log](logs/12-walg-install.log)):

```bash
sudo lxc file push /tmp/wal-g-pg-24.04-amd64 pg$i/usr/local/bin/wal-g --mode 0755
sudo lxc config device add pg$i walg disk source=/srv/walg path=/backup shift=true
```

`/var/lib/postgresql/.walg.json`:

```json
{
  "WALG_FILE_PREFIX": "/backup/bananaflow",
  "WALG_COMPRESSION_METHOD": "brotli",
  "WALG_DELTA_MAX_STEPS": "6",
  "PGHOST": "/var/run/postgresql",
  "PGUSER": "postgres"
}
```

Архивацию WAL включил через динамическую конфигурацию Patroni в DCS, чтобы она применилась на всех узлах и пережила смену лидера. Затем сделал `patronictl restart`, так как `archive_mode` требует перезапуска ([logs/13-walg-archive-failed.log](logs/13-walg-archive-failed.log)):

```yaml
# patronictl -c /etc/patroni/config.yml edit-config --apply /tmp/walg-patch.yml --force
postgresql:
  parameters:
    archive_mode: "on"
    archive_command: "wal-g wal-push %p"
    archive_timeout: 60
  recovery_conf:
    restore_command: "wal-g wal-fetch %f %p"
  pg_hba:
    - local all postgres peer
    - host replication replicator 10.48.221.0/24 scram-sha-256
    - host all all 10.48.221.0/24 scram-sha-256
    - host all all 127.0.0.1/32 scram-sha-256
```

Строку `local all postgres peer` пришлось указать явно. Когда `pg_hba` задан в DCS, Patroni полностью перезаписывает `pg_hba.conf`, и без неё `wal-g backup-push` не подключится через unix-сокет.

**Проблема:** после рестарта архивация не работала:

```
 archived_count | last_archived_wal | failed_count
----------------+-------------------+--------------
              0 |                   |            3
```

**Решение:** в журнале Patroni ([logs/14-walg-archive-debug.log](logs/14-walg-archive-debug.log)) WAL-G сообщал:

```
ERROR: ... create FS storage: FS storage root directory doesn't exist or is inaccessible: stat /backup/bananaflow: no such file or directory
```

Файловое хранилище WAL-G не создаёт корневой каталог само. Создал его от `postgres` (каталог общий, поэтому достаточно одного раза), и архивация пошла. Сегмент `...05`, на котором были ошибки, заархивировался при повторной попытке ([logs/15-walg-archive-fix.log](logs/15-walg-archive-fix.log)):

```
$ su postgres -c 'mkdir -p /backup/bananaflow'
$ psql -c 'select archived_count, last_archived_wal, last_failed_wal, failed_count from pg_stat_archiver'
 archived_count |    last_archived_wal     |     last_failed_wal      | failed_count
----------------+--------------------------+--------------------------+--------------
              2 | 000000020000000000000006 | 000000020000000000000005 |            3
$ ls /backup/bananaflow/wal_005/
000000020000000000000005.br
000000020000000000000006.br
```

Полный бэкап по расписанию: на всех трёх узлах в crontab пользователя `postgres` задача на 02:00. Скрипт делает бэкап, только если узел сейчас лидер (`/primary` в REST API Patroni), и хранит 7 последних полных бэкапов ([logs/16-walg-backup.log](logs/16-walg-backup.log)):

```bash
#!/bin/bash
# backup is taken only on the current Patroni leader
curl -sf -o /dev/null http://127.0.0.1:8008/primary || exit 0
wal-g backup-push /var/lib/postgresql/16/patroni && wal-g delete retain FULL 7 --confirm
```

```
$ crontab -u postgres -l
0 2 * * * /usr/local/bin/walg-backup.sh >> /var/lib/postgresql/walg-backup.log 2>&1
$ su postgres -c /usr/local/bin/walg-backup.sh; echo "pg1 (replica) exit=$?"      # на pg1 (реплика): скрипт сразу выходит
pg1 (replica) exit=0
$ su postgres -c /usr/local/bin/walg-backup.sh      # на pg2 (лидер)
INFO: ... Couldn't find previous backup. Doing full backup.
...
INFO: ... Wrote backup with name base_000000020000000000000008 to storage default
$ wal-g backup-list --detail
backup_name                   modified             wal_file_name            storage_name start_time           finish_time          hostname data_dir                       pg_version start_lsn finish_lsn is_permanent
base_000000020000000000000008 2026-10-19T20:14:03Z 000000020000000000000008 default      2026-10-19T20:13:42Z 2026-10-19T20:13:59Z pg2      /var/lib/postgresql/16/patroni 160015     0/8000060 0/8000138  false
```

Проверка восстановления ([logs/17-walg-restore.log](logs/17-walg-restore.log)). После бэкапа вставил ещё 1000 строк, затем на `pg3` развернул последний бэкап в отдельный каталог и поднял временный экземпляр на порту 5433. Он догнал состояние, проиграв WAL из архива:

```bash
psql -h 127.0.0.1 -p 5000 -U postgres -c "insert into orders(supplier,tons) select 'after-backup', g from generate_series(1,1000) g" -c "select count(*) from orders" -c "select pg_switch_wal()"
wal-g backup-fetch /var/lib/postgresql/restore LATEST && touch /var/lib/postgresql/restore/recovery.signal
pg_ctl -D /var/lib/postgresql/restore -l /tmp/restore.log -w start -o "-p 5433 -c shared_buffers=32MB -c archive_mode=off -c synchronous_standby_names='' -c primary_conninfo='' -c primary_slot_name='' -c restore_command='wal-g wal-fetch %f %p'"
```

```
 count
-------
  1083

LOG:  restored log file "000000020000000000000008" from archive
LOG:  restored log file "000000020000000000000009" from archive
LOG:  redo done at 0/9030A88 ...
LOG:  selected new timeline ID: 3

$ psql -p 5433 -c 'select supplier, count(*) from orders group by supplier order by 1'
    supplier     | count
-----------------+-------
 GreenBanana Co. |     1
 after-backup    |  1000
 writer          |    82
```

В восстановленной копии все 1083 строки, включая 1000 вставленных уже после бэкапа: они пришли из архива WAL. Временный экземпляр остановлен и удалён, кластер Patroni при этом продолжал работать в штатном режиме (`pg2` лидер, `pg3` синхронная реплика, `pg1` реплика).
