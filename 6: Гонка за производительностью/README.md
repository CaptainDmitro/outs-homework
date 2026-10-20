# ДЗ №6. Гонка за производительностью

## 1. Развернуть инстанс PostgreSQL на виртуальной машине

ВМ: тот же VDS, что в ДЗ №4–5 (KVM, Ubuntu 24.04, 4 vCPU, 8 ГБ RAM, один виртуальный диск), вместо Яндекс.Облака ([logs/01-host.log](logs/01-host.log)). PostgreSQL 16 установил прямо на ВМ из репозитория Ubuntu ([logs/02-install.log](logs/02-install.log)):

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

**Проблема:** на диске ВМ было свободно всего 1,9 ГБ (остальное занимают LXD-контейнеры из прошлых ДЗ). В такой объём не помещаются ни нормальная тестовая база, ни WAL при большом `max_wal_size`.

**Решение:** увеличил виртуальный диск ВМ до 81 ГБ. После этого диск `vda` стал 81 ГБ, но раздел `/dev/vda1` и ext4 на нём остались 19 ГБ. Растянул раздел и файловую систему онлайн, без перезагрузки ([logs/03-disk-resize.log](logs/03-disk-resize.log)):

```bash
sudo growpart /dev/vda 1
sudo resize2fs /dev/vda1
```

```
CHANGED: partition=1 start=2099200 old: size=39851151 end=41950350 new: size=167774663 end=169873862
...
The filesystem on /dev/vda1 is now 20971520 (4k) blocks long.

$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda1        78G   18G   61G  23% /
```

## 2. Протестировать производительность с помощью pgbench

Настройки PostgreSQL — по умолчанию. Создал базу pgbench с масштабом 100 (1,5 ГБ, 10 млн строк в `pgbench_accounts`). Перед тестом сделал `checkpoint`, чтобы запись после загрузки данных не попала в замер. Тест — TPC-B, 24 клиента, 4 потока, 120 секунд, два прогона подряд. Клиентов меньше, чем строк в `pgbench_branches` (100), поэтому они почти не ждут блокировок на одной строке ([logs/04-pgbench-baseline.log](logs/04-pgbench-baseline.log)):

```bash
sudo -u postgres createdb bench
sudo -u postgres pgbench -i -s 100 bench
sudo -u postgres psql -c checkpoint
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 120 bench
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 120 bench
```

```
 pg_size_pretty
----------------
 1503 MB

max_wal_size|1024|MB
shared_buffers|16384|8kB
synchronous_commit|on|
fsync|on|
...
progress: 30.0 s, 1260.6 tps, lat 19.014 ms stddev 36.669, 0 failed
progress: 40.0 s, 320.6 tps, lat 73.805 ms stddev 121.557, 0 failed
progress: 50.0 s, 83.6 tps, lat 277.917 ms stddev 128.054, 0 failed
progress: 60.0 s, 247.4 tps, lat 101.713 ms stddev 137.762, 0 failed
...
latency average = 32.622 ms
tps = 733.811960 (without initial connection time)
...
progress: 50.0 s, 914.8 tps, lat 25.873 ms stddev 46.660, 0 failed
progress: 60.0 s, 94.8 tps, lat 255.527 ms stddev 117.766, 0 failed
progress: 70.0 s, 1057.6 tps, lat 22.733 ms stddev 43.827, 0 failed
...
latency average = 43.904 ms
tps = 544.698931 (without initial connection time)
```

Итог базового замера: 545–734 TPS, средняя задержка 33–44 мс. TPS всё время скачет от ~90 до ~1260.

## 3. Оптимизировать настройки PostgreSQL

Узкие места при настройках по умолчанию:

- база (1,5 ГБ) не помещается в `shared_buffers` (128 МБ), поэтому грязные страницы постоянно вытесняются на диск;
- `max_wal_size = 1GB` мал для такой нагрузки: чекпоинты запускаются по объёму WAL один за другим (см. п. 4);
- каждый коммит ждёт `fsync` WAL на медленном диске VDS.

Сначала задал только безопасные параметры, которые не влияют на надёжность. Их подбирал под ВМ с 4 vCPU и 8 ГБ RAM ([logs/05-tuning-safe.log](logs/05-tuning-safe.log)):

```sql
alter system set shared_buffers = '2GB';              -- 25% RAM, вся БД помещается в кэш
alter system set effective_cache_size = '6GB';        -- кэш ОС + shared_buffers, для планировщика
alter system set maintenance_work_mem = '512MB';
alter system set work_mem = '16MB';
alter system set wal_buffers = '64MB';
alter system set max_wal_size = '8GB';                -- чекпоинты по таймеру, а не по объёму WAL
alter system set min_wal_size = '2GB';
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
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 120 bench
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 120 bench
```

```
progress: 10.0 s, 2358.4 tps, lat 10.140 ms stddev 18.077, 0 failed
progress: 20.0 s, 2654.5 tps, lat 8.991 ms stddev 16.167, 0 failed
progress: 30.0 s, 3006.2 tps, lat 8.017 ms stddev 15.088, 0 failed
progress: 40.0 s, 3985.7 tps, lat 6.012 ms stddev 10.335, 0 failed
progress: 50.0 s, 4813.4 tps, lat 4.984 ms stddev 8.591, 0 failed
...
latency average = 5.471 ms
tps = 4382.832670 (without initial connection time)
...
progress: 10.0 s, 5234.3 tps, lat 4.570 ms stddev 7.375, 0 failed
progress: 20.0 s, 5211.9 tps, lat 4.600 ms stddev 7.016, 0 failed
...
progress: 120.0 s, 5219.3 tps, lat 4.595 ms stddev 12.188, 0 failed
...
latency average = 4.579 ms
tps = 5234.885968 (without initial connection time)
```

Первые ~40 секунд первого прогона TPS ниже: после рестарта `shared_buffers` пуст и прогревается. Во втором прогоне кэш уже тёплый, и TPS держится ровно на 5000–5470.

## 4. Проверить, насколько выросла производительность

После безопасного тюнинга TPS вырос с 545–734 до 4383–5235, средняя задержка упала с 33–44 до 4,6–5,5 мс. На прогретом кэше это в 7–10 раз лучше по обоим показателям. Провалы TPS до ~90 исчезли.

Эффект от `max_wal_size` видно по логу сервера ([logs/07-checkpoints.log](logs/07-checkpoints.log)). Базовые прогоны шли с 21:59:04 по 22:03:08. С 22:00:19 и до конца теста чекпоинты по объёму WAL (`checkpoint starting: wal`) шли подряд: каждый длился 80–86 секунд, и следующий начинался через 5 секунд после конца предыдущего. В конце каждого был `sync` на 7–10 секунд. После тюнинга (22:03:38–22:07:42) не было ни одного чекпоинта до рестарта:

```
2026-10-19 21:59:04.033 UTC [72283] LOG:  checkpoint starting: immediate force wait
2026-10-19 22:00:19.584 UTC [72283] LOG:  checkpoint starting: wal
2026-10-19 22:01:39.496 UTC [72283] LOG:  checkpoint complete: wrote 1813 buffers (11.1%); ... write=71.614 s, sync=7.096 s, total=79.912 s; ...
2026-10-19 22:01:44.398 UTC [72283] LOG:  checkpoint starting: wal
2026-10-19 22:03:10.510 UTC [72283] LOG:  checkpoint complete: wrote 1490 buffers (9.1%); ... write=75.895 s, sync=10.010 s, total=86.112 s; ...
2026-10-19 22:03:29.745 UTC [72275] LOG:  received fast shutdown request
...
2026-10-19 22:03:38.058 UTC [74509] LOG:  database system is ready to accept connections
2026-10-19 22:07:42.522 UTC [74509] LOG:  received fast shutdown request
```

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
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 120 bench
sudo -u postgres pgbench -c 24 -j 4 -P 10 -T 120 bench
```

```
fsync|off|
full_page_writes|off|
synchronous_commit|off|
wal_level|minimal|
...
latency average = 2.559 ms
tps = 9369.165444 (without initial connection time)
...
progress: 10.0 s, 9208.4 tps, lat 2.585 ms stddev 1.035, 0 failed
progress: 20.0 s, 9769.1 tps, lat 2.455 ms stddev 0.926, 0 failed
progress: 30.0 s, 9890.9 tps, lat 2.425 ms stddev 0.996, 0 failed
...
progress: 120.0 s, 9776.3 tps, lat 2.452 ms stddev 1.005, 0 failed
...
latency average = 2.513 ms
tps = 9543.992949 (without initial connection time)
```

Без гарантий надёжности кластер выдаёт ~9500 TPS: в 1,8 раза больше безопасного тюнинга и в 13–17 раз больше, чем на настройках по умолчанию. Задержка стабильная, около 2,5 мс. Цена — при сбое ОС или ВМ база может потерять последние транзакции и повредиться.
