set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg build-essential git fio >/dev/null

# PostgreSQL 17 из PGDG
install -d /usr/share/postgresql-common/pgdg
curl -fsSo /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# ClickHouse из официального репозитория
curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=amd64] https://packages.clickhouse.com/deb stable main" > /etc/apt/sources.list.d/clickhouse.list

apt-get update -qq
apt-get install -y -qq postgresql-17 clickhouse-server clickhouse-client >/dev/null
apt-get install -y -qq --no-install-recommends pgloader >/dev/null
pg_lsclusters
psql --version
clickhouse-server --version
pgloader --version

# настройки PostgreSQL под 8 vCPU / 32 ГБ
cp /opt/bench/pg-bench.conf /etc/postgresql/17/main/conf.d/bench.conf
cat /etc/postgresql/17/main/conf.d/bench.conf
systemctl restart postgresql@17-main
runuser -u postgres -- psql -c "ALTER USER postgres PASSWORD 'otus_pass'"
runuser -u postgres -- createdb tpch

# ClickHouse: файлы для file() читаются из каталога с данными TPC-H
mkdir -p $D
chmod 755 /data $D
cp /opt/bench/ch-bench.xml /etc/clickhouse-server/config.d/bench.xml
cat /etc/clickhouse-server/config.d/bench.xml
systemctl enable clickhouse-server
systemctl restart clickhouse-server
sleep 5
clickhouse-client -q "SELECT version()"
psql -c "SELECT version()"

# генератор TPC-H
git clone -q --depth 1 https://github.com/electrum/tpch-dbgen /opt/tpch-dbgen
make -C /opt/tpch-dbgen -j8 -s 2>&1 | grep -ci warning
ls -l /opt/tpch-dbgen/dbgen
