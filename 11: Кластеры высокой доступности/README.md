# ДЗ №11. Кластеры высокой доступности

## 1. HA-кластер PostgreSQL в облаке (вариант 2: Yandex Cloud Compute, Patroni + etcd + HAProxy)

Стек: PostgreSQL 16, Patroni 3.2, etcd 3.4, HAProxy 2.8 из репозиториев Ubuntu 24.04, всё развёрнуто вручную на ВМ Yandex Cloud Compute.

Квоты облака дают только 2 vCPU на зону, а минимальная ВМ `standard-v3` уже занимает 2 vCPU. Поэтому в каждой зоне одна ВМ, а три узла кластера на ней работают как Docker-контейнеры: в каждом etcd, Patroni и PostgreSQL. Отказ узла имитируется остановкой контейнера, отказ зоны остановкой ВМ.

**Архитектура:**

- `pg-d` (ru-central1-d, 10.130.0.10): основной кластер Patroni `bananaflow-d`: `node1..3` (etcd-кластер из трёх членов, Patroni, PostgreSQL) и `haproxy`. HAProxy на `:5432` ведёт на текущего лидера (проверка `OPTIONS /primary` на REST API Patroni `:8008`), на `:8404/health` отвечает `200`, если лидер на запись есть, иначе `503`.
- `pg-e` (ru-central1-e, 10.131.0.10): standby-кластер Patroni `bananaflow-e` с той же структурой и своим etcd. Его standby-лидер реплицируется напрямую с узлов `pg-d` (порты ВМ 5441–5443), а свои реплики каскадом идут от него.
- Сетевой балансировщик Yandex NLB `pg-nlb` (публичный адрес 46.243.210.86, порт 5432) с целевой группой из обеих ВМ и проверкой `HTTP :8404/health`. Трафик идёт только на ту площадку, где есть лидер на запись.
- Приватная зона Cloud DNS `bananaflow.internal`: запись `pg.bananaflow.internal` указывает на адрес балансировщика, клиенты в VPC подключаются по имени.

**Развёртывание.** Вся инфраструктура описана в [terraform/](terraform/), конфигурация узлов в [docker/](docker/): [Dockerfile](docker/Dockerfile), [entrypoint.sh](docker/entrypoint.sh), [patroni.yml.tftpl](docker/patroni.yml.tftpl), [haproxy.cfg](docker/haproxy.cfg), [compose.yaml.tftpl](docker/compose.yaml.tftpl). Terraform передаёт эти файлы в cloud-init, а cloud-init на каждой ВМ ставит Docker, собирает образ и запускает `docker compose up -d`. На площадке `e` в bootstrap-конфигурации Patroni дополнительно есть секция `standby_cluster`.

```bash
cd terraform
YC_TOKEN=$(yc iam create-token) terraform apply
```

Через 5–6 минут оба кластера готовы ([logs/24-terraform-apply.log](logs/24-terraform-apply.log)):

```
Apply complete! Resources: 2 added, 0 changed, 2 destroyed.
pg_endpoint = "pg.bananaflow.internal:5432 -> 46.243.210.86"
public_ips = {
  "pg-d" = "178.154.211.162"
  "pg-e" = "153.51.119.19"
}
```

Состояние основного кластера ([logs/25-clusters-status.log](logs/25-clusters-status.log)):

```
+ sudo docker exec node1 patronictl -c /etc/patroni.yml list
+ Cluster: bananaflow-d (7698852953298616353) ----+-----------+
| Member | Host        | Role    | State     | TL | Lag in MB |
+--------+-------------+---------+-----------+----+-----------+
| node1  | 172.20.0.11 | Leader  | running   |  1 |           |
| node2  | 172.20.0.12 | Replica | streaming |  1 |         0 |
| node3  | 172.20.0.13 | Replica | streaming |  1 |         0 |
+--------+-------------+---------+-----------+----+-----------+
+ sudo docker exec node1 etcdctl --endpoints=172.20.0.11:2379 member list -w table
| 16630e3843e090fd | started | node3 | http://172.20.0.13:2380 | http://172.20.0.13:2379 |      false |
| 9007172cf1537b98 | started | node1 | http://172.20.0.11:2380 | http://172.20.0.11:2379 |      false |
| 9c4c7ee7febca8c8 | started | node2 | http://172.20.0.12:2380 | http://172.20.0.12:2379 |      false |
+ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8404/health
200
```

Тестовая БД создаётся на лидере через HAProxy, затем проверено подключение с Mac через балансировщик ([logs/26-create-db.log](logs/26-create-db.log)):

```
CREATE ROLE
CREATE DATABASE
CREATE TABLE

$ PGPASSWORD=banana_pass_11 psql -h 46.243.210.86 -U banana -d bananaflow -XAt -c "select current_setting('cluster_name'), inet_server_addr(), pg_is_in_recovery(), version()"
bananaflow-d|172.20.0.11|f|PostgreSQL 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1) on x86_64-pc-linux-gnu, ...
```

**Проблема:** ВМ в `ru-central1-a` не создалась: `Zone ru-central1-a is not available` ([logs/01-terraform-apply-failed.log](logs/01-terraform-apply-failed.log)). Затем то же случилось с `ru-central1-b` ([logs/02-terraform-apply-failed.log](logs/02-terraform-apply-failed.log)), а подсеть в `ru-central1-k` создать не удалось.

**Решение:** для этого облака доступны только зоны `d` и `e`, поэтому площадки разнесены по ним. Отдельной клиентской ВМ места не осталось, и тестовый клиент запускается с Mac (см. п. 4).

**Проблема:** первая сборка упала с `failed to solve: image "docker.io/library/patroni-etcd:16": already exists` ([logs/05-cloud-init-pg-d-failed.log](logs/05-cloud-init-pg-d-failed.log)): три сервиса compose с одинаковыми `build` и `image` собирали образ параллельно.

**Решение:** образ собирается отдельной командой `docker build -t patroni-etcd:16 .`, а в compose осталось только `image`.

**Проблема:** на одной из ВМ не установились пакеты: `Failure when attempting to install packages` после `Waiting for APT lock` ([logs/10-cloud-init-pg-d-apt-lock-failed.log](logs/10-cloud-init-pg-d-apt-lock-failed.log)). Блокировку держал `unattended-upgrades`, а модуль `packages` в cloud-init ждёт её только 30 с.

**Решение:** установка перенесена в `runcmd` с `apt-get -o DPkg::Lock::Timeout=600`.

## 2. Автоматический failover

Пока с Mac работает [ha-test.sh](ha-test.sh) (раз в секунду вставляет строку через балансировщик и печатает id, кластер и адрес узла), на `pg-d` убит контейнер лидера ([logs/27-failover-node.log](logs/27-failover-node.log)):

```
+ date +%T
20:42:56
+ sudo docker kill node1
node1
+ sleep 45
+ sudo docker exec node2 patronictl -c /etc/patroni.yml list
| node2  | 172.20.0.12 | Replica | streaming |  2 |         0 |
| node3  | 172.20.0.13 | Leader  | running   |  2 |           |
+ sudo docker exec node2 patronictl -c /etc/patroni.yml history
|  1 | 88284672 | no recovery target specified | 2026-10-20T20:43:31.748047+00:00 | node3      |
2026-10-20 20:43:31.606 UTC [54] LOG:  received promote request
2026-10-20 20:43:32,811 INFO: no action. I am (node3), the leader with the lock
...
+ sudo docker start node1
+ sleep 30
+ sudo docker exec node2 patronictl -c /etc/patroni.yml list
| node1  | 172.20.0.11 | Replica | running   |  1 |         0 |
| node2  | 172.20.0.12 | Replica | streaming |  2 |         0 |
| node3  | 172.20.0.13 | Leader  | running   |  2 |           |
```

Patroni сам повысил `node3` через 35 с (TTL блокировки лидера 30 с), а вернувшийся `node1` подключился как реплика. Клиент ([logs/28-ha-test.log](logs/28-ha-test.log), время UTC) не мог писать 46 с: отказ, выборы и подъём проверок HAProxy и NLB.

```
20:42:56 5|bananaflow-d|172.20.0.11
20:43:00 psql: error: connection to server at "46.243.210.86", port 5432 failed: timeout expired
...
20:43:41 psql: error: connection to server at "46.243.210.86", port 5432 failed: timeout expired
20:43:42 34|bananaflow-d|172.20.0.13
20:43:44 35|bananaflow-d|172.20.0.13
```

Скачок id с 5 на 34 появился из-за кэша последовательности: новый лидер продолжает с значения, уже записанного в WAL с запасом в 32.

## 3. Два кластера в разных зонах: Patroni HA и Standby, репликация

Standby-кластер в `ru-central1-e` создаётся Patroni из bootstrap-секции `standby_cluster`. Его лидер реплицируется напрямую с узлов основного кластера, а реплики `pg-e` каскадом идут от своего лидера ([logs/25-clusters-status.log](logs/25-clusters-status.log)):

```
+ sudo docker exec node1 patronictl -c /etc/patroni.yml list
+ Cluster: bananaflow-e (7698852953298616353) ------+----+-----------+
| Member | Host        | Role           | State     | TL | Lag in MB |
+--------+-------------+----------------+-----------+----+-----------+
| node1  | 172.20.0.11 | Replica        | streaming |  1 |         0 |
| node2  | 172.20.0.12 | Standby Leader | streaming |  1 |           |
| node3  | 172.20.0.13 | Replica        | streaming |  1 |         0 |
+--------+-------------+----------------+-----------+----+-----------+
+ sudo docker exec node1 patronictl -c /etc/patroni.yml show-config
...
standby_cluster:
  create_replica_methods:
  - basebackup
  host: 10.130.0.10,10.130.0.10,10.130.0.10
  port: 5441,5442,5443
ttl: 30
+ sudo docker exec node2 psql -h /var/run/postgresql -U postgres -XAt -c 'show primary_conninfo' -c 'select pg_is_in_recovery(), status, received_tli, sender_host, sender_port from pg_stat_wal_receiver'
user=replicator passfile=/tmp/pgpass host=10.130.0.10,10.130.0.10,10.130.0.10 port=5441,5442,5443 sslmode=prefer application_name=node2 gssencmode=prefer channel_binding=prefer
t|streaming|1|10.130.0.10|5441
```

Системный идентификатор у обоих кластеров один (`7698852953298616353`), то есть это физическая копия основного кластера.

При отказе узла в основном кластере (п. 2) standby сразу переподключился к следующему узлу из списка, сам перешёл на таймлайн 2 и догнал данные: `max(id)` равен последнему значению у клиента ([logs/27-failover-node.log](logs/27-failover-node.log)):

```
2026-10-20 20:42:56.958 UTC [67] FATAL:  could not receive data from WAL stream: server closed the connection unexpectedly
2026-10-20 20:42:57.016 UTC [157] LOG:  started streaming WAL from primary at 0/5000000 on timeline 1
2026-10-20 20:43:37.306 UTC [157] LOG:  replication terminated by primary server
2026-10-20 20:43:37.311 UTC [157] LOG:  fetching timeline history file for timeline 2 from primary server
2026-10-20 20:43:37.322 UTC [66] LOG:  new target timeline is 2
2026-10-20 20:43:37.331 UTC [157] LOG:  restarted WAL streaming at 0/5000000 on timeline 2
streaming|2|10.130.0.10|5442
56
```

**Проблема:** сначала standby-кластер ходил за WAL через HAProxy основного кластера (`10.130.0.10:5000`), и basebackup не стартовал: соединение с `10.130.0.10:5000` из `pg-e` зависало, а другие порты отвечали ([logs/07-standby-port5000-failed.log](logs/07-standby-port5000-failed.log)). tcpdump показал, что `pg-d` отвечает SYN-ACK, а в ответ приходит RST.

**Решение:** порт 5000 был target-портом балансировщика, а NLB перехватывает трафик на этот порт целевых ВМ, даже если он идёт напрямую между ВМ. Порты разведены: NLB → `:5432` HAProxy, репликация на других портах.

**Проблема:** после failover внутри основного кластера standby переставал получать WAL. В итоге при отказе площадки потерялись строки, записанные после первого failover: в `pg-e` после промоута были только id 1–4, а новые строки снова начались с 34 ([logs/19-standby-timeline-failed.log](logs/19-standby-timeline-failed.log)). Заодно в логах standby было `no pg_hba.conf entry for replication connection from host "127.0.0.1"`: Patroni не мог прочитать локальный таймлайн.

**Решение:** в `pg_hba` добавлено `host replication replicator 127.0.0.1/32`. Основная причина нашлась позже. Walreceiver подключался к HAProxy в ту же секунду, когда умирал лидер. HAProxy отдавал соединение уже мёртвому серверу, серверная сторона закрывалась, а клиентская оставалась открытой без таймеров ([logs/21-standby-walreceiver-hang-failed.log](logs/21-standby-walreceiver-hang-failed.log), [logs/23b-haproxy-stuck-session-failed.log](logs/23b-haproxy-stuck-session-failed.log)):

```
0x60e03fe3c9b0: [20/Oct/2026:20:21:41.739559] id=46 proto=tcpv4 source=10.131.0.10:49010
  flags=0x2900a, conn_retries=2, conn_exp=<NEVER> ...
  server=node1 (id=1) addr=172.20.0.11:5432
  scf=... state=EST ... rex=<NEVER> wex=<NEVER>
  scb=... state=CLO ...
```

Walreceiver подключается асинхронно и не ограничивает время подключения (`connect_timeout`/`PGCONNECT_TIMEOUT` он не соблюдает, [logs/23-failover-node-walreceiver-hang-failed.log](logs/23-failover-node-walreceiver-hang-failed.log)), поэтому ждал ответа вечно. Не помогли ни отдельный listener с `timeout client 30s`, `timeout queue` и `option redispatch`, ни HAProxy 3.0 ([logs/23b-haproxy-stuck-session-failed.log](logs/23b-haproxy-stuck-session-failed.log)). Поэтому HAProxy убран из пути репликации: порты узлов `pg-d` опубликованы как 5441–5443, а в `standby_cluster` указан список хостов и портов libpq. Упавший узел сразу даёт `Connection refused`, и walreceiver переходит к следующему. Строку `/tmp/pgpass`, которую пишет Patroni, libpq не сопоставляет с парами хост:порт из списка, поэтому пароль репликации передан через `PGPASSWORD` в окружении узлов.

## 4. Отказоустойчивый DNS / балансировщик

Точка входа для клиентов: Yandex NLB `pg-nlb` перед HAProxy обеих площадок и запись `pg.bananaflow.internal` в приватной зоне Cloud DNS ([terraform/main.tf](terraform/main.tf)). Проверка `HTTP :8404/health` пропускает трафик только туда, где HAProxy видит лидера на запись. В исходном состоянии ([logs/25-clusters-status.log](logs/25-clusters-status.log)):

```
### pg-e (ru-central1-e): standby-кластер
+ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8404/health
503
+ dig +short pg.bananaflow.internal
46.243.210.86

$ yc load-balancer network-load-balancer target-states pg-nlb --target-group-id enp6o5l1lj9ou6q388qk
+----------------------+-------------+-----------+
|      SUBNET ID       |   ADDRESS   |  STATUS   |
+----------------------+-------------+-----------+
| ajcd2bbrfbagcv6p73t1 | 10.131.0.10 | UNHEALTHY |
| fl8cjtnhpo4im199nvpg | 10.130.0.10 | HEALTHY   |
+----------------------+-------------+-----------+
```

**Проблема:** сначала балансировщик был внутренним (10.131.0.100), а клиент работал на `pg-e` по имени `pg.bananaflow.internal`. После переключения трафика на `pg-e` NLB показывал её `HEALTHY`, но клиент так и не подключился ([logs/16a-failover-site-hairpin-failed.log](logs/16a-failover-site-hairpin-failed.log), [logs/16b-ha-test-hairpin-failed.log](logs/16b-ha-test-hairpin-failed.log)):

```
19:38:17 psql: error: connection to server at "pg.bananaflow.internal" (10.131.0.100), port 5432 failed: timeout expired
19:38:20 psql: error: connection to server at "pg.bananaflow.internal" (10.131.0.100), port 5432 failed: timeout expired
```

**Решение:** NLB не доставляет трафик целевой ВМ, если она сама и есть клиент (hairpin). Третью ВМ для клиента квоты не дают, поэтому NLB сделан внешним, а клиент запускается с Mac по публичному адресу балансировщика. Запись в приватной DNS-зоне указывает на тот же адрес и нужна клиентам внутри VPC.

## 5. Отказ одного из кластеров и переключение трафика

С Mac по-прежнему работает [ha-test.sh](ha-test.sh). Отказ зоны `d` имитируется остановкой ВМ `pg-d`, после чего standby-кластер повышается командой Patroni: удаляется секция `standby_cluster` из конфигурации в DCS. Повышение standby-кластера Patroni намеренно не делает сам, чтобы не получить два лидера при разрыве сети между зонами. Трафик переключает NLB автоматически ([logs/29-failover-site.log](logs/29-failover-site.log), время UTC):

```
### pg-e: перед отказом
streaming|2|5442
63

### Mac
$ yc compute instance stop pg-d
20:44:30
20:44:59
$ yc load-balancer network-load-balancer target-states pg-nlb --target-group-id enp6o5l1lj9ou6q388qk
| ajcd2bbrfbagcv6p73t1 | 10.131.0.10 | UNHEALTHY |
| fl8cjtnhpo4im199nvpg | 10.130.0.10 | UNHEALTHY |

### pg-e
+ sudo docker exec node1 patronictl -c /etc/patroni.yml list
| node2  | 172.20.0.12 | Standby Leader | running   |  1 |           |
+ sudo docker exec node2 psql -h /var/run/postgresql -U postgres -d bananaflow -XAt -c 'select max(id) from ha_test'
68
+ sudo docker exec node1 patronictl -c /etc/patroni.yml edit-config --force -s standby_cluster=null
-standby_cluster:
-  create_replica_methods:
-  - basebackup
-  host: 10.130.0.10,10.130.0.10,10.130.0.10
-  port: 5441,5442,5443
Configuration changed
+ sleep 20
+ sudo docker exec node1 patronictl -c /etc/patroni.yml list
| node1  | 172.20.0.11 | Replica | streaming |  3 |         0 |
| node2  | 172.20.0.12 | Leader  | running   |  3 |           |
| node3  | 172.20.0.13 | Replica | streaming |  3 |         0 |
+ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8404/health
200

$ yc load-balancer network-load-balancer target-states pg-nlb --target-group-id enp6o5l1lj9ou6q388qk
20:45:28
| ajcd2bbrfbagcv6p73t1 | 10.131.0.10 | HEALTHY   |
| fl8cjtnhpo4im199nvpg | 10.130.0.10 | UNHEALTHY |
```

Клиент ([logs/28-ha-test.log](logs/28-ha-test.log)) с прежним адресом без изменений продолжил писать уже в кластер `bananaflow-e`:

```
20:44:37 68|bananaflow-d|172.20.0.13
20:44:40 psql: error: connection to server at "46.243.210.86", port 5432 failed: server closed the connection unexpectedly
...
20:45:18 psql: error: connection to server at "46.243.210.86", port 5432 failed: timeout expired
20:45:21 100|bananaflow-e|172.20.0.12
20:45:22 101|bananaflow-e|172.20.0.12
```

Сверка после переключения: все 40 строк, которые клиент успел записать в основной кластер (id 1–68), есть в новом, потерь нет:

```
cluster|count|min|max|first|last
bananaflow-d|40|1|68|20:42:51|20:44:37
bananaflow-e|21|100|120|20:45:21|20:45:55
```

Итог: при отказе зоны `ru-central1-d` запись через тот же адрес восстановилась через 44 с, включая ручное повышение standby-кластера, без потери подтверждённых данных.
