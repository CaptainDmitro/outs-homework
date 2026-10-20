# ДЗ №7. PostgreSQL в Minikube

## Подготовка. Установить и запустить Minikube, убедиться, что установлены kubectl и psql

Стенд: тот же VDS, что в ДЗ №4–6 (Ubuntu 24.04, 4 vCPU, 8 ГБ RAM). LXD-контейнеры и PostgreSQL из прошлых ДЗ с него удалены.

Установка Docker (драйвер для Minikube), клиента psql, Minikube и kubectl ([logs/01-prepare.log](logs/01-prepare.log)):

```bash
sudo apt-get install -y -q docker.io postgresql-client curl
sudo usermod -aG docker $USER
curl -sLo /tmp/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install /tmp/minikube /usr/local/bin/minikube
curl -sLo /tmp/kubectl "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install /tmp/kubectl /usr/local/bin/kubectl
```

```
$ docker --version; minikube version; kubectl version --client; psql --version
Docker version 29.1.3, build 29.1.3-0ubuntu3~24.04.2
minikube version: v1.39.0
Client Version: v1.37.1
psql (PostgreSQL) 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
```

Запуск кластера ([logs/02-minikube-start.log](logs/02-minikube-start.log)):

```
$ minikube start --driver=docker --cpus=2 --memory=4g
* minikube v1.39.0 on Ubuntu 24.04 (amd64)
* Using the docker driver based on user configuration
...
* Done! kubectl is now configured to use "minikube" cluster and "default" namespace by default

$ kubectl get nodes -o wide
NAME       STATUS     ROLES           AGE   VERSION   INTERNAL-IP    ...   CONTAINER-RUNTIME
minikube   NotReady   control-plane   5s    v1.37.0   192.168.49.2   ...   containerd://2.3.4
```

Узел в `NotReady` только первые секунды, пока поднимается CNI; через полминуты в нём уже работает под PostgreSQL (шаг 1).

## Шаг 1. Развернуть PostgreSQL через манифест

Манифест [postgres.yaml](postgres.yaml): Deployment `postgres` с образом `postgres:14`, Service `postgres` (ClusterIP, 5432) и PVC на 1 ГБ под данные. Пользователь и пароль заданы переменными окружения в Deployment:

```yaml
          env:
            - name: POSTGRES_USER
              value: banana
            - name: POSTGRES_PASSWORD
              value: otus_pass
            - name: POSTGRES_DB
              value: logistics
```

Применение и проверка через `kubectl port-forward` + `psql` ([logs/03-manifest.log](logs/03-manifest.log)). Пароль psql берёт из `~/.pgpass`, поэтому в логе его нет:

```
$ kubectl apply -f postgres.yaml
persistentvolumeclaim/postgres-data created
deployment.apps/postgres created
service/postgres created

$ kubectl rollout status deployment/postgres --timeout=180s
deployment "postgres" successfully rolled out

$ kubectl get deploy,svc,pvc,pods -l app=postgres -o wide
NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE
pod/postgres-74cb65b865-b28dm   1/1     Running   0          30s   10.244.0.3   minikube

$ kubectl get svc postgres
NAME       TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
postgres   ClusterIP   10.98.155.58   <none>        5432/TCP   33s

$ kubectl port-forward svc/postgres 15432:5432 &
$ psql -h localhost -p 15432 -U banana -d logistics -c 'select version();'
                                                       version
----------------------------------------------------------------------------------------------------------------------
 PostgreSQL 14.24 (Debian 14.24-1.pgdg13+2) on x86_64-pc-linux-gnu, compiled by gcc (Debian 14.2.0-19) 14.2.0, 64-bit
(1 row)

$ psql -h localhost -p 15432 -U banana -d logistics
create table shipments(id serial primary key, port text, tons int);
insert into shipments(port, tons) values ('Brisbane', 300), ('Sydney', 300), ('Melbourne', 120);
select * from shipments;
 id |   port    | tons
----+-----------+------
  1 | Brisbane  |  300
  2 | Sydney    |  300
  3 | Melbourne |  120
(3 rows)
```

## Шаг 2. Развернуть PostgreSQL через Helm

Установка Helm ([logs/04-helm-install.log](logs/04-helm-install.log)):

```
$ curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm installed into /usr/local/bin/helm
$ helm version
version.BuildInfo{Version:"v3.22.1", ...}
```

Чарт Bitnami PostgreSQL с PostgreSQL 14 — ветка 11.x, последняя версия 11.9.13:

```
$ helm show chart oci://registry-1.docker.io/bitnamicharts/postgresql --version 11.9.13 | grep -E '^(appVersion|version)'
appVersion: 14.5.0
version: 11.9.13
```

**Проблема:** чарт ссылается на образ `docker.io/bitnami/postgresql:14.5.0-debian-11-r35`, а Bitnami убрал старые теги из репозитория `bitnami` (в 2025 году их перенесли в `bitnamilegacy`). С образом по умолчанию поды остались бы в `ImagePullBackOff`.

**Решение:** проверил наличие тега в обоих репозиториях и переопределил `image.repository` в `values.yaml` ([logs/05-helm-postgres.log](logs/05-helm-postgres.log)):

```
$ docker manifest inspect docker.io/bitnami/postgresql:14.5.0-debian-11-r35 >/dev/null; echo "bitnami: exit $?"
no such manifest: docker.io/bitnami/postgresql:14.5.0-debian-11-r35
bitnami: exit 1
$ docker manifest inspect docker.io/bitnamilegacy/postgresql:14.5.0-debian-11-r35 >/dev/null; echo "bitnamilegacy: exit $?"
bitnamilegacy: exit 0
```

Параметры подключения и масштабирование в [values.yaml](values.yaml): `architecture: replication`. Primary и read-реплики разворачиваются как StatefulSet'ы с потоковой репликацией, на старте одна реплика:

```yaml
auth:
  username: banana
  password: otus_pass
  database: logistics
  postgresPassword: otus_pass
  replicationUsername: repl_user
  replicationPassword: otus_pass

architecture: replication

readReplicas:
  replicaCount: 1
```

Установка в namespace `bananaflow` и проверка ([logs/05-helm-postgres.log](logs/05-helm-postgres.log)):

```
$ helm install pg oci://registry-1.docker.io/bitnamicharts/postgresql --version 11.9.13 -n bananaflow --create-namespace -f values.yaml --wait --timeout 10m
NAME: pg
NAMESPACE: bananaflow
STATUS: deployed
REVISION: 1
CHART VERSION: 11.9.13
APP VERSION: 14.5.0

$ kubectl get statefulset,svc,pvc,pods -n bananaflow -o wide
...
NAME                                     READY   AGE
statefulset.apps/pg-postgresql-primary   1/1     47s
statefulset.apps/pg-postgresql-read      1/1     47s

NAME                          READY   STATUS    RESTARTS   AGE
pod/pg-postgresql-primary-0   1/1     Running   0          47s
pod/pg-postgresql-read-0      1/1     Running   0          47s

$ kubectl port-forward -n bananaflow svc/pg-postgresql-primary 15433:5432 &
$ psql -h localhost -p 15433 -U banana -d logistics
select version();
 PostgreSQL 14.5 on x86_64-pc-linux-gnu, compiled by gcc (Debian 10.2.1-6) 10.2.1 20210110, 64-bit

create table shipments(id serial primary key, port text, tons int);
insert into shipments(port, tons) values ('Brisbane', 300), ('Sydney', 300), ('Melbourne', 120);
select * from shipments;
 id |   port    | tons
----+-----------+------
  1 | Brisbane  |  300
  2 | Sydney    |  300
  3 | Melbourne |  120
(3 rows)
```

## Кризисный момент. Увеличить количество подов до 3 и убедиться, что все в статусе Running

Добавил вторую read-реплику, итого 3 пода ([logs/06-scale.log](logs/06-scale.log)):

```
$ helm upgrade pg oci://registry-1.docker.io/bitnamicharts/postgresql --version 11.9.13 -n bananaflow -f values.yaml --set readReplicas.replicaCount=2 --wait --timeout 10m
Release "pg" has been upgraded. Happy Helming!
REVISION: 2

$ kubectl get statefulset -n bananaflow
NAME                    READY   AGE
pg-postgresql-primary   1/1     86s
pg-postgresql-read      2/2     86s

$ psql -h localhost -p 15433 -U postgres -d logistics -c 'select client_addr, application_name, state, sync_state from pg_stat_replication;'
 client_addr | application_name |   state   | sync_state
-------------+------------------+-----------+------------
 10.244.0.4  | my_application   | streaming | async
 10.244.0.6  | my_application   | streaming | async
(2 rows)
```

**Проблема:** при проверке реплик по очереди `kill %1` не остановил port-forward к `read-0` (номер фонового задания уже был другим: `kill: %1: no such job`). Порт 15434 остался занят, и запрос «к `read-1`» на самом деле ушёл снова в `read-0`.

**Решение:** запоминать PID через `pf=$!` и останавливать именно его (`kill $pf; wait $pf`). Повторная проверка: обе реплики в режиме recovery и отдают данные, записанные на primary ([logs/07-replicas-check.log](logs/07-replicas-check.log)):

```
$ kubectl port-forward -n bananaflow pod/pg-postgresql-read-0 15434:5432 &
$ psql -h localhost -p 15434 -U banana -d logistics -c 'select inet_server_addr(), pg_is_in_recovery(), * from shipments;'
 inet_server_addr | pg_is_in_recovery | id |   port    | tons
------------------+-------------------+----+-----------+------
 127.0.0.1        | t                 |  1 | Brisbane  |  300
 127.0.0.1        | t                 |  2 | Sydney    |  300
 127.0.0.1        | t                 |  3 | Melbourne |  120
(3 rows)

$ kubectl port-forward -n bananaflow pod/pg-postgresql-read-1 15434:5432 &
$ psql -h localhost -p 15434 -U banana -d logistics -c 'select inet_server_addr(), pg_is_in_recovery(), * from shipments;'
 inet_server_addr | pg_is_in_recovery | id |   port    | tons
------------------+-------------------+----+-----------+------
 127.0.0.1        | t                 |  1 | Brisbane  |  300
 127.0.0.1        | t                 |  2 | Sydney    |  300
 127.0.0.1        | t                 |  3 | Melbourne |  120
(3 rows)

$ kubectl get pods -n bananaflow
NAME                      READY   STATUS    RESTARTS   AGE
pg-postgresql-primary-0   1/1     Running   0          117s
pg-postgresql-read-0      1/1     Running   0          117s
pg-postgresql-read-1      1/1     Running   0          53s
```

Все 3 пода PostgreSQL 14 в статусе Running: 1 primary и 2 потоковые реплики.
