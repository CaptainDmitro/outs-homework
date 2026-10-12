# ДЗ №3. Спасение данных на внешнем диске

## 1. Виртуальная машина и установка PostgreSQL 15+

Использовал локальную ВМ в UTM с Debian 11 (arm64) вместо Ubuntu 20.04. Подключение: `ssh debian@192.168.64.3`. Установил PostgreSQL 16 из репозитория PGDG ([logs/02-pg-install.log](logs/02-pg-install.log)):

```bash
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt-archive.postgresql.org/pub/repos/apt bullseye-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update
sudo apt-get install -y postgresql-16
```

```
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory              Log file
16  main    5432 online postgres /var/lib/postgresql/16/main /var/log/postgresql/postgresql-16-main.log
```

## 2. Таблица с данными о перевозках

Создал базу `logistics` и таблицу `shipments` ([shipments.sql](shipments.sql), [logs/03-shipments.log](logs/03-shipments.log)):

```bash
sudo -u postgres psql -c "CREATE DATABASE logistics"
sudo -u postgres psql -d logistics -v ON_ERROR_STOP=1 -f - <<'SQL'
...   # содержимое shipments.sql
SQL
```

```
CREATE DATABASE
CREATE TABLE
INSERT 0 5
```

```
$ sudo -u postgres psql -d logistics -c "SELECT * FROM shipments ORDER BY id"
 id | product_name | quantity |  destination  |          shipped_at
----+--------------+----------+---------------+-------------------------------
  1 | Bananas      |     1000 | Europe        | 2026-10-12 10:10:11.916876-07
  2 | Apples       |      500 | Asia          | 2026-10-12 10:10:11.916876-07
  3 | Oranges      |      750 | Africa        | 2026-10-12 10:10:11.916876-07
  4 | Mangoes      |      300 | South America | 2026-10-12 10:10:11.916876-07
  5 | Bananas      |     1200 | Europe        | 2026-10-12 10:10:11.916876-07
(5 rows)
```

## 3. Внешний диск и перенос базы данных

Выключил ВМ и в настройках UTM добавил второй диск на 5 ГБ (Drives → New → VirtIO). После загрузки он появился как `/dev/vdb` ([logs/04-new-disk.log](logs/04-new-disk.log)):

```
$ lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
vda    254:0    0   20G  0 disk
├─vda1 254:1    0  512M  0 part /boot/efi
├─vda2 254:2    0 18.6G  0 part /
└─vda3 254:3    0  951M  0 part [SWAP]
vdb    254:16   0    5G  0 disk
```

Разметил диск, создал ФС и настроил монтирование в `/mnt/data` по UUID через `/etc/fstab`, чтобы диск монтировался после перезагрузки ([logs/05-disk-init.log](logs/05-disk-init.log)):

```bash
sudo parted -s /dev/vdb mklabel gpt
sudo parted -s -a optimal /dev/vdb mkpart pgdata ext4 0% 100%
sudo mkfs.ext4 -L pgdata /dev/vdb1
sudo mkdir -p /mnt/data
UUID=$(sudo blkid -s UUID -o value /dev/vdb1)
echo "UUID=$UUID /mnt/data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount -a
```

```
$ df -h /mnt/data
Filesystem      Size  Used Avail Use% Mounted on
/dev/vdb1       4.9G   24K  4.6G   1% /mnt/data
```

Остановил кластер, скопировал каталог данных с сохранением прав и сверил копию с оригиналом. Старый каталог не удалял, а переименовал в `main.bak` на случай отката ([logs/07-move-data.log](logs/07-move-data.log)):

```bash
sudo systemctl stop postgresql@16-main
sudo apt-get install -y rsync
sudo rsync -aHAX /var/lib/postgresql/16 /mnt/data/postgresql/
sudo chown -R postgres:postgres /mnt/data/postgresql
sudo diff -r /var/lib/postgresql/16/main /mnt/data/postgresql/16/main && echo IDENTICAL
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.bak
```

```
IDENTICAL
$ sudo ls -ld /mnt/data/postgresql/16/main
drwx------ 19 postgres postgres 4096 Oct 12 10:10 /mnt/data/postgresql/16/main
```

## 4. Настройка PostgreSQL для работы с новым диском

Указал новый путь в параметре `data_directory`. Добавил для службы зависимость от точки монтирования: если внешний диск не подключится, PostgreSQL не запустится на пустом каталоге ([logs/08-pg-config.log](logs/08-pg-config.log)):

```bash
sudo sed -i "s|^data_directory = .*|data_directory = '/mnt/data/postgresql/16/main'\t\t# use data in another directory|" /etc/postgresql/16/main/postgresql.conf
sudo mkdir -p /etc/systemd/system/postgresql@16-main.service.d
printf '[Unit]\nRequiresMountsFor=/mnt/data\n' | sudo tee /etc/systemd/system/postgresql@16-main.service.d/mount.conf
sudo systemctl daemon-reload
sudo systemctl start postgresql@16-main
```

```
$ grep -n '^data_directory' /etc/postgresql/16/main/postgresql.conf
42:data_directory = '/mnt/data/postgresql/16/main'		# use data in another directory
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory               Log file
16  main    5432 online postgres /mnt/data/postgresql/16/main /var/log/postgresql/postgresql-16-main.log
$ sudo -u postgres psql -tAc "SHOW data_directory"
/mnt/data/postgresql/16/main
```

## 5. Проверка сохранности и доступности данных

Прочитал таблицу, записал в неё новую строку и перезагрузил ВМ, чтобы проверить автомонтирование диска и автозапуск PostgreSQL ([logs/09-check.log](logs/09-check.log)):

```
$ sudo -u postgres psql -d logistics -c "INSERT INTO shipments (product_name, quantity, destination) VALUES ('Bananas', 800, 'Europe')"
INSERT 0 1
$ sudo -u postgres psql -d logistics -c "SELECT pg_relation_filepath('shipments'), current_setting('data_directory')"
 pg_relation_filepath |       current_setting
----------------------+------------------------------
 base/16384/16386     | /mnt/data/postgresql/16/main
$ sudo systemctl reboot
```

После перезагрузки:

```
$ findmnt /mnt/data
TARGET    SOURCE    FSTYPE OPTIONS
/mnt/data /dev/vdb1 ext4   rw,relatime
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory               Log file
16  main    5432 online postgres /mnt/data/postgresql/16/main /var/log/postgresql/postgresql-16-main.log
$ sudo -u postgres psql -d logistics -c "SELECT * FROM shipments ORDER BY id"
 id | product_name | quantity |  destination  |          shipped_at
----+--------------+----------+---------------+-------------------------------
  1 | Bananas      |     1000 | Europe        | 2026-10-12 10:10:11.916876-07
  2 | Apples       |      500 | Asia          | 2026-10-12 10:10:11.916876-07
  3 | Oranges      |      750 | Africa        | 2026-10-12 10:10:11.916876-07
  4 | Mangoes      |      300 | South America | 2026-10-12 10:10:11.916876-07
  5 | Bananas      |     1200 | Europe        | 2026-10-12 10:10:11.916876-07
  6 | Bananas      |      800 | Europe        | 2026-10-12 10:11:13.296913-07
(6 rows)
```

Все 5 исходных строк на месте. Строка, записанная уже на новый диск, пережила перезагрузку. После перезагрузки PostgreSQL сам запустился с каталогом данных на внешнем диске `/dev/vdb1`.
