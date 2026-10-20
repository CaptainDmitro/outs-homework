# ДЗ №1. Работа с уровнями изоляции транзакции в PostgreSQL

## 1. Создание проекта

Проект `bananaflow-19980112`. Вместо ВМ в облаке использовал локальную ВМ в UTM на Mac, вместо Ubuntu на ней Debian 11 (4 vCPU, 1 ГБ RAM).

```
$ cat /etc/os-release | head -2; nproc; free -h
PRETTY_NAME="Debian GNU/Linux 11 (bullseye)"
NAME="Debian GNU/Linux"
4
               total        used        free      shared  buff/cache   available
Mem:           974Mi       247Mi       255Mi        26Mi       471Mi       625Mi
```

## 2. Настройка SSH-доступа

Публичный ключ уже лежит в `~/.ssh/authorized_keys` на ВМ. Добавил ключ в агент и подключился к ВМ (первая сессия) ([logs/01-ssh.log](logs/01-ssh.log)):

```
$ ssh-add ~/ai_advent_deploy_key
Identity added: /Users/dmitry/ai_advent_deploy_key (github-actions-deploy)
$ ssh-add -l
256 SHA256:Wkt9J+DjjjKnjfOdzTkGUEN4m5weskGKxqm2iy3Rfnw github-actions-deploy (ED25519)
$ ssh debian@192.168.64.3 'cat ~/.ssh/authorized_keys | cut -c1-60; hostname'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPEERU2K+lfOZQu6Ff9Zn9+W
debian
$ ssh-keygen -y -f ~/ai_advent_deploy_key | cut -c1-60
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPEERU2K+lfOZQu6Ff9Zn9+W
```

## 3. Установка PostgreSQL

Репозиторий PGDG на ВМ уже подключён, поэтому `apt install postgresql` поставил PostgreSQL 18 ([logs/02-apt-install-no-cluster.log](logs/02-apt-install-no-cluster.log)):

```
$ sudo apt install -y postgresql
The following NEW packages will be installed:
  postgresql postgresql-18 postgresql-18-jit postgresql-client-18
...
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory               Log file
16  main    5432 online postgres /mnt/data/postgresql/16/main /var/log/postgresql/postgresql-16-main.log
```

**Проблема:** кластер 18/main после установки не создался, `psql -p 5433` ругается на отсутствие сокета.

**Решение:** на ВМ уже есть кластер PostgreSQL 16 из ДЗ №3 (порт 5432), а скрипт установки (`create_main_cluster` в `/usr/share/postgresql-common/maintscripts-functions`) пропускает создание `main`, если в `/etc/postgresql/` уже есть какой-либо кластер. Создал и запустил его вручную, он занял порт 5433 ([logs/03-createcluster.log](logs/03-createcluster.log)):

```
$ sudo pg_createcluster 18 main --start
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory               Log file
16  main    5432 online postgres /mnt/data/postgresql/16/main /var/log/postgresql/postgresql-16-main.log
18  main    5433 online postgres /var/lib/postgresql/18/main  /var/log/postgresql/postgresql-18-main.log
$ sudo -u postgres psql -p 5433 -c 'select version();'
 PostgreSQL 18.6 (Debian 18.6-1.pgdg11+2) on aarch64-unknown-linux-gnu, ...
```

## 4. Подключение к PostgreSQL

Открыл две SSH-сессии и в каждой запустил `psql` от имени `postgres`:

```bash
ssh -tt debian@192.168.64.3 'sudo -u postgres psql -p 5433 -P pager=off'
```

Команды в сессии подавались по очереди из скрипта, порядок записан в [logs/06-order.log](logs/06-order.log). Полный вывод сессий: [logs/04-session1.log](logs/04-session1.log) (сессия 1) и [logs/05-session2.log](logs/05-session2.log) (сессия 2). Длинные команды readline в логах обрезает до `<...`, полный текст есть в `06-order.log`.

```
psql (18.6 (Debian 18.6-1.pgdg11+2))
Type "help" for help.

postgres=#
```

## 5. Работа с транзакциями

Выключил автокоммит в обеих сессиях:

```
postgres=# \set AUTOCOMMIT off
postgres=# \echo :AUTOCOMMIT
off
```

Сессия 1, создание таблицы и данных:

```
postgres=# create table shipments(id serial, product_name text, quantity int, destination text);
CREATE TABLE
postgres=*# insert into shipments(product_name, quantity, destination) values('bananas', 1000, 'Europe');
INSERT 0 1
postgres=*# insert into shipments(product_name, quantity, destination) values('coffee', 500, 'USA');
INSERT 0 1
postgres=*# commit;
COMMIT
```

Звёздочка в приглашении `=*#` показывает, что при выключенном автокоммите psql сам открыл транзакцию.

## 6. Изучение уровней изоляции

Текущий уровень изоляции в обеих сессиях `read committed` (по умолчанию). `show` при выключенном автокоммите открывает транзакцию, поэтому завершил её `commit` и начал новую в обеих сессиях:

```
postgres=# show transaction isolation level;
 transaction_isolation
-----------------------
 read committed
(1 row)

postgres=*# commit;
COMMIT
postgres=# begin;
BEGIN
```

Сессия 1:

```
postgres=*# insert into shipments(product_name, quantity, destination) values('sugar', 300, 'Asia');
INSERT 0 1
```

Сессия 2:

```
postgres=*# select * from shipments;
 id | product_name | quantity | destination
----+--------------+----------+-------------
  1 | bananas      |     1000 | Europe
  2 | coffee       |      500 | USA
(2 rows)
```

Новой записи нет. Транзакция сессии 1 ещё не зафиксирована, а PostgreSQL ни на одном уровне не показывает чужие незафиксированные изменения (грязного чтения нет).

Сессия 1 выполнила `commit;`, затем сессия 2 снова:

```
postgres=*# select * from shipments;
 id | product_name | quantity | destination
----+--------------+----------+-------------
  1 | bananas      |     1000 | Europe
  2 | coffee       |      500 | USA
  3 | sugar        |      300 | Asia
(3 rows)
```

Теперь запись `sugar` видна, хотя транзакция сессии 2 та же самая. В `read committed` снимок данных берётся заново перед каждым запросом, поэтому второй `select` видит всё, что зафиксировано к его началу (неповторяющееся чтение / фантом допустимы).

## 7. Эксперименты с уровнем изоляции Repeatable Read

Сессия 2 завершила предыдущую транзакцию `commit;`. В обеих сессиях начал транзакции с уровнем `repeatable read`:

```
postgres=# begin;
BEGIN
postgres=*# set transaction isolation level repeatable read;
SET
postgres=*# show transaction isolation level;
 transaction_isolation
-----------------------
 repeatable read
(1 row)
```

Сессия 1:

```
postgres=*# insert into shipments(product_name, quantity, destination) values('bananas', 2000, 'Africa');
INSERT 0 1
```

Сессия 2:

```
postgres=*# select * from shipments;
 id | product_name | quantity | destination
----+--------------+----------+-------------
  1 | bananas      |     1000 | Europe
  2 | coffee       |      500 | USA
  3 | sugar        |      300 | Asia
(3 rows)
```

Новой записи нет: транзакция сессии 1 не зафиксирована.

Сессия 1 выполнила `commit;`, сессия 2 снова:

```
postgres=*# select * from shipments;
 id | product_name | quantity | destination
----+--------------+----------+-------------
  1 | bananas      |     1000 | Europe
  2 | coffee       |      500 | USA
  3 | sugar        |      300 | Asia
(3 rows)
```

Запись по-прежнему не видна, хотя уже зафиксирована. В `repeatable read` снимок берётся один раз, при первом запросе транзакции, и действует до её конца. Первый `select` сессии 2 выполнился до коммита сессии 1, поэтому строки `Africa` в снимке нет. В PostgreSQL этот уровень защищает и от неповторяющегося чтения, и от фантомов.

Сессия 2 завершила транзакцию и снова выполнила запрос:

```
postgres=*# commit;
COMMIT
postgres=# select * from shipments;
 id | product_name | quantity | destination
----+--------------+----------+-------------
  1 | bananas      |     1000 | Europe
  2 | coffee       |      500 | USA
  3 | sugar        |      300 | Asia
  4 | bananas      |     2000 | Africa
(4 rows)
```

Запись видна: `select` выполнился в новой транзакции (уровень снова `read committed` по умолчанию) с новым снимком, в который попали все зафиксированные к этому моменту изменения.
