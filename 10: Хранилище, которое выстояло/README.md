# ДЗ №10. Хранилище, которое выстояло

## 1. Выбрать одну из СУБД

Выбрал **ClickHouse**. Ирине нужно понять, где быстрее агрегации и отчёты, а это ровно тот профиль, под который сделана колоночная СУБД с движком MergeTree. Сравниваю с **PostgreSQL 17**.

Обе СУБД стоят на одной VM в **VK Cloud**, поэтому условия одинаковые. VM поднимаю через Terraform ([terraform](terraform)): `STD3-8-32` (8 vCPU Intel Ice Lake, 32 ГБ RAM), загрузочный диск `high-iops` 250 ГБ, Ubuntu 24.04. Сеть и подсеть остались от ДЗ №9, роутер нужен только для выхода в интернет ([logs/01-terraform-apply.log](logs/01-terraform-apply.log)):

```
vkcs_compute_instance.bench: Creation complete after 1m16s [id=613fef55-cbcc-42c5-b6b0-0d6c0c4ffa79]

Apply complete! Resources: 3 added, 0 changed, 0 destroyed.
```

**Проблема:** в проекте VK Cloud квота floating IP = 0, поэтому у VM нет публичного адреса и по SSH к ней не подключиться.

**Решение:** при старте cloud-init ставит на VM небольшой агент ([cloud-init/user-data.yaml](cloud-init/user-data.yaml)). Он раз в 10 секунд читает метаданные сервера из `169.254.169.254`. С Mac скрипт [scripts/vkcmd.py](scripts/vkcmd.py) кладёт туда очередной скрипт шага, сжатый gzip, в base64 и порезанный на ключи по 255 символов. Агент выполняет скрипт и пишет вывод в серийную консоль, оттуда `vkcmd.py fetch` забирает его через `os-getConsoleOutput`. Так получены все логи в [logs](logs): шаги лежат в [scripts](scripts), SQL в [sql](sql).

Установка: PostgreSQL 17 из PGDG, ClickHouse из официального репозитория, pgloader, генератор TPC-H `dbgen` ([scripts/02-install.sh](scripts/02-install.sh), [logs/02-install-failed.log](logs/02-install-failed.log)):

```
+ psql --version
psql (PostgreSQL) 17.11 (Ubuntu 17.11-1.pgdg24.04+2)
+ clickhouse-server --version
ClickHouse server version 26.9.23.15 (official build).
+ pgloader --version
pgloader version "3.6.10~devel"
```

Настройки PostgreSQL под 8 vCPU / 32 ГБ лежат в [scripts/pg-bench.conf](scripts/pg-bench.conf): `shared_buffers = 8GB`, `work_mem = 256MB`, `max_wal_size = 32GB`, `max_parallel_workers_per_gather = 8`, `random_page_cost = 1.1`. В ClickHouse изменён только `user_files_path` (каталог с CSV для `file()`), остальное по умолчанию.

**Проблема:** пароль `postgres` не задался, `createdb` тоже упал:

```
+ runuser -u postgres -- psql -c 'ALTER USER postgres PASSWORD '\''otus_pass'\'''
psql: error: connection to server at "localhost" (127.0.0.1), port 5432 failed: FATAL:  password authentication failed for user "postgres"
```

**Решение:** все шаги подключают [scripts/env.sh](scripts/env.sh) с `PGHOST=localhost`, `PGPASSWORD` и `PGDATABASE=tpch`. Из-за этого `runuser psql` шёл по TCP с паролем, который ещё не задан, а не через peer-аутентификацию на сокете. Со второй попытки я убрал `PGHOST` и `PGPASSWORD`, но остался `PGDATABASE=tpch` — база, которой ещё нет ([logs/02-install-pg-failed.log](logs/02-install-pg-failed.log)). Третья попытка без всех трёх переменных прошла ([scripts/02-install-pg.sh](scripts/02-install-pg.sh), [logs/02-install-pg.log](logs/02-install-pg.log)):

```
+ runuser -u postgres -- env -u PGHOST -u PGPASSWORD -u PGDATABASE psql -c 'ALTER USER postgres PASSWORD '\''otus_pass'\'''
ALTER ROLE
+ psql -c 'SELECT version()'
 PostgreSQL 17.11 (Ubuntu 17.11-1.pgdg24.04+2) on x86_64-pc-linux-gnu, compiled by gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0, 64-bit
```

ClickHouse ответил сразу (`SELECT version()` → `26.9.23.15`). Обе системы работают.

## 2. Загрузить в неё данные

### Объём данных

Набор TPC-H с коэффициентом масштаба 20, сгенерированный `dbgen`. Большие таблицы режутся на 8 частей и генерируются в 8 процессов ([scripts/04-datagen.sh](scripts/04-datagen.sh), [logs/04-datagen.log](logs/04-datagen.log)):

```
real 92.187s
+ du -sh --apparent-size /data/tpch
21G	/data/tpch
lineitem 119994608
orders 30000000
partsupp 16000000
part 4000000
supplier 200000
nation 25
region 5
```

Ещё 3 млн строк `customer` генерируются потоком при загрузке (см. ниже). После загрузки ([logs/09-sizes.log](logs/09-sizes.log)):

| | PostgreSQL | ClickHouse |
|---|---|---|
| lineitem | 18 GB + индексы 4402 MB | 2.81 GiB (без сжатия 10.76 GiB) |
| orders | 4195 MB + 842 MB | 713 MiB (2.88 GiB) |
| вся БД | 31 GB (+ WAL 30G) | 4.50 GiB (16.73 GiB), сжатие в 3,7 раза |

**Проблема:** `dbgen` ставит разделитель `|` и после последнего поля, а `COPY` из-за этого видит лишнюю колонку:

```
1|3103787|153803|1|17|30440.71|0.04|0.02|N|O|1996-03-13|1996-02-12|1996-03-22|DELIVER IN PERSON|TRUCK|egular courts above the|
```

**Решение:** после генерации прохожу все файлы `sed -i 's/|$//'` в 8 потоков (31 с), при потоковой загрузке ставлю `sed` в конвейер.

**Проблема:** у одного файла оказались права `---x-----x`, его не прочитали бы ни `postgres`, ни `clickhouse`:

```
---x-----x 1 root root 1959810145 Oct 20 18:57 lineitem.tbl.6
```

**Решение:** `dbgen` при параллельной генерации (`-C/-S`) создаёт файл через `open(..., O_CREAT)` без аргумента mode, и права берутся случайные. В начало загрузки добавил `chmod 644 $D/*.tbl*` ([logs/05-pg-load-methods.log](logs/05-pg-load-methods.log)).

### Механизмы загрузки

Все способы проверял на одной таблице `orders` (30 млн строк, 3,5 ГБ CSV, 8 файлов), перед каждым — `TRUNCATE`. Для INSERT использовал один и тот же SQL-файл в обеих СУБД. PostgreSQL: [scripts/05-pg-load-methods.sh](scripts/05-pg-load-methods.sh), [logs/05-pg-load-methods.log](logs/05-pg-load-methods.log). ClickHouse: [scripts/06-ch-load-methods.sh](scripts/06-ch-load-methods.sh), [logs/06-ch-load-methods.log](logs/06-ch-load-methods.log).

| Способ | Строк | PostgreSQL | ClickHouse |
|---|---|---|---|
| INSERT по одной строке | 20 000 | 8,8 с (2 280 строк/с) | 1214,5 с (16 строк/с) |
| то же с `async_insert=1` | 20 000 | — | 10,3 с (1 940 строк/с) |
| INSERT по 1000 строк | 1 000 000 | 16,8 с (59 тыс./с) | 61,3 с (16 тыс./с) |
| `COPY` / `INSERT FORMAT CSV`, один поток | 30 млн | 57,0 с (526 тыс./с) | — |
| стриминг через клиента: `cat \| COPY FROM STDIN` / `cat \| clickhouse-client` | 30 млн | 63,1 с (475 тыс./с) | 8,3 с (3,6 млн/с) |
| параллельно: 8 сессий по файлу | 30 млн | 20,8 с (1,45 млн/с) | 8,9 с (3,4 млн/с) |
| на сервере: `file('orders.tbl.*')`, `max_insert_threads=8` | 30 млн | — | 7,1 с (4,2 млн/с) |
| сторонние средства: pgloader / `postgresql()` из PG в CH | 30 млн | 526,2 с (57 тыс./с) | 29,3 с (1,0 млн/с) |
| стриминг из генератора: `dbgen → FIFO → sed → COPY` (customer) | 3 млн | 13,6 с | 11,3 с |

Стриминг из генератора идёт без промежуточного файла на диске:

```
+ mkfifo customer.tbl
+ /opt/tpch-dbgen/dbgen -q -f -s 20 -T c
+ sed 's/|$//' customer.tbl
+ psql -qc 'COPY customer FROM STDIN (DELIMITER '\''|'\'')'
+ wait
real 13.591s
```

pgloader из одного конфига [scripts/orders.load](scripts/orders.load) забирает все 8 файлов:

```
      "public"."orders"          0   30000000     3.2 GB        3m1.118s
COPY Threads Completion          0         16                  8m44.923s
      Total import time          ✓   30000000     3.2 GB       8m44.938s
```

**Проблема:** одиночные синхронные INSERT в ClickHouse заняли 20 минут на 20 000 строк, по 60 мс на строку. Пачки по 1000 строк тоже медленнее, чем в PostgreSQL.

**Решение:** в MergeTree каждый INSERT создаёт на диске новый кусок (part) из нескольких файлов, и 60 мс — это его накладные расходы, не зависящие от числа строк. Помогает `async_insert=1`: сервер копит строки в буфере и пишет их крупными кусками. Те же 20 000 строк легли за 10,3 с, итог — 3 куска. Для объёмов ClickHouse ждёт большие пачки: поток через клиента или `file()` укладывают 30 млн строк за 7–9 с.

Остальные таблицы грузил самым быстрым способом в каждой СУБД. PostgreSQL: параллельный `COPY` в 8 сессий — 116,1 с, затем первичные ключи, индексы по `l_shipdate` и `o_orderdate` и `VACUUM ANALYZE` — ещё 175,0 с ([logs/07-pg-load-all.log](logs/07-pg-load-all.log)):

```
real 116.114s
...
ALTER TABLE lineitem ADD PRIMARY KEY (l_orderkey, l_linenumber);
Time: 50716.484 ms (00:50.716)
CREATE INDEX lineitem_shipdate_idx ON lineitem (l_shipdate);
Time: 47113.162 ms (00:47.113)
VACUUM ANALYZE;
Time: 56548.731 ms (00:56.549)
real 174.972s
```

ClickHouse: `INSERT ... SELECT FROM file()` — 62,1 с на все таблицы. Индекс задаётся ключом сортировки (`ORDER BY (l_shipdate, l_orderkey)`) и строится при вставке ([logs/08-ch-load-all.log](logs/08-ch-load-all.log)).

**Проблема:** запрос размеров в ClickHouse упал на синтаксисе ([logs/09-sizes-failed.log](logs/09-sizes-failed.log)):

```
Code: 62. DB::Exception: Syntax error: failed at position 404 (TOTALS) (line 7, col 8): TOTALS. Expected one of: FILL, end of query. (SYNTAX_ERROR)
```

**Решение:** `WITH TOTALS` в ClickHouse пишется сразу после `GROUP BY`, до `ORDER BY`. Заодно `du` каталога PostgreSQL (61G) разбил на `base` и `pg_wal`: 30G из них — WAL при `max_wal_size = 32GB`.

## 3. Провести сравнение

### Запросы

Три запроса по мотивам TPC-H, текст один и тот же для обеих СУБД:

- [sql/q1-agg.sql](sql/q1-agg.sql) — **агрегация** (TPC-H Q1): сводка по 118 млн строк `lineitem` с группировкой по `l_returnflag, l_linestatus`;
- [sql/q2-filter.sql](sql/q2-filter.sql) — **фильтрация** (Q6, сужен до одного месяца): `l_shipdate` за январь 1994, диапазон скидки, количество < 24;
- [sql/q3-join.sql](sql/q3-join.sql) — **соединение** (Q3): `lineitem ⋈ orders ⋈ customer`, группировка и топ-10 по выручке.

### Системные условия

VM `STD3-8-32`: 8 vCPU Intel Ice Lake, 31 ГиБ RAM, без swap, Ubuntu 24.04.4, ядро 6.8. Диск `high-iops` 250 ГБ, замер fio ([scripts/03-system.sh](scripts/03-system.sh), [logs/03-system.log](logs/03-system.log)):

```
  write: IOPS=964, BW=965MiB/s (1012MB/s)(8192MiB/8492msec); 0 zone resets
  read: IOPS=964, BW=965MiB/s (1012MB/s)(8192MiB/8492msec)
  read: IOPS=10.0k, BW=78.4MiB/s (82.2MB/s)(2354MiB/30026msec)
```

Последовательно диск отдаёт около 1 ГБ/с, случайное чтение упирается в лимит 10 тыс. IOPS.

Методика ([scripts/10-queries-pg.sh](scripts/10-queries-pg.sh), [scripts/11-queries-ch.sh](scripts/11-queries-ch.sh)). Перед каждым запросом обе СУБД останавливаются, кеш ОС сбрасывается (`echo 3 > /proc/sys/vm/drop_caches`), запускается только тестируемая. Первый прогон холодный, второй и третий — с прогретым кешем. В ClickHouse перед замерами дожидался окончания фоновых слияний (`system.merges` = 0).

### Время

Логи: [logs/10-queries-pg.log](logs/10-queries-pg.log), [logs/11-queries-ch.log](logs/11-queries-ch.log). Результаты запросов в обеих СУБД совпадают.

| Запрос | PostgreSQL: холодный / 2 / 3 | ClickHouse: холодный / 2 / 3 | Разница (тёплый кеш) |
|---|---|---|---|
| Q1 агрегация | 19,68 / 16,04 / 15,38 с | 1,94 / 1,76 / 1,52 с | ~10× |
| Q2 фильтрация | 55,66 / 2,38 / 2,44 с | 0,041 / 0,020 / 0,019 с | ~120× |
| Q3 соединение | 29,14 / 10,17 / 10,41 с | 1,08 / 0,88 / 0,89 с | ~11× |

### Планы выполнения

**Q1, PostgreSQL:** параллельный seq scan всей таблицы в 9 процессах. Прочитано 2,3 млн страниц (18 ГБ), основное время уходит на арифметику `numeric` в агрегатах, на JIT ещё 2,1 с:

```
 Finalize GroupAggregate  (cost=3015789.49..3015797.15 rows=6 width=236) (actual time=16546.020..16554.519 rows=4 loops=1)
   Buffers: shared hit=920 read=2309278
   ->  Gather Merge  (cost=3015789.49..3015795.43 rows=48 width=236) (actual time=16545.960..16554.418 rows=36 loops=1)
         Workers Launched: 8
...
               ->  Partial HashAggregate  (cost=3014789.13..3014789.27 rows=6 width=236) (actual time=16519.433..16519.439 rows=4 loops=9)
                     ->  Parallel Seq Scan on lineitem  (cost=0.00..2497635.05 rows=14775831 width=25) (actual time=235.835..2583.095 rows=13145120 loops=9)
                           Filter: (l_shipdate <= '1998-09-02'::date)
...
   Timing: Generation 12.557 ms (Deform 6.919 ms), Inlining 750.994 ms, Optimization 831.842 ms, Emission 539.382 ms, Total 2134.776 ms
 Execution Time: 16574.072 ms
```

**Q1, ClickHouse:** читает только 6 нужных колонок из 16, 3,97 GiB в несжатом виде. Агрегирует векторно, памяти тратит 16 МиБ:

```
   └──ReadFromMergeTree (tpch.lineitem)
         Parts: 3 | Granules: 14443
         Output: l_returnflag, l_linestatus, l_quantity, l_extendedprice, l_discount, l_tax
         Prewhere filter column:  l_shipdate <= \'1998-09-02\'
             Granules: 14443/14677
```

**Q2, PostgreSQL:** индекс по `l_shipdate` находит 1,5 млн строк, но они разбросаны по всей таблице: она физически упорядочена по `l_orderkey`. Bitmap Heap Scan читает 839 тыс. страниц, больше трети таблицы. На холодную это случайное чтение с диска, который упирается в 10 тыс. IOPS, отсюда 55,7 с:

```
               ->  Parallel Bitmap Heap Scan on lineitem  (cost=17701.03..1252848.87 rows=29033 width=12) (actual time=793.234..2994.085 rows=24275 loops=8)
                     Recheck Cond: ((l_shipdate >= '1994-01-01'::date) AND (l_shipdate < '1994-02-01'::date))
                     Heap Blocks: exact=105344
                     Buffers: shared hit=1 read=839227
                     ->  Bitmap Index Scan on lineitem_shipdate_idx  (cost=0.00..17650.22 rows=1614485 width=0) (actual time=386.452..386.453 rows=1544294 loops=1)
```

**Q2, ClickHouse:** данные отсортированы по `l_shipdate`, поэтому разреженный первичный индекс отсекает 14 485 гранул из 14 677. Читается 1,57 млн строк (39 МиБ), и это последовательное чтение:

```
         PrimaryKey
           Keys:
             l_shipdate
           Condition: and((l_shipdate in (-Inf, 8796]), (l_shipdate in [8766, +Inf)))
           Granules: 192/14677
```

**Q3, PostgreSQL:** seq scan `lineitem` (64,7 млн строк после фильтра), затем Nested Loop с Memoize по индексу `orders_pkey` (16,5 млн обращений к индексу) и hash join с `customer`. 83 млн попаданий в shared buffers:

```
                                 ->  Nested Loop  (cost=0.57..2945220.55 rows=3919120 width=32) (actual time=12.196..10257.154 rows=333003 loops=9)
                                       ->  Parallel Seq Scan on lineitem  (cost=0.00..2497635.05 rows=8052018 width=20) (actual time=0.074..2223.478 rows=7187573 loops=9)
                                       ->  Memoize  (cost=0.57..0.60 rows=1 width=20) (actual time=0.001..0.001 rows=0 loops=64688156)
                                             ->  Index Scan using orders_pkey on orders  (cost=0.56..0.59 rows=1 width=20) (actual time=0.003..0.003 rows=0 loops=16562067)
 Execution Time: 11909.285 ms
```

**Q3, ClickHouse:** сначала строит хеш-таблицы по меньшим `customer` и `orders`, потом стримит `lineitem` через параллельный хеш-джойн с runtime-фильтром по `o_orderkey`. Ключ сортировки отсекает половину гранул `lineitem` и `orders`:

```
      └──Join (JOIN FillRightFirst)
         │  lineitem[64440668] ⋈ (orders[14569646] ⋈ customer[500000])
         │  Type: inner | Strictness: all | Algorithm: SpillingHashJoin(ConcurrentHashJoin)
         ├──ReadFromMergeTree (tpch.lineitem)
         │     Runtime filters: RF2(l_orderkey, o_orderkey)
         │         Granules: 7927/14677
```

Сводка из `system.query_log`:

```
   ┌──────────event_time─┬───ms─┬─read_rows─┬─read──────┬─memory─────┬─query_text───────────────────────────────┐
1. │ 2026-10-20 20:08:48 │ 1938 │ 118315577 │ 3.97 GiB  │ 18.43 MiB  │ SELECT l_returnflag,        l_linestatus │
4. │ 2026-10-20 20:08:58 │   41 │   1572864 │ 39.00 MiB │ 4.22 MiB   │ SELECT sum(l_extendedprice * l_discount) │
7. │ 2026-10-20 20:09:06 │ 1084 │  82280368 │ 1.77 GiB  │ 470.48 MiB │ SELECT l_orderkey,        sum(l_extended │
```

**Проблема:** первый вариант этой сводки (с `query LIKE '%FROM lineitem%'`) вернул пустой результат, хотя записи в `query_log` есть.

**Решение:** в SELECT был алиас `substring(...) AS query`, а ClickHouse, в отличие от PostgreSQL, подставляет алиасы и в `WHERE`. `LIKE` проверял обрезанную до 40 символов строку, а не текст запроса. Переименовал алиас в `query_text` и перезапустил шаг, в логе итоговый прогон.

## 4. Описать процесс

**Что выбирал и почему.** ClickHouse — потому что вопрос Ирины про агрегации и отчёты, а колоночное хранение с сортировкой и сжатием сделано под них. Набор TPC-H: у него известная схема, есть генератор любого объёма, а запросы Q1/Q6/Q3 покрывают агрегацию, фильтрацию и соединение. SF20 = 21 ГБ CSV, в PostgreSQL это 31 ГБ, так что данные сравнимы с объёмом RAM. Обе СУБД на одной VM, чтобы сравнение было честным.

**Какие механизмы загрузки пробовал.** INSERT по одной строке и пачками, `COPY` с сервера, стриминг через клиента (`COPY FROM STDIN`, `clickhouse-client ... FORMAT CSV`), параллельную загрузку в 8 сессий, серверную `file()` с параллельной вставкой, `async_insert`, стриминг прямо из генератора через FIFO, сторонние средства: pgloader и табличную функцию `postgresql()` (ClickHouse сам забирает данные из PostgreSQL). Цифры в таблице в п. 2.

**С какими проблемами столкнулся.** Нет floating IP в VK Cloud: сделал канал через метаданные сервера и серийную консоль. Переменные `PG*` мешали первичной настройке. `dbgen` даёт лишний разделитель в конце строки и создаёт файлы со случайными правами. Синхронные одиночные INSERT в ClickHouse очень медленные. Синтаксис `WITH TOTALS` и алиасы в `WHERE` в ClickHouse.

**Что показалось удобным.** В ClickHouse: загрузка по маске файлов одной командой (`file('orders.tbl.*')`) со скоростью 4 млн строк/с без отдельной утилиты, импорт прямо из PostgreSQL через `postgresql()`, сжатие в 3,7 раза, `EXPLAIN indexes = 1` с числом отсечённых гранул, `system.query_log` с прочитанными байтами и памятью на каждый запрос. В PostgreSQL: дешёвые одиночные INSERT (2 тыс. строк/с даже с коммитом каждой строки), предсказуемый `COPY`, подробный `EXPLAIN (ANALYZE, BUFFERS)`.

**Что неудобно.** В ClickHouse нельзя писать по строке: нужен буфер (`async_insert`) или пачки на сотни тысяч строк. Индекс один — порядок сортировки, и выбрать его нужно при создании таблицы. Есть мелкие отличия SQL от стандарта. В PostgreSQL загрузка — это не только `COPY`: ещё 3 минуты уходят на индексы и `VACUUM ANALYZE`, WAL при загрузке занял ещё 30 ГБ. pgloader оказался в 25 раз медленнее параллельного `COPY`. На холодном кеше фильтр по неупорядоченному столбцу превращается в случайное чтение.

Итог для Ирины: агрегации и отчёты по большому массиву гонять в ClickHouse — на тех же 8 vCPU он в 10–120 раз быстрее, а данные занимают в 7 раз меньше места. PostgreSQL оставить для транзакционной части с точечными изменениями и построчными вставками.
