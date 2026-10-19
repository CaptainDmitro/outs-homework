# ДЗ №5. Бэкапы

## 1. Настройка бэкапов PostgreSQL для базы «Лояльность оптовиков»

Стенд: тот же VDS, что в ДЗ №4 (Ubuntu 24.04, 4 vCPU, 8 ГБ RAM). Кластер Patroni из ДЗ №4 не трогал (только очистил в его контейнерах кэш apt, см. ниже). Для этого ДЗ создал три отдельных LXD-контейнера ([logs/01-nodes.log](logs/01-nodes.log)): `bk-primary` (10.48.221.41) — основной кластер с БД, `bk-replica` (.42) — потоковая реплика для бэкапа под нагрузкой, `bk-restore` (.43) — другой кластер для восстановления.

Инструмент: **pg_probackup** (WAL-G уже использовался в ДЗ №4). На все узлы установил PostgreSQL 16 из репозитория Ubuntu и `pg-probackup-16` из репозитория Postgres Pro. Каталог бэкапов — каталог хоста `/srv/probackup`, примонтированный во все три узла как `/backup` ([logs/02-install-failed.log](logs/02-install-failed.log)):

```bash
curl -fsSL https://repo.postgrespro.ru/pg_probackup/keys/GPG-KEY-PG-PROBACKUP | gpg --dearmor -o /usr/share/keyrings/pg_probackup.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/pg_probackup.gpg] https://repo.postgrespro.ru/pg_probackup/deb noble main-noble" > /etc/apt/sources.list.d/pg_probackup.list
apt-get install -y postgresql-16 pg-probackup-16
sudo lxc config device add $n probackup disk source=/srv/probackup path=/backup shift=true
```

```
pg_probackup-16 2.5.16 (PostgreSQL 16.11)
psql (PostgreSQL) 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
```

**Проблема:** на третьем узле установка упала с `No space left on device`, на хосте `/` заполнился на 100%.

**Решение:** пул LXD использует драйвер `dir`, поэтому каждый контейнер хранит полную копию ФС (~1.5 ГБ). Из них ~350 МБ занимали кэш и списки пакетов apt. Очистил их во всех контейнерах и на хосте (это только кэш), освободилось 3.5 ГБ. Затем доустановил пакеты на `bk-restore` ([logs/03-disk-cleanup.log](logs/03-disk-cleanup.log)):

```
$ for c in $(sudo lxc list -c n -f csv); do sudo lxc exec $c -- bash -c 'apt-get clean; rm -rf /var/lib/apt/lists/*'; done
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda1        19G   15G  3.5G  81% /
```

Настройка `bk-primary` ([logs/04-primary.log](logs/04-primary.log)):

1. Включил контрольные суммы страниц (`pg_checksums --enable` на остановленном кластере). С ними pg_probackup проверяет каждую страницу при бэкапе и валидации и обнаруживает повреждения данных.
2. Инициализировал каталог и зарегистрировал инстанс `loyalty`. Задал политику хранения (7 бэкапов и не меньше 7 дней) и сжатие zlib уровня 1: оно экономит место и почти не нагружает CPU.
3. Включил архивацию WAL через `pg_probackup archive-push`. Вместе с полными бэкапами она даёт восстановление на любой момент времени (PITR). Параметры записал в `/etc/postgresql/16/main/conf.d/`, а не через `ALTER SYSTEM`: иначе `archive_command` попал бы в `postgresql.auto.conf` внутри бэкапа, и восстановленный кластер начал бы писать свой WAL в тот же архив.

```bash
pg_probackup-16 init -B /backup
pg_probackup-16 add-instance -B /backup -D /var/lib/postgresql/16/main --instance loyalty
pg_probackup-16 set-config -B /backup --instance loyalty --retention-redundancy=7 --retention-window=7 --compress-algorithm=zlib --compress-level=1 -d postgres
```

`/etc/postgresql/16/main/conf.d/backup.conf`:

```
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
archive_mode = on
archive_command = 'pg_probackup-16 archive-push -B /backup --instance loyalty --wal-file-path=%p --wal-file-name=%f --compress'
archive_timeout = 60
```

База «Лояльность оптовиков» (`wholesale_loyalty`): оптовики, бонусные счета и операции начисления/списания:

```sql
create database wholesale_loyalty;
comment on database wholesale_loyalty is 'Лояльность оптовиков';
create table wholesalers(id serial primary key, name text not null, inn char(10) not null unique,
  tier text not null check (tier in ('bronze','silver','gold','platinum')), created_at timestamptz not null default now());
create table bonus_accounts(wholesaler_id int primary key references wholesalers, balance numeric(12,2) not null default 0);
create table bonus_operations(id bigserial primary key, wholesaler_id int not null references wholesalers,
  amount numeric(12,2) not null, op_type text not null check (op_type in ('accrual','redeem')), created_at timestamptz not null default now());
-- 10 000 оптовиков, 500 000 операций, балансы = сумма операций
...
```

```
 data_checksums
----------------
 on

 wholesalers | accounts | operations | db_size
-------------+----------+------------+---------
       10000 |    10000 |     500000 | 56 MB
```

Бэкапы ([logs/05-backup.log](logs/05-backup.log)). Сначала проверил, что архивация работает. Затем снял полный бэкап, добавил 20 000 операций и снял инкрементальный DELTA (в бэкап попадают только изменённые страницы):

```
$ psql -Atc 'select pg_switch_wal()' -c 'select pg_sleep(2)' -c 'select archived_count, last_archived_wal, failed_count from pg_stat_archiver'
7|000000010000000000000007|0

$ pg_probackup-16 backup -B /backup --instance loyalty -b FULL -j 2 --compress
INFO: Backup start, pg_probackup version: 2.5.16, instance: loyalty, backup ID: TN6A22, backup mode: FULL, wal mode: ARCHIVE, ...
INFO: This PostgreSQL instance was initialized with data block checksums. Data block corruption will be detected
...
INFO: Backup TN6A22 completed

$ pg_probackup-16 backup -B /backup --instance loyalty -b DELTA -j 2 --compress
...
INFO: Parent backup: TN6A22
...
INFO: Backup TN6A2I completed

$ pg_probackup-16 validate -B /backup --instance loyalty
INFO: Validating backup TN6A2I
INFO: Backup TN6A2I data files are valid
INFO: Backup TN6A2I WAL segments are valid
INFO: Validating backup TN6A22
INFO: Backup TN6A22 data files are valid
INFO: Backup TN6A22 WAL segments are valid
INFO: All backups are valid

$ pg_probackup-16 show -B /backup --instance loyalty
 Instance  Version  ID      Recovery Time           Mode   WAL Mode  TLI  Time    Data   WAL  Zratio  Start LSN  Stop LSN   Status
 loyalty   16       TN6A2I  2026-10-19 20:54:23+00  DELTA  ARCHIVE   1/1    7s  2628kB  16MB    2.60  0/B000060  0/C0000B8  OK
 loyalty   16       TN6A22  2026-10-19 20:54:13+00  FULL   ARCHIVE   1/0   15s    24MB  16MB    3.26  0/8000028  0/90000B8  OK

$ pg_probackup-16 show -B /backup --instance loyalty --archive
 TLI  Parent TLI  Switchpoint  Min Segno                 Max Segno                 N segments  Size  Zratio  N backups  Status
 1    0           0/0          000000010000000000000001  00000001000000000000000C  12          33MB  5.82    2          OK
```

Полный бэкап сжался до 24 МБ при PGDATA 79 МБ, а DELTA занял всего 2.6 МБ.

Расписание: `/etc/cron.d/pg_probackup`. Полный бэкап по воскресеньям, DELTA в остальные дни в 02:00. Устаревшие бэкапы и WAL удаляются по политике хранения:

```
0 2 * * 0   postgres pg_probackup-16 backup -B /backup --instance loyalty -b FULL  -j 2 --compress --delete-expired --delete-wal >> /var/log/postgresql/pg_probackup-cron.log 2>&1
0 2 * * 1-6 postgres pg_probackup-16 backup -B /backup --instance loyalty -b DELTA -j 2 --compress --delete-expired --delete-wal >> /var/log/postgresql/pg_probackup-cron.log 2>&1
```

## 2. Восстановление данных на другом кластере

Чтобы проверить, что восстанавливается не только сам бэкап, но и WAL из архива, уже **после** DELTA-бэкапа добавил на primary контрольного оптовика и переключил WAL. Затем зафиксировал эталон: число строк и md5 содержимого каждой таблицы ([logs/06-restore.log](logs/06-restore.log)):

```
$ psql -d wholesale_loyalty -c "insert into wholesalers(name, inn, tier) values ('ООО Банановый опт (после бэкапа)', '9999999999', 'platinum')" -c 'select pg_switch_wal()'
INSERT 0 1

$ psql -d wholesale_loyalty -c "select 'wholesalers' tbl, count(*), md5(string_agg(t::text, ',' order by id)) from wholesalers t union all ..."   # на bk-primary
       tbl        | count  |               md5
------------------+--------+----------------------------------
 wholesalers      |  10001 | 5a6ebd251ea368cf48cb79635821e970
 bonus_accounts   |  10000 | da1b77b52b7575cdeb9c5a946c72c028
 bonus_operations | 520000 | d0b7f1e82661b995f18a998e349d9f2e
```

На `bk-restore` остановил его собственный кластер, удалил каталог данных и восстановил последний бэкап. pg_probackup сам проверил цепочку FULL → DELTA, собрал из неё PGDATA и прописал `restore_command`, чтобы при старте догнать WAL из архива:

```
$ pg_ctlcluster 16 main stop
$ rm -rf /var/lib/postgresql/16/main
$ pg_probackup-16 restore -B /backup --instance loyalty -D /var/lib/postgresql/16/main -j 2
INFO: Validating parents for backup TN6A2I
INFO: Validating backup TN6A22
INFO: Backup TN6A22 data files are valid
INFO: Validating backup TN6A2I
INFO: Backup TN6A2I data files are valid
INFO: Backup TN6A2I WAL segments are valid
INFO: Backup TN6A2I is valid.
INFO: Restoring the database from backup TN6A2I
...
INFO: Restore of backup TN6A2I completed.

$ cat /var/lib/postgresql/16/main/postgresql.auto.conf
# recovery settings added by pg_probackup restore of backup TN6A2I at '2026-10-19 20:54:52+00'
recovery_target_timeline = 'current'
recovery_target_action = 'pause'
restore_command = '"/usr/bin/pg_probackup-16" archive-get -B "/backup" --instance "loyalty" --wal-file-path=%p --wal-file-name=%f'

$ pg_ctlcluster 16 main start
LOG:  redo done at 0/F3DECC8 ...
LOG:  last completed transaction was at log time 2026-10-19 20:54:47.028075+00
LOG:  restored log file "00000001000000000000000F" from archive
ERROR: pg_probackup archive-get failed to deliver WAL file: 00000002.history, time elapsed: 0ms
LOG:  selected new timeline ID: 2
LOG:  archive recovery complete
```

Сообщения `failed to deliver ... .history` — штатная часть восстановления: PostgreSQL проверяет, нет ли в архиве более новых таймлайнов, и, не найдя их, переходит на таймлайн 2. Последняя восстановленная транзакция (20:54:47) — это вставка контрольного оптовика, сделанная после бэкапа.

## 3. Проверка корректности восстановленных данных

На `bk-restore` выполнил те же запросы и сравнил результат с эталоном primary через `diff` ([logs/07-verify.log](logs/07-verify.log)):

```
 pg_is_in_recovery
-------------------
 f

  shobj_description
----------------------
 Лояльность оптовиков

  id   |               name               |    inn     |   tier   |          created_at
-------+----------------------------------+------------+----------+-------------------------------
 10001 | ООО Банановый опт (после бэкапа) | 9999999999 | platinum | 2026-10-19 20:54:47.026796+00

       tbl        | count  |               md5
------------------+--------+----------------------------------
 wholesalers      |  10001 | 5a6ebd251ea368cf48cb79635821e970
 bonus_accounts   |  10000 | da1b77b52b7575cdeb9c5a946c72c028
 bonus_operations | 520000 | d0b7f1e82661b995f18a998e349d9f2e

$ diff /tmp/primary.txt /tmp/restore.txt && echo "DATA IDENTICAL"
DATA IDENTICAL
```

Число строк и md5 содержимого всех трёх таблиц совпадают с primary. Контрольная запись, сделанная после последнего бэкапа, на месте. Кроме того, проверил физическую целостность таблиц и индексов через `pg_amcheck`.

**Проблема:** первый запуск `pg_amcheck` ничего не проверил:

```
pg_amcheck: warning: skipping database "wholesale_loyalty": amcheck is not installed
pg_amcheck: error: no relations to check
```

**Решение:** `pg_amcheck` работает через расширение `amcheck`, а в восстановленной базе его нет. Повторил запуск с `--install-missing`:

```
$ /usr/lib/postgresql/16/bin/pg_amcheck -d wholesale_loyalty --install-missing --heapallindexed && echo AMCHECK_OK
AMCHECK_OK
```

## 4. Дополнительно: бэкап под нагрузкой с реплики

Реплику `bk-replica` склонировал с primary через `pg_basebackup` со слотом репликации ([logs/08-replica.log](logs/08-replica.log)):

```
$ pg_basebackup -h 10.48.221.41 -U replicator -D /var/lib/postgresql/16/main -R -X stream -C -S bk_replica -P
$ psql -xc 'select pg_is_in_recovery(), status, sender_host, slot_name from pg_stat_wal_receiver'
pg_is_in_recovery | t
status            | streaming
sender_host       | 10.48.221.41
slot_name         | bk_replica
```

Нагрузка: pgbench на primary, 8 клиентов, 120 с. Каждая транзакция — начисление бонуса: вставка операции и увеличение баланса в одной транзакции. Перед этим пересчитал балансы, чтобы для каждого счёта выполнялось `balance = сумма операций`. По этому инварианту потом проверю согласованность бэкапа:

```
\set wid random(1, 10000)
\set amt random(1, 500)
BEGIN;
INSERT INTO bonus_operations(wholesaler_id, amount, op_type) VALUES (:wid, :amt, 'accrual');
UPDATE bonus_accounts SET balance = balance + :amt WHERE wholesaler_id = :wid;
END;
```

**Проблема:** лог первого прогона ([logs/09-replica-backup-under-load-failed.log](logs/09-replica-backup-under-load-failed.log)) вырос до 30 МБ и 700 тыс. строк вида `pgbench: client 4 sending BEGIN;`.

**Решение:** запускал pgbench как `pgbench -d wholesale_loyalty ...` по аналогии с psql. Но в pgbench `-d` означает `--debug`, а имя базы передаётся позиционным аргументом. Нагрузка при этом отработала (48 590 транзакций, 0 ошибок), но вывод был отладочным. Повторил прогон с `pgbench ... wholesale_loyalty`. В сохранённом логе первой попытки отладочный вывод вырезан.

Через 40 секунд после старта нагрузки снял на реплике полный бэкап. На standby pg_probackup снимает бэкап в режиме `--stream`: нужный WAL он забирает по протоколу репликации с самой реплики, и в бэкапе не участвуют ни архив, ни primary ([logs/10-replica-backup-under-load.log](logs/10-replica-backup-under-load.log)):

```
$ pg_probackup-16 backup -B /backup --instance loyalty -D /var/lib/postgresql/16/main -b FULL --stream -j 2 --compress   # на bk-replica, 21:05:17
INFO: Backup start, pg_probackup version: 2.5.16, instance: loyalty, backup ID: TN6AKT, backup mode: FULL, wal mode: STREAM, ...
INFO: Backup TN6AKT is going to be taken from standby
...
INFO: Backup files are synced, time elapsed: 10s
INFO: Validating backup TN6AKT
INFO: Backup TN6AKT data files are valid
INFO: Backup TN6AKT completed
21:05:39

$ cat /tmp/pgbench.log     # на bk-primary
progress: 30.0 s, 462.5 tps, lat 16.772 ms stddev 34.937, 0 failed
progress: 40.0 s, 453.2 tps, lat 18.190 ms stddev 47.024, 0 failed
progress: 50.0 s, 71.0 tps, lat 112.612 ms stddev 778.852, 0 failed
progress: 60.0 s, 228.9 tps, lat 34.787 ms stddev 70.097, 0 failed
progress: 70.0 s, 226.5 tps, lat 35.472 ms stddev 150.759, 0 failed
progress: 80.0 s, 463.5 tps, lat 17.272 ms stddev 34.117, 0 failed
...
number of transactions actually processed: 44773
number of failed transactions: 0 (0.000%)
tps = 373.002746 (without initial connection time)
```

Бэкап снят за 22 секунды, ни одна транзакция на primary не упала, отставание реплики после бэкапа — 0.6 с.

**Проблема:** во время бэкапа TPS на primary проседал с ~460 до 71–230, хотя бэкап снимался с реплики.

**Решение:** причина в стенде: данные primary, реплики и каталог бэкапов лежат на одном диске VDS `/dev/vda1`. Планировщик ввода-вывода там `none`, поэтому `ionice` не поможет ([logs/11-disk-contention.log](logs/11-disk-contention.log)):

```
$ cat /sys/block/vda/queue/scheduler
[none] mq-deadline
$ sudo lxc exec bk-primary -- df -h /var/lib/postgresql
/dev/vda1        19G   16G  2.8G  85% /
$ sudo lxc exec bk-replica -- df -h /var/lib/postgresql /backup
/dev/vda1        19G   16G  2.8G  85% /
/dev/vda1        19G   16G  2.8G  85% /backup
```

Запись бэкапа и последующий `fsync` каталога конкурируют за этот диск с `fsync` коммитов на primary. Попробовал уменьшить объём записи: инкрементальный DELTA вместо FULL, один поток и `--no-sync` ([logs/12-replica-delta-under-load.log](logs/12-replica-delta-under-load.log)). Изменённых страниц оказалось всего 2.8 МБ, но бэкап всё равно записал 128 МБ WAL: реплика стримит его от последнего restartpoint. Поэтому просадка осталась (41–243 tps). На этом стенде её не убрать. В рабочей схеме реплика и хранилище бэкапов стоят на отдельных серверах, и primary нагрузку от бэкапа не видит: на нём не выполняются ни `pg_backup_start`, ни чтение файлов.

Проверка бэкапа, снятого с реплики под нагрузкой ([logs/13-replica-backup-restore.log](logs/13-replica-backup-restore.log)). Развернул DELTA `TN6APX` (цепочка FULL `TN6AKT` → DELTA) на `bk-restore` вторым кластером на порту 5433. Восстанавливал только до точки согласованности бэкапа (`--recovery-target=immediate`), без WAL из архива, чтобы проверить именно сам бэкап:

```
$ pg_createcluster 16 from_replica -p 5433
$ rm -rf /var/lib/postgresql/16/from_replica
$ pg_probackup-16 restore -B /backup --instance loyalty -i TN6APX -D /var/lib/postgresql/16/from_replica -j 2 --recovery-target=immediate --recovery-target-action=promote
INFO: Validating parents for backup TN6APX
...
INFO: Backup TN6APX is valid.
INFO: Restore of backup TN6APX completed.
$ pg_ctlcluster 16 from_replica start
LOG:  consistent recovery state reached at 0/19716F48
LOG:  recovery stopping after reaching consistency
LOG:  selected new timeline ID: 2
LOG:  database system is ready to accept connections

 operations |        last_operation
------------+-------------------------------
     631514 | 2026-10-19 21:08:33.799444+00

 broken_accounts
-----------------
               0

$ /usr/lib/postgresql/16/bin/pg_amcheck -p 5433 -d wholesale_loyalty --install-missing --heapallindexed && echo AMCHECK_OK
AMCHECK_OK
```

Бэкап с реплики под нагрузкой восстановился в согласованном состоянии: последняя операция совпадает с `Recovery Time` бэкапа (21:08:33), ни одного счёта с рассогласованным балансом нет, `amcheck` ошибок не нашёл.
