set -x
# PGHOST/PGPASSWORD/PGDATABASE из env.sh уводят psql на TCP с паролем; для первичной настройки нужен peer через сокет
runuser -u postgres -- env -u PGHOST -u PGPASSWORD -u PGDATABASE psql -c "ALTER USER postgres PASSWORD 'otus_pass'"
psql -c "SELECT version()"
psql -l
