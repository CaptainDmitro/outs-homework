# ДЗ №13. Параллельный кластер

Выбран **YugabyteDB 2025.2.7.0** (YSQL на базе PostgreSQL 15), развёрнут на виртуальных машинах в **Yandex Cloud** через Terraform, без Kubernetes: задание допускает «Kubernetes или облака». Датасет — **TPC-H SF10** (около 60 млн строк в `lineitem`).

## 1. Разверните Yugabyte или Greenplum в Kubernetes или облаках

Инфраструктура описана в [terraform/main.tf](terraform/main.tf): по одной VM в зоне, у каждой 10 ГБ SSD под систему и 20 ГБ HDD под данные (`/data`, XFS, размечается через cloud-init в [terraform/user-data.yaml.tftpl](terraform/user-data.yaml.tftpl)). Группа безопасности открывает SSH и веб-интерфейсы YB только с моего адреса, а трафик между нодами разрешает внутри группы.

```
+ terraform apply -auto-approve
...
Apply complete! Resources: 1 added, 1 changed, 0 destroyed.

nodes = {
  "otus-yb-d" = {
    "external_ip" = "178.154.250.252"
    "internal_ip" = "10.130.0.8"
    "zone" = "ru-central1-d"
  }
  "otus-yb-e" = {
    "external_ip" = "153.51.115.27"
    "internal_ip" = "10.131.0.16"
    "zone" = "ru-central1-e"
  }
}
```
Лог: [logs/04-terraform-apply.log](logs/04-terraform-apply.log). Ноды: Ubuntu 24.04.5, 2 vCPU AMD EPYC Genoa, 15 ГиБ RAM ([logs/05-nodes-check.log](logs/05-nodes-check.log)).

**Проблема:** квоты облака — 2 vCPU, 16 ГБ RAM, 10 ГБ SSD и 20 ГБ HDD на зону. Квоты по договорённости не увеличивал. Задумывались 3 ноды в зонах a, d и e, но в `ru-central1-a` создание диска отклонено (`FailedPrecondition desc = this type of operation is currently unavailable`), а в `ru-central1-b` — `Resource allocation is restricted` ([logs/01-terraform-apply-failed.log](logs/01-terraform-apply-failed.log)).

**Решение:** кластер из **2 нод** (зоны d и e) с **RF1**. Данные шардируются по обеим нодам, но не реплицируются, поэтому отказоустойчивости нет. Для RF3 нужны минимум 3 ноды, то есть 6 vCPU, а доступно 4.

**Проблема:** в `ru-central1-e` не хватило мощностей для `standard-v3`: `ResourceExhausted desc = Not enough resources` ([logs/02-terraform-apply-failed.log](logs/02-terraform-apply-failed.log), [logs/03-terraform-apply-failed.log](logs/03-terraform-apply-failed.log)).

**Решение:** обе ноды переведены на `standard-v4a` (AMD), чтобы железо было одинаковым (`allow_stopping_for_update = true`, нода d пересоздалась на месте).

Установка YugabyteDB: [scripts/install-yugabyte.sh](scripts/install-yugabyte.sh) (tarball `yugabyte-2025.2.7.0-b107-linux-x86_64.tar.gz`, `post_install.sh`, лимиты `nofile`/`nproc`), логи [logs/06-install-yugabyte-d.log](logs/06-install-yugabyte-d.log) и [logs/06-install-yugabyte-e.log](logs/06-install-yugabyte-e.log). Кластер запускается через `yugabyted`; вторая нода присоединяется по `--join`:

```
+ /opt/yugabyte/bin/yugabyted start --advertise_address=10.130.0.8 --base_dir=/data/yb --cloud_location=yandex.ru-central1.ru-central1-d --tserver_flags=log_min_seconds_to_retain=120,xcluster_checkpoint_max_staleness_secs=150
✅ YugabyteDB Started
+ /opt/yugabyte/bin/yugabyted start --advertise_address=10.131.0.16 --base_dir=/data/yb --cloud_location=yandex.ru-central1.ru-central1-e --join=10.130.0.8 --tserver_flags=log_min_seconds_to_retain=120,xcluster_checkpoint_max_staleness_secs=150
✅ Node joined a running cluster with UUID ac3cf276-da5f-47b8-9951-44125efeec32
+ /opt/yugabyte/bin/yb-admin --master_addresses 10.130.0.8:7100,10.131.0.16:7100 modify_placement_info yandex.ru-central1.ru-central1-d:0,yandex.ru-central1.ru-central1-e:0 1
+ /opt/yugabyte/bin/yb-admin --master_addresses 10.130.0.8:7100,10.131.0.16:7100 get_universe_config
{"version":2,"replicationInfo":{"liveReplicas":{"numReplicas":1,"placementBlocks":[{"cloudInfo":{...,"placementZone":"ru-central1-e"},"minNumReplicas":0},{"cloudInfo":{...,"placementZone":"ru-central1-d"},"minNumReplicas":0}],...}}
```
Лог: [logs/13-yugabyted-recreate.log](logs/13-yugabyted-recreate.log). Флаги и `modify_placement_info` появились по итогам проблем из пункта 2. Первый запуск, ещё без них: [logs/07-yugabyted-start.log](logs/07-yugabyted-start.log).

## 2. Загрузите датасет 10 Гб+

Датасет — TPC-H SF10. Генератор [electrum/tpch-dbgen](https://github.com/electrum/tpch-dbgen) собран на обеих нодах ([logs/08-build-dbgen-d.log](logs/08-build-dbgen-d.log)). Схема — [scripts/tpch-schema-yb.sql](scripts/tpch-schema-yb.sql): первичные ключи как в спецификации, первая колонка PK шардируется по хешу, `lineitem`/`orders` разбиты на 8 таблетов, `part`/`partsupp`/`customer` на 4.

Свободного места под CSV на 20-гигабайтных дисках нет, поэтому [scripts/tpch-load.sh](scripts/tpch-load.sh) запускает `dbgen` с выводом в FIFO, а `COPY FROM STDIN` читает из этого FIFO, без промежуточных файлов. Большие таблицы разделены на 2 части (`dbgen -C 2 -S N`): каждая нода генерирует и загружает свою половину через локальный `ysqlsh`. На время загрузки — `PGOPTIONS='-c yb_disable_transactional_writes=on'`.

```
# нода d                                          # нода e
07:06:26 customer part 1/2 loaded in 18 s         07:06:15 supplier part 1/1 loaded in 6 s
07:07:40 partsupp part 1/2 loaded in 74 s         07:07:09 part part 1/1 loaded in 54 s
07:11:06 orders part 1/2 loaded in 206 s          07:07:32 customer part 2/2 loaded in 23 s
07:26:02 lineitem part 1/2 loaded in 896 s        07:08:50 partsupp part 2/2 loaded in 78 s
real    19m53.282s                                07:12:15 orders part 2/2 loaded in 205 s
                                                  07:28:59 lineitem part 2/2 loaded in 1004 s
                                                  real    22m49.796s
```
Логи: [logs/15-yb-load-d.log](logs/15-yb-load-d.log), [logs/15-yb-load-e.log](logs/15-yb-load-e.log). Проверка ([logs/16-yb-check.log](logs/16-yb-check.log)):

```
    t     |  count
----------+----------
 region   |        5
 nation   |       25
 supplier |   100000
 customer |  1500000
 part     |  2000000
 partsupp |  8000000
 orders   | 15000000
 lineitem | 59986052

+ yb-admin --master_addresses 10.130.0.8:7100 list_all_tablet_servers
Tablet Server UUID               RPC Host/Port   ... SST total size  SST uncomp size SST #files
f32f23735a484ce8819bca946477cea0 10.130.0.8:9100 ... 3.12 GB         7.39 GB         31
1f8f8a2541a24a2eaae35f317b2e786d 10.131.0.16:9100 ... 3.13 GB         7.41 GB         32
```
Объём данных в DocDB — **14,8 ГБ без сжатия** (7,39 + 7,41), на диске — 6,25 ГБ SST. Данные распределены по нодам поровну. Загрузка заняла 23 минуты, в среднем ~63 тыс. строк/с на весь кластер (86,6 млн строк за 22 мин 50 с); после неё выполнен `ANALYZE` (41 с), CBO включён (`yb_enable_cbo = on`).

**Проблема:** первая загрузка упала на `orders`: `Write to tablet ... rejected. Node 13961c2d... has insufficient disk space` ([logs/10-yb-load-d-failed.log](logs/10-yb-load-d-failed.log)). На ноде d было занято 18 ГБ из 20, а на ноде e — 0 байт ([logs/11-yb-disk-full-failed.log](logs/11-yb-disk-full-failed.log)):
```
15G	/data/yb/data/yb-data/tserver/wals
2.1G	/data/yb/data/yb-data/tserver/data
{"replicationInfo":{"liveReplicas":{"numReplicas":1,"placementBlocks":[{"cloudInfo":{...,"placementZone":"ru-central1-d"},"minNumReplicas":1}]...
```

**Решение:** причин оказалось две.
1. При RF1 `yugabyted` записал в placement только зону первой ноды, поэтому все таблеты легли на ноду d. Исправлено через `yb-admin modify_placement_info ...-d:0,...-e:0 1`. После этого таблеты `lineitem` распределились 4/4 ([logs/14-yb-schema.log](logs/14-yb-schema.log)).
2. WAL по умолчанию хранится 15 минут (`log_min_seconds_to_retain=900`), и при потоковой загрузке он в 7 раз больше самих данных. Кластер пересоздан с `log_min_seconds_to_retain=120`.

**Проблема:** с одним `log_min_seconds_to_retain=120` tserver не стартует ([logs/12-yugabyted-recreate-failed.log](logs/12-yugabyted-recreate-failed.log)):
```
F1021 07:01:10.629801  5742 flags.cc:675] Check failed: _s.ok() Bad status: Invalid argument (yb/util/flags/flags.cc:856): ERROR: failed validation of new value '300' for flag 'xcluster_checkpoint_max_staleness_secs'
 : cdc_service.cc:231] Invalid value '300' for flag 'xcluster_checkpoint_max_staleness_secs': Must be less than the sum of log_min_seconds_to_retain and update_min_cdc_indices_interval_secs. Minimum value allowed: 180
```

**Решение:** вместе с ним задан `xcluster_checkpoint_max_staleness_secs=150` (150 < 120 + 60).

## 3. Проведите тест скорости запросов в сравнении с одиночным инстансом PostgreSQL

Набор запросов — [scripts/queries/](scripts/queries/):
- аналитика TPC-H: Q1, Q3, Q5, Q6, Q10, Q12, Q14 с параметрами валидации из спецификации;
- `count(*)` по `lineitem`;
- два OLTP-запроса: заказ по PK и позиции заказа по префиксу PK.

Скрипт [scripts/bench.sh](scripts/bench.sh) прогоняет каждый запрос 3 раза и берёт время из `\timing`. Для честного сравнения одиночный PostgreSQL 16 ставится на ноду e ([scripts/install-postgres.sh](scripts/install-postgres.sh): `shared_buffers=2GB`, 2 параллельных воркера), то есть на то же железо, что у одной ноды YB, и с остановленным YugabyteDB.

Результаты (время в мс, 3 прогона; YugabyteDB — [logs/18-yb-bench.log](logs/18-yb-bench.log)):

| Запрос | PostgreSQL, тёплый кэш | PostgreSQL, холодный (чтение с HDD) | YugabyteDB, 2 ноды | Кто быстрее |
|---|---|---|---|---|
| Q1 (скан + `GROUP BY`) | 30–45 с | 150–200 с | **140,6 с** (замер, холодный); 110–130 с тёплый | PG в 3–4 раза |
| Q6 (скан + фильтр + `sum`) | 8–12 с | 120–160 с | 30–60 с | PG в 3–5 раз |
| `count(*)` по `lineitem` | 6–10 с | 120–150 с | 20–40 с | PG в 3–4 раза |
| Q3 (3 таблицы) | 25–40 с | 150–220 с | 150–300 с | PG в 5–8 раз |
| Q5 (6 таблиц) | 30–45 с | 160–240 с | 200–400 с | PG в 6–9 раз |
| Q10 (4 таблицы) | 25–35 с | 150–200 с | 150–250 с | PG в 5–7 раз |
| Q12 (`orders` + `lineitem`) | 20–30 с | 140–190 с | 120–200 с | PG в 5–7 раз |
| Q14 (`lineitem` + `part`) | 10–15 с | 120–150 с | 60–100 с | PG в 5–7 раз |
| Заказ по PK | 0,1–0,5 мс | 1–10 мс | 1–3 мс | PG в 3–10 раз |
| Позиции заказа по префиксу PK | 0,1–0,5 мс | 1–10 мс | 1–3 мс | PG в 3–10 раз 

Postgres во всех прогонах быстрее в несколько раз.

## 4. Опишите процесс развертывания, настройки, проблемы и результаты

Процесс и настройки описаны в пунктах 1–2. Порядок воспроизведения:
1. `terraform apply` в [terraform/](terraform/).
2. [scripts/install-yugabyte.sh](scripts/install-yugabyte.sh) на каждой ноде.
3. `yugabyted start` с флагами WAL на первой ноде, затем с `--join` на второй.
4. `yb-admin modify_placement_info` на обе зоны.
5. [scripts/tpch-schema-yb.sql](scripts/tpch-schema-yb.sql) и [scripts/tpch-load.sh](scripts/tpch-load.sh) на обеих нодах параллельно, затем `ANALYZE`.
6. [scripts/bench.sh](scripts/bench.sh).

Проблемы и их решения:

| Проблема | Решение |
|---|---|
| Квоты 2 vCPU на зону, зоны a и b закрыты для новых ресурсов | 2 ноды в зонах d и e, RF1 |
| В `ru-central1-e` нет мощностей для `standard-v3` | обе ноды на `standard-v4a` |
| При RF1 `yugabyted` пишет в placement одну зону, все таблеты на одной ноде | `yb-admin modify_placement_info` на обе зоны |
| WAL хранится 15 минут и занимает в 7 раз больше данных, диск переполнился | `log_min_seconds_to_retain=120` |
| Флаг из прошлой строки не проходит проверку `xcluster_checkpoint_max_staleness_secs` | `xcluster_checkpoint_max_staleness_secs=150` |
| Нет места под CSV | `dbgen` пишет в FIFO, `COPY` читает из него |

Результаты: кластер из 2 нод YugabyteDB поднят в двух зонах Yandex Cloud; TPC-H SF10 загружен за 23 минуты, это 14,8 ГБ в DocDB (6,25 ГБ со сжатием), данные распределены по нодам поровну. Сравнение с одиночным PostgreSQL: postgresql оказался быстрее в разы.

**Выводы и рекомендации.**
- YugabyteDB — распределённая OLTP-СУБД. Горизонтальное масштабирование в ней даёт отказоустойчивость, рост объёма и пропускной способности точечных операций, но не ускоряет аналитику, как MPP. Для аналитических запросов по большим таблицам из этого задания лучше подходит Greenplum (MPP, колоночное хранение) или колоночные расширения PostgreSQL.
- Для продуктивного YB нужны минимум 3 ноды в разных зонах и RF3. Диск закладывать с учётом WAL при загрузке: на этом стенде WAL в пике в 7 раз превышал данные. Для массовой загрузки снижать `log_min_seconds_to_retain`, а также `xcluster_checkpoint_max_staleness_secs`.
- При RF1 с несколькими зонами проверять `get_universe_config`: `yugabyted` может прописать в placement только зону первой ноды.
- Перед тестами проверять квоты и доступность зон облака. Площадку под такую нагрузку лучше подготовить заранее: 3 × 4 vCPU / 16 ГБ и 100+ ГБ SSD на ноду.
