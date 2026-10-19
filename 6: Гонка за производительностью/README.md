# ДЗ №6. Гонка за производительностью

## 1. Развернуть инстанс PostgreSQL на виртуальной машине

ВМ: тот же VDS, что в ДЗ №4–5 (KVM, Ubuntu 24.04, 4 vCPU, 8 ГБ RAM, один виртуальный диск `/dev/vda1`), вместо Яндекс.Облака ([logs/01-host.log](logs/01-host.log)). PostgreSQL 16 установил прямо на ВМ из репозитория Ubuntu ([logs/02-install.log](logs/02-install.log)):

```bash
sudo apt-get install -y -q postgresql-16 postgresql-contrib
```

```
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory              Log file
16  main    5432 online postgres /var/lib/postgresql/16/main /var/log/postgresql/postgresql-16-main.log

$ sudo -u postgres psql -c 'select version()'
 PostgreSQL 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1) on x86_64-pc-linux-gnu, compiled by gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0, 64-bit
```

**Проблема:** на диске ВМ свободно всего 1,9 ГБ: остальное место занимают LXD-контейнеры из прошлых ДЗ.

**Решение:** взял масштаб pgbench 30 (БД 456 МБ) и оставил `max_wal_size = 1GB`, чтобы данные и WAL поместились на диск.

## 2. Протестировать производительность с помощью pgbench

Инициализация и прогон на настройках по умолчанию: TPC-B, 24 клиента, 4 потока, 60 секунд. Клиентов меньше, чем строк в `pgbench_branches` (30), поэтому они почти не ждут блокировок на одной строке ([logs/03-pgbench-baseline.log](logs/03-pgbench-baseline.log)):

```bash
sudo -u postgres createdb bench
sudo -u postgres pgbench -i -s 30 bench
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 60 bench
```

```
 pg_size_pretty
----------------
 456 MB

shared_buffers|16384|8kB
synchronous_commit|on|
fsync|on|
max_wal_size|1024|MB
checkpoint_timeout|300|s
...
progress: 10.0 s, 1075.0 tps, lat 21.617 ms stddev 54.535, 0 failed
progress: 20.0 s, 210.3 tps, lat 112.932 ms stddev 301.014, 0 failed
progress: 30.0 s, 323.5 tps, lat 76.232 ms stddev 136.771, 0 failed
progress: 40.0 s, 137.3 tps, lat 175.501 ms stddev 465.582, 0 failed
progress: 50.0 s, 230.9 tps, lat 103.981 ms stddev 209.887, 0 failed
progress: 60.0 s, 245.7 tps, lat 94.133 ms stddev 187.951, 0 failed
...
latency average = 64.693 ms
tps = 370.866417 (without initial connection time)
```

Узкое место — диск: база (456 МБ) не помещается в `shared_buffers` по умолчанию (128 МБ), поэтому грязные страницы постоянно вытесняются на диск. Кроме того, каждый коммит ждёт `fsync` WAL на медленном диске VDS. TPS после первых 10 секунд падает до 140–320, а задержка доходит до 100–175 мс.

## 3. Оптимизировать настройки PostgreSQL

Сначала задал только безопасные параметры, которые не влияют на надёжность. Их подбирал под ВМ с 4 vCPU и 8 ГБ RAM ([logs/04-tuning-safe.log](logs/04-tuning-safe.log)):

```sql
alter system set shared_buffers = '2GB';              -- 25% RAM, вся БД помещается в кэш
alter system set effective_cache_size = '6GB';        -- кэш ОС + shared_buffers, для планировщика
alter system set maintenance_work_mem = '512MB';
alter system set work_mem = '16MB';
alter system set wal_buffers = '64MB';
alter system set max_wal_size = '1GB';                -- больше не позволяет место на диске
alter system set min_wal_size = '512MB';
alter system set checkpoint_timeout = '15min';        -- реже чекпоинты
alter system set checkpoint_completion_target = 0.9;  -- запись чекпоинта размазана по времени
alter system set wal_compression = 'lz4';             -- меньше объём WAL на медленный диск
alter system set commit_delay = 1000;                 -- групповой коммит: один fsync на несколько транзакций
alter system set commit_siblings = 5;
alter system set random_page_cost = 1.1;
alter system set effective_io_concurrency = 200;
```

```bash
sudo systemctl restart postgresql@16-main
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 60 bench
```

```
progress: 10.0 s, 2526.7 tps, lat 9.418 ms stddev 20.377, 0 failed
progress: 20.0 s, 2467.8 tps, lat 9.726 ms stddev 20.612, 0 failed
progress: 30.0 s, 2900.6 tps, lat 8.274 ms stddev 15.203, 0 failed
progress: 40.0 s, 2511.8 tps, lat 9.549 ms stddev 25.887, 0 failed
progress: 50.0 s, 2923.1 tps, lat 8.206 ms stddev 16.125, 0 failed
progress: 60.0 s, 3008.8 tps, lat 7.967 ms stddev 15.201, 0 failed
...
latency average = 8.805 ms
tps = 2722.768190 (without initial connection time)
```

## 4. Проверить, насколько выросла производительность

После безопасного тюнинга TPS вырос с 371 до 2723 (в 7,3 раза), а средняя задержка упала с 64,7 до 8,8 мс.

**Проблема:** прирост в 7 раз выглядел подозрительно. В первом базовом прогоне TPS за первые 10 секунд был 1075, а потом резко упал. Возможно, базовый замер испортила запись на диск, оставшаяся после `pgbench -i`.

**Решение:** сохранил настроенный `postgresql.auto.conf`, сбросил параметры к значениям по умолчанию (`alter system reset all`) и повторил базовый замер дважды. Затем вернул настройки ([logs/05-baseline-recheck.log](logs/05-baseline-recheck.log)):

```bash
sudo cp /var/lib/postgresql/16/main/postgresql.auto.conf /var/lib/postgresql/16/tuned-safe.auto.conf
sudo -u postgres psql -c 'alter system reset all'
sudo systemctl restart postgresql@16-main
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 60 bench
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 60 bench
sudo cp /var/lib/postgresql/16/tuned-safe.auto.conf /var/lib/postgresql/16/main/postgresql.auto.conf
sudo systemctl restart postgresql@16-main
```

```
128MB
0
...
latency average = 60.166 ms
tps = 398.731640 (without initial connection time)
...
latency average = 90.281 ms
tps = 264.313115 (without initial connection time)
...
2GB
1000
```

На настройках по умолчанию снова получилось 264–399 TPS, то есть базовый замер верный, а прирост в ~7 раз настоящий.

## 5. Настроить кластер на оптимальную производительность, не обращая внимания на стабильность БД

Оставшееся узкое место — синхронная запись WAL на диск при каждом коммите. Поверх безопасных настроек отключил гарантии надёжности ([logs/06-tuning-unsafe.log](logs/06-tuning-unsafe.log)):

```sql
alter system set fsync = off;                   -- не ждать сброса данных и WAL на диск
alter system set synchronous_commit = off;      -- коммит не ждёт записи WAL
alter system set full_page_writes = off;        -- не писать полные страницы в WAL после чекпоинта
alter system set wal_level = 'minimal';         -- минимальный WAL, без репликации
alter system set max_wal_senders = 0;           -- нужно для wal_level = minimal
alter system set wal_writer_delay = '10s';      -- WAL writer сбрасывает WAL реже
alter system set wal_writer_flush_after = '64MB';
alter system set commit_delay = 0;              -- групповой коммит больше не нужен
alter system set bgwriter_lru_maxpages = 0;     -- отключить фоновую запись грязных страниц
alter system set autovacuum = off;              -- не тратить CPU и диск на автовакуум
```

```bash
sudo systemctl restart postgresql@16-main
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 60 bench
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 60 bench
```

```
fsync|off|
full_page_writes|off|
synchronous_commit|off|
wal_level|minimal|
...
progress: 10.0 s, 9066.9 tps, lat 2.638 ms stddev 1.051, 0 failed
progress: 20.0 s, 9301.8 tps, lat 2.578 ms stddev 0.982, 0 failed
progress: 30.0 s, 9670.0 tps, lat 2.480 ms stddev 0.949, 0 failed
progress: 40.0 s, 8934.5 tps, lat 2.684 ms stddev 1.258, 0 failed
progress: 50.0 s, 9150.3 tps, lat 2.621 ms stddev 1.055, 0 failed
progress: 60.0 s, 9290.4 tps, lat 2.581 ms stddev 1.041, 0 failed
...
latency average = 2.596 ms
tps = 9235.801976 (without initial connection time)
```

Два прогона дали 8866 и 9236 TPS: в 3,4 раза больше безопасного тюнинга и в 23–35 раз больше, чем на настройках по умолчанию (264–399 TPS). Средняя задержка снизилась до 2,6 мс и почти перестала скакать (stddev ~1 мс). Цена — при сбое ОС или ВМ база может потерять последние транзакции и повредиться.
