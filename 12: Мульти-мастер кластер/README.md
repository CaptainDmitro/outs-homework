# ДЗ №12. Мульти-мастер кластер

Выбран **вариант 1: CockroachDB в облаке** (Yandex Cloud Compute).

## 1. Разверни CockroachDB в облаке

CockroachDB v26.3.2: кластер из трёх узлов, каждый принимает и чтение, и запись. Данные разбиты на диапазоны (ranges) по 512 МБ, у каждого диапазона три реплики на разных узлах, согласованные через Raft.

**Архитектура:**

- `crdb-d` (ru-central1-d, 10.130.0.20, 2 vCPU / 16 ГБ): узлы `node1` (`:26257`, DB Console `:8080`) и `node2` (`:26258`, `:8081`).
- `crdb-e` (ru-central1-e, 10.131.0.20, 2 vCPU / 8 ГБ): узел `node3` (`:26257`, `:8080`).
- На каждой ВМ загрузочный диск network-ssd 10 ГБ и диск данных network-hdd 20 ГБ (`/mnt/data`). Каждому узлу отдано 2 ГБ кеша и 2 ГБ SQL-памяти (`--cache`/`--max-sql-memory`), у узлов указаны `--locality=region=ru-central1,zone=...`.
- Режим `--insecure`, доступ к SSH, SQL и DB Console открыт в группе безопасности только с адреса администратора, между узлами только по внутренней сети VPC.

Зоны Yandex Cloud выступают «регионами» (Нью-Йорк, Чикаго, Москва из легенды). Доступны только две зоны, поэтому в зоне `d` работают два узла.

**Развёртывание.** Инфраструктура описана в [terraform/](terraform/): [main.tf](terraform/main.tf), [node.yaml.tftpl](terraform/node.yaml.tftpl) (cloud-init: форматирует диск данных, создаёт systemd-шаблон `cockroach@.service` и файлы `/etc/cockroach/nodeN.env` с портами), [variables.tf](terraform/variables.tf), [terraform.tfvars](terraform/terraform.tfvars). Бинарник ставит [install.sh](install.sh).

```bash
cd terraform
YC_TOKEN=$(yc iam create-token) terraform apply
cd ..
./install.sh cockroach-v26.3.2.linux-amd64.tgz 178.154.234.67 153.51.112.133
```

[logs/02-terraform-apply.log](logs/02-terraform-apply.log), [logs/05-install.log](logs/05-install.log):

```
Apply complete! Resources: 2 added, 1 changed, 0 destroyed.
public_ips = {
  "crdb-d" = "178.154.234.67"
  "crdb-e" = "153.51.112.133"
}
...
Build Tag:        v26.3.2
  cockroach@node1.service loaded active running CockroachDB node1
  cockroach@node2.service loaded active running CockroachDB node2
...
  cockroach@node3.service loaded active running CockroachDB node3
```

Инициализация кластера ([logs/06-init.log](logs/06-init.log)):

```
+ cockroach init --insecure --host=10.130.0.20:26257
Cluster successfully initialized
+ cockroach node status --insecure --host=10.130.0.20:26257
id	address	sql_address	build	...	locality	...	is_available	is_live
1	10.130.0.20:26257	10.130.0.20:26257	v26.3.2	...	region=ru-central1,zone=ru-central1-d	...	true	true
2	10.131.0.20:26257	10.131.0.20:26257	v26.3.2	...	region=ru-central1,zone=ru-central1-e	...	true	true
3	10.130.0.20:26258	10.130.0.20:26258	v26.3.2	...	region=ru-central1,zone=ru-central1-d	...	true	true
+ cockroach sql ... -e 'SET CLUSTER SETTING storage.sstable.compression_algorithm = zstd'
...
RANGE default	"ALTER RANGE default CONFIGURE ZONE USING
	range_max_bytes = 536870912,
	num_replicas = 3,
```

Нумерация CockroachDB не совпадает с именами сервисов: `n1` = `node1`, `n2` = `node3` (зона `e`), `n3` = `node2`.

**Проблема:** в `ru-central1-a` не создался диск: `FailedPrecondition desc = this type of operation is currently unavailable` ([logs/01-terraform-apply-failed.log](logs/01-terraform-apply-failed.log)). Квоты облака: 2 vCPU и 10 ГБ SSD + 20 ГБ HDD на зону.

**Решение:** как и в ДЗ №11, для этого облака доступны только зоны `d` и `e`. Вместо трёх ВМ по зонам сделано две, а третий узел работает вторым процессом на `crdb-d` (отдельный порт и каталог хранилища, systemd-шаблон `cockroach@node2`).

**Проблема:** cloud-init на обеих ВМ упал: `binaries.cockroachdb.com` отвечает `403` на адреса Yandex Cloud ([logs/03-cloud-init-download-failed.log](logs/03-cloud-init-download-failed.log)):

```
82:curl: (22) The requested URL returned error: 403
+ curl -sI https://binaries.cockroachdb.com/cockroach-v26.3.2.linux-amd64.tgz
HTTP/2 403
```

**Решение:** архив скачивается на Mac, сверяется с опубликованным `.sha256sum` и копируется на ВМ через `scp` ([install.sh](install.sh)). Скачивание убрано из cloud-init.

**Проблема:** первый `scp` на `crdb-e` упал с `Connection closed` ([logs/05-install.log](logs/05-install.log)): ключа хоста нового адреса не было в `known_hosts`, а неинтерактивный ssh не может спросить подтверждение.

**Решение:** отпечаток ED25519 из `yc compute instance get-serial-port-output crdb-e` сверен с `ssh-keyscan` и добавлен в `known_hosts`.

**Проверка мульти-мастера и консистентности** ([consistency.sh](consistency.sh), [logs/17-crdb-consistency.log](logs/17-crdb-consistency.log)). Скрипт 300 раз записывает строку через один узел и сразу читает её через другой (узлы по кругу), затем меряет время записи через каждый узел:

```
+ ./consistency.sh 300 'postgresql://root@10.130.0.20:26257/otus?sslmode=disable' 'postgresql://root@10.130.0.20:26258/otus?sslmode=disable' 'postgresql://root@10.131.0.20:26257/otus?sslmode=disable'
writes=300 stale_reads=0
gateway postgresql://root@10.130.0.20:26257/otus?sslmode=disable:
Time: 15.384 ms
Time: 18.833 ms
Time: 11.880 ms
gateway postgresql://root@10.130.0.20:26258/otus?sslmode=disable:
Time: 9.037 ms
...
gateway postgresql://root@10.131.0.20:26257/otus?sslmode=disable:
Time: 11.877 ms
Time: 8.974 ms
Time: 9.808 ms
```

Устаревших чтений нет: CockroachDB даёт сериализуемые транзакции, и чтение через любой узел видит подтверждённую запись. Запись через любой узел занимает 8–19 мс: это кворум Raft между зонами.

**Отказоустойчивость** ([logs/21-crdb-failover-node2.log](logs/21-crdb-failover-node2.log), [logs/21-crdb-failover-pgbench.log](logs/21-crdb-failover-pgbench.log)). Под нагрузкой pgbench (8 клиентов, шлюзы `node1` и `node3` через `load_balance_hosts=random`) процесс `node2` убит через `kill -9`. Автоперезапуск systemd на время теста отключён runtime drop-in'ом `Restart=no`:

```
+ date -u +%T
23:57:39
+ sudo kill -9 95488
+ systemctl is-active cockroach@node2
failed
+ cockroach node status ... --ranges --format=records
id                     | 1
is_live                | true
ranges_unavailable     | 0
ranges_underreplicated | 46
...
id                     | 3
address                | 10.130.0.20:26258
is_live                | false
+ cockroach sql ... -e 'SELECT count(*) FROM trips WHERE id BETWEEN 1 AND 1000000'
count
1000000
...
+ sudo systemctl start cockroach@node2
active
```

```
progress: 30.0 s, 234.2 tps, lat 34.018 ms stddev 16.207, 0 failed
progress: 35.0 s, 74.2 tps, lat 106.510 ms stddev 472.174, 0 failed
progress: 40.0 s, 142.8 tps, lat 56.873 ms stddev 294.481, 0 failed
progress: 45.0 s, 257.4 tps, lat 31.094 ms stddev 16.167, 0 failed
...
number of failed transactions: 0 (0.000%)
tps = 241.430264 (without initial connection time)
...
ranges_unavailable     | 0
ranges_underreplicated | 0
```

После отказа узла пропускная способность ~10 секунд проседает, пока истекают аренды (leases) на диапазоны `node2` и они переходят к оставшимся репликам. Ни одна транзакция не потеряна, недоступных диапазонов нет. После возврата узла реплики догоняются, и недореплицированных диапазонов не остаётся.

**Проблема:** первая попытка `systemctl kill -s KILL cockroach@node2 && systemctl stop ...` завершилась `Failed to send signal SIGKILL to auxiliary processes: Invalid argument`. Из-за `&&` команда `stop` не выполнилась, и systemd (`Restart=always`) сразу перезапустил узел ([logs/20-crdb-failover-node2-failed.log](logs/20-crdb-failover-node2-failed.log)).

**Решение:** на время теста автоперезапуск отключён через `/run/systemd/system/cockroach@node2.service.d/norestart.conf`, а процесс убивается по `MainPID`.

## 2. Используй датасет 10 Гб+

Датасет: таблица поездок `trips` ([sql/schema.sql](sql/schema.sql)) по трём городам. Строки генерируются на сервере из `generate_series` ([sql/load-chunk.sql](sql/load-chunk.sql)), все поля вычисляются из `id`, поэтому в CockroachDB и PostgreSQL данные совпадают байт в байт: это позволяет сверять результаты запросов. [load.sh](load.sh) режет диапазон id на порции по 200 тыс. строк и раздаёт их по кругу параллельным воркерам, по одному на каждый адрес. Для CockroachDB это три разных узла, то есть запись идёт одновременно через все мастера.

```bash
./load.sh 60000000 200000 \
  postgresql://root@10.130.0.20:26257/otus?sslmode=disable \
  postgresql://root@10.130.0.20:26258/otus?sslmode=disable \
  postgresql://root@10.131.0.20:26257/otus?sslmode=disable
FIRST=60000001 ./load.sh 66000000 200000 ...
```

Итог ([logs/13-crdb-verify.log](logs/13-crdb-verify.log)): **66 млн строк, 10,09 ГБ логических данных**, на каждом узле полная реплика 10,45 ГБ:

```
count	sum	complete
66000000	2178000033000000	t
ranges	logical_gb
42	10.09
id                | 1
live_bytes        | 10446633633
id                | 2
live_bytes        | 10446722743
id                | 3
live_bytes        | 10446187416
+ df -h /mnt/data
/dev/vdb         20G  4.7G   14G  26% /mnt/data
```

После компакций реплика `node3` с zstd занимает на диске 4,7 ГБ, то есть ~45 % от логического объёма. Основные воркеры загрузили 60 млн строк за 4242 с, дозагрузка порций воркера 1 закончилась ещё через ~8 минут ([logs/11-load-crdb-result.log](logs/11-load-crdb-result.log)), всего около 80 минут. Догрузка 6 млн строк заняла 281 с ([logs/12-load-crdb-extra.log](logs/12-load-crdb-extra.log)).

В PostgreSQL загружены те же 66 млн строк ([logs/27-pg-load.log](logs/27-pg-load.log)):

```
loaded ids 1..66000000 in 704 s, rc=0
+ psql -X -d otus -c '\timing on' -c 'VACUUM ANALYZE trips'
Time: 766683.610 ms (12:46.684)
  count   |       sum        | complete
----------+------------------+----------
 66000000 | 2178000033000000 | t
  table   | indexes | database
----------+---------+----------
 10114 MB | 2172 MB | 12 GB
```

**Проблема:** на 60 млн строк получилось 9,17 ГБ логических данных, меньше 10 ГБ.

**Решение:** в `load.sh` добавлен параметр `FIRST`, догружены id 60 000 001..66 000 000.

**Проблема:** по замерам на первых 16 млн строк две реплики на HDD `crdb-d` к концу загрузки заняли бы ~18–20 ГБ из 20, вместе с WAL и недоделанными компакциями. Snappy по умолчанию почти не сжимает случайные hex-строки.

**Решение:** до загрузки включён `storage.sstable.compression_algorithm = zstd`. Во время загрузки `node2` получил второе хранилище на загрузочном SSD (`--store=path=/var/lib/cockroach/node2,size=4GiB`). Реплики одного диапазона не кладутся на один узел, поэтому реплики `node2` распределились по двум его хранилищам, а `size=4GiB` не дал заполнить корневой раздел ([logs/08-node2-extra-store.log](logs/08-node2-extra-store.log), [logs/10-node2-store-size.log](logs/10-node2-store-size.log)). Пик: HDD 65 %, корневой раздел 80 %.

**Проблема:** перезапуск `node2` во время загрузки остановил воркер, писавший через него: 5 повторов по 5 секунд закончились раньше, чем узел снова начал принимать клиентов ([logs/11-load-crdb-result.log](logs/11-load-crdb-result.log)):

```
psql:sql/load-chunk.sql:13: ERROR:  server is shutting down
...
psql: error: connection to server at "10.130.0.20", port 26258 failed: ERROR:  server is not accepting clients, try another node
worker 1: chunk 15200001..15400000 failed, retry 5
loaded 60000000 rows in 4242 s, rc=1
```

Ещё одна порция получила `result is ambiguous: unable to determine whether command was applied via snapshot`.

**Решение:** порции воркера 1 дозагружены отдельным скриптом с паузой 30 с между повторами ([logs/09-load-resume-worker1.log](logs/09-load-resume-worker1.log)). Неоднозначная порция при повторе не дала `duplicate key`, значит первая попытка не применилась. Полнота подтверждена проверкой `sum(id) = n(n+1)/2`. Для приложений это значит, что повторы с обработкой `40001` и неоднозначных ошибок обязательны.

**Проблема:** в PostgreSQL загрузка упала с `integer out of range` ([logs/23-pg-load-failed.log](logs/23-pg-load-failed.log)): `generate_series` с целочисленными литералами возвращает `int4`, и `i * 104729` переполняется. В CockroachDB `INT` 64-битный, поэтому там ошибки не было.

**Решение:** `generate_series(:lo::BIGINT, :hi)`. В CockroachDB результат тот же: первые строки обеих СУБД сверены вручную.

**Проблема:** вторая загрузка в PostgreSQL заполнила диск: `No space left on device`, затем падение и recovery ([logs/24-pg-load-diskfull-failed.log](logs/24-pg-load-diskfull-failed.log)). При `max_wal_size = 8GB` WAL вырос до 8,1 ГБ, а рядом лежали 4,6 ГБ хранилища `node3` ([logs/25-free-space.log](logs/25-free-space.log)). После `max_wal_size = 2GB` и `CHECKPOINT` каталог `pg_wal` не уменьшился: «будущие» сегменты, переработанные заранее, удаляются только после использования.

**Решение:** тесты CockroachDB к этому моменту были закончены, поэтому хранилище `node3` удалено, а сервис отключён. Кластер PostgreSQL пересоздан сразу с `max_wal_size = 2GB` ([logs/26-postgresql-recreate.log](logs/26-postgresql-recreate.log)).

## 3. Сравни производительность запросов с однопользовательским инстансом PostgreSQL

PostgreSQL 16.15 развёрнут на `crdb-e` (2 vCPU / 8 ГБ, тот же HDD 20 ГБ) после остановки `node3`, чтобы СУБД досталась вся ВМ ([logs/22-postgresql-setup.log](logs/22-postgresql-setup.log)): `shared_buffers = 2GB` (как кеш узла CockroachDB), `effective_cache_size = 6GB`, `work_mem = 64MB`, `max_parallel_workers_per_gather = 2`. Клиент в обоих случаях запускался на `crdb-e`, к CockroachDB через локальный `node3`. Запросы ([sql/queries.sql](sql/queries.sql)) прогнаны по 3 раза, перед замерами собрана статистика (`ANALYZE` в CockroachDB, `VACUUM ANALYZE` в PostgreSQL).

| Запрос | CockroachDB, 3 узла ([logs/15](logs/15-crdb-queries.log)) | PostgreSQL ([logs/28](logs/28-pg-queries.log)) |
|---|---|---|
| Q1: точечное чтение по PK | 1,9 / 1,3 / 1,7 мс | 124 (холодный) / 1,4 / 1,6 мс |
| Q2: диапазон PK, 100 тыс. строк | 101 / 167 / 93 мс | 21 869 (холодный) / 49 / 51 мс |
| Q3: агрегация по всей таблице | 53,6 / 58,6 / 58,9 с | 345 / 383 / 378 с |
| Q4: группировка по 100 тыс. водителей | 188 / 227 / 239 с | 348 / 378 / 346 с |
| OLTP pgbench, 8 клиентов, 60 с | 324 tps, 24,7 мс ([logs/19](logs/19-crdb-pgbench.log)) | 148 tps, 53,8 мс ([logs/29](logs/29-pg-pgbench.log)) |

OLTP-нагрузка ([sql/oltp.pgbench](sql/oltp.pgbench)): чтение и `UPDATE` случайной строки по PK. С балансировкой по трём узлам (`load_balance_hosts=random`) у CockroachDB 289 tps, это меньше, чем через один шлюз: половина клиентов попадает на `crdb-d`, где два узла делят 2 vCPU.

Результаты запросов совпадают в обеих СУБД, например Q3:

```
   city   |  count   |      sum      |   avg
----------+----------+---------------+---------
 chicago  | 22000000 | 1165890000.00 | 24999.5
 moscow   | 22000000 | 1165890000.00 | 24999.5
 new_york | 22000000 | 1165890000.00 | 24999.5
```

Почему так:

- **Полные сканы (Q3, Q4).** PostgreSQL читает 1 079 606 блоков (8,2 ГБ) с одного network-hdd за ~390 с, это ~21 МБ/с, упор в полосу диска:
  ```
  ->  Parallel Seq Scan on trips  (... actual time=17.685..391174.315 rows=22000000 loops=3)
        Buffers: shared hit=214628 read=1079606
  Execution Time: 399710.554 ms
  ```
  CockroachDB выполняет запрос распределённо (`distribution: full`, `sql nodes: n1, n2, n3`): каждый узел сканирует свою часть диапазонов со своего диска, а данные сжаты zstd примерно вдвое. Q4 упирается уже в CPU: хеш-агрегация по 100 тыс. групп заняла `sql cpu time: 7m44s` на 4 vCPU кластера, поэтому выигрыш меньше.
- **Точечные запросы (Q1, Q2).** С прогретым кешем PostgreSQL быстрее: у него нет сетевого шлюза и KV-слоя, Q2 выполняется за 50 мс против ~100 мс. Холодные первые запуски PostgreSQL (124 мс и 21,9 с) — это случайное чтение с HDD.
- **OLTP.** У PostgreSQL случайные чтения и обновления по 12 ГБ данных при 8 ГБ ОЗУ уходят в HDD. У CockroachDB рабочий набор сжат (~4,7 ГБ на узел) и распределён по трём узлам, при том что каждая запись подтверждается кворумом между зонами.

**Проблема:** первый прогон запросов на CockroachDB шёл без статистики (`missing stats` в плане, `SHOW STATISTICS` пустой), хотя `sql.stats.automatic_collection.enabled = t` ([logs/14-crdb-queries-nostats.log](logs/14-crdb-queries-nostats.log)).

**Решение:** статистика собрана явно через `ANALYZE trips` (6,5 мин), замер повторён ([logs/15-crdb-queries.log](logs/15-crdb-queries.log)). Q1 ускорился с 7–45 мс до 1,3–1,9 мс.

**Проблема:** `pgbench` не нашёлся: `pg_wrapper: pgbench was not found` ([logs/16-crdb-pgbench-failed.log](logs/16-crdb-pgbench-failed.log)). В Ubuntu он входит в серверный пакет.

**Решение:** установлен `postgresql-16` с `create_main_cluster = false` ([logs/18-install-postgresql.log](logs/18-install-postgresql.log)).

## 4. Опиши процесс, решения и возникшие сложности

Процесс и решения описаны в пунктах 1–3: развёртывание Terraform + cloud-init, установка бинарника с Mac, параллельная загрузка через все узлы, проверка полноты и консистентности, отказ узла под нагрузкой, сравнение с PostgreSQL на том же железе.

Сложности, которые не связаны с конкретным шагом:

- С v24.3 CockroachDB требует лицензию (Enterprise Free или Trial). Без неё у нового кластера 7 дней grace-периода, после чего включается троттлинг, а в каждую сессию приходит `NOTICE:  No license is installed. Throttling will begin after 2026-10-27 21:19:50 +0000 UTC` (в логах pgbench такие строки схлопнуты в одну). Доступ к `crdb_internal` по умолчанию закрыт (`allow_unsafe_internals`), поэтому размеры смотрелись через `SHOW RANGES ... WITH DETAILS` и `cockroach node status --stats`.
- Загрузка через `INSERT ... SELECT generate_series` в CockroachDB идёт почти в 7 раз медленнее, чем в PostgreSQL (~85 минут против 704 с): каждая запись реплицируется в три копии через Raft, а у `crdb-d` с двумя узлами на 2 vCPU всю загрузку load average держался на 5–8.
- Из двух зон кластер переживает отказ узла и отказ зоны `e`, но не отказ зоны `d`: там два узла из трёх, и при её потере пропадает кворум.

**Выводы.** CockroachDB даёт то, о чём просили в задаче: писать и читать можно через любой узел, данные сразу консистентны (0 устаревших чтений), отказ узла проходит без потерянных транзакций, а аналитические запросы по 10+ ГБ масштабируются на узлы и в этом стенде идут в 6,5 раза быстрее одного PostgreSQL. Цена: запись медленнее и дороже (кворум, тройная репликация, загрузка почти в 7 раз дольше), больше требований к железу, лицензия, а точечные запросы с прогретым кешем у PostgreSQL быстрее.

**Рекомендации:**

- Ставить узлы минимум в три разных региона или зоны, по одному на регион, и следить за квотами: при двух зонах отказ одной из них может положить кластер. Для «свой регион пишет быстро» использовать мультирегиональную БД (`ALTER DATABASE ... ADD REGION`, таблицы `REGIONAL BY ROW` с колонкой региона), для отчётов — follower reads (`AS OF SYSTEM TIME follower_read_timestamp()`).
- Минимум 4 vCPU на узел и SSD: на 2 vCPU и network-hdd кластер упирается в CPU и полосу диска.
- Включать `zstd`, а большие объёмы грузить через `IMPORT INTO` или `COPY`, а не порциями `INSERT ... SELECT`. После загрузки запускать `ANALYZE`.
- Балансировать клиентов по узлам (`load_balance_hosts=random` в libpq 16+, HAProxy или сетевой балансировщик) и обязательно повторять транзакции на `40001` и `result is ambiguous`.
- Перед продом получить лицензию и держать зеркало бинарников и образов: `binaries.cockroachdb.com` недоступен из российских облаков.
