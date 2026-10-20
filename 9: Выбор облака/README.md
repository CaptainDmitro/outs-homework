# ДЗ №9. Выбор облака

## 1. Развернуть managed PostgreSQL в двух облаках. Минимальные параметры: 1 vCPU, 1 ГБ RAM

Выбрал **Yandex Cloud** (Managed Service for PostgreSQL) и **VK Cloud** (Cloud Databases). Вместо скриншотов привожу вывод консоли.

### Yandex Cloud

Использую кластер `otus-pg` из ДЗ №8: PostgreSQL 17, один хост `b2.medium` в `ru-central1-e`, диск `network-ssd` 10 ГБ ([logs/01-cluster.log](logs/01-cluster.log)):

```
$ yc postgres cluster list
+----------------------+---------+---------------------+--------+---------+
|          ID          |  NAME   |     CREATED AT      | HEALTH | STATUS  |
+----------------------+---------+---------------------+--------+---------+
| c9qssrecqhfgosn3jo9b | otus-pg | 2026-10-20 16:09:30 | ALIVE  | RUNNING |
+----------------------+---------+---------------------+--------+---------+

$ yc postgres cluster get otus-pg --format json | jq '{name, environment, status, health, version: .config.version, resources: .config.resources, security_group_ids}'
{
  "name": "otus-pg",
  "environment": "PRODUCTION",
  "status": "RUNNING",
  "health": "ALIVE",
  "version": "17",
  "resources": {
    "resource_preset_id": "b2.medium",
    "disk_size": "10737418240",
    "disk_type_id": "network-ssd"
  },
  ...
```

**Проблема:** класса 1 vCPU / 1 ГБ нет. Минимальный `b2.medium` — это 2 vCPU с гарантированной долей 50% и 4 ГБ RAM (подробности в ДЗ №8).

### VK Cloud

Кластер создавал через Terraform ([terraform/vkcs](terraform/vkcs)): сеть, подсеть, роутер, группа безопасности, инстанс `vkcs_db_instance` (PostgreSQL 17, `ceph-ssd` 10 ГБ, автоувеличение диска до 20 ГБ), БД `bananaflow`, пользователь `banana` и план резервного копирования (раз в неделю, хранить 7 полных копий).

```bash
source <(sed 's/^Export /export /' ~/otushw2-openrc.sh) </dev/null
terraform -chdir=terraform/vkcs init
terraform -chdir=terraform/vkcs apply -auto-approve
```

**Проблема:** первый `apply` упал на создании инстанса ([logs/04-vk-terraform-apply-failed.log](logs/04-vk-terraform-apply-failed.log)):

```
Error: error creating vkcs_db_instance: Request forbidden: ... {"forbidden": {"code": 403, "message": "Policy doesn't allow instance:create to be performed."}}
```

**Решение:** у сервисного пользователя `otushw` не было роли на Cloud Databases. Создали сервисного пользователя `otushw2` с нужной ролью, я взял его openrc. В скачанном openrc последняя строка `Export OS_PASSWORD=...` написана с заглавной буквы, а скрипт сам спрашивает пароль через `read`. Поэтому подключаю файл через `sed` с `</dev/null`.

**Проблема:** на 1 vCPU / 1 ГБ (`STD3-1-1`) API ответил ([logs/05-vk-terraform-apply-failed.log](logs/05-vk-terraform-apply-failed.log)):

```
{"badRequest": {"code": 400, "message": "Flavor should meet default requirements:RAM-8192 and CPU-2."}}
```

**Решение:** минимальный flavor для Cloud Databases — 2 vCPU / 8 ГБ. Взял `STD3-2-8` (Intel Ice Lake).

**Проблема:** инстанс перешёл в `ERROR` ([logs/06-vk-terraform-apply-failed.log](logs/06-vk-terraform-apply-failed.log)):

```
"message": "Failed to create server for instance 9f655d9d-...\nQuota exceeded for resource: 'floatingip' (limit: 0, used: 0)."
```

Повторный `apply` пересоздал инстанс и снова получил `ERROR` (`list index out of range`). Удалённый через Terraform инстанс оставил в проекте работающий сервер и тома, и квота дисков (4 шт.) кончилась ([logs/07-vk-terraform-apply-failed.log](logs/07-vk-terraform-apply-failed.log)):

```
+ GET network/v2.0/quotas/<project> | jq .quota.floatingip
0
+ GET volume/v3/<project>/os-quota-sets?usage=true | jq .quota_set.volumes
{"reserved":0,"allocated":0,"limit":4,"in_use":4}
```

**Решение:** удалил оставшиеся серверы и тома через API. Квота floating IP в проекте по-прежнему 0, поэтому вынес публичный IP в переменную `public_access` и создал инстанс без него (`public_access = false` в `terraform.tfvars`).

**Проблема:** инстанс создался за 2m19s, но пользователь БД — нет ([logs/08-vk-terraform-apply-failed.log](logs/08-vk-terraform-apply-failed.log)):

```
{"badRequest": {"code": 400, "message": "User create error: invalid password: password must be at least 16 characters long and contain a lowercase letter, an uppercase letter, a digit and a special character."}}
```

**Решение:** задал пароль по политике VK (`Otus-Pass-9-Banana!`, тестовый) ([logs/09-vk-terraform-apply.log](logs/09-vk-terraform-apply.log)):

```
vkcs_db_user.banana: Creation complete after 13s [id=7275c5df-e49a-4f9a-a7f6-0cab78fc398c/banana]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

Состояние инстанса ([logs/10-vk-cluster.log](logs/10-vk-cluster.log)):

```
+ GET database/v1.0/<project>/instances/7275c5df-e49a-4f9a-a7f6-0cab78fc398c
{
  "name": "otus-pg",
  "status": "ACTIVE",
  "datastore": {
    "type": "postgresql",
    "version": "17"
  },
  "flavor": "2d9866a9-e955-4986-b00a-340ca54b2cac",
  "volume": {
    "size": 10,
    ...
  },
  "ip": [
    "192.168.199.113"
  ],
  ...
}
+ GET .../instances/<id>/databases
{"databases":[{"name":"bananaflow"}]}
+ GET .../instances/<id>/users
[{"name":"banana","databases":[{"name":"bananaflow"}]}]
```

## 2. Настроить доступ с вашего IP

**Yandex Cloud:** в группе безопасности кластера открыт порт 6432 только для моего IP ([logs/02-access.log](logs/02-access.log)):

```
$ yc vpc security-group get enp4g2tqhtcnub933ujh --format json | jq '{name, rules: [...]}'
{
  "name": "otus-pg-sg",
  "rules": [
    {
      "description": "psql from my IP",
      "direction": "INGRESS",
      "ports": {
        "from_port": "6432",
        "to_port": "6432"
      },
      "protocol_name": "TCP",
      "cidr_blocks": {
        "v4_cidr_blocks": [
          "85.172.184.54/32"
        ]
      }
    }
  ]
}
```

**Проблема:** `ifconfig.me` показывает другие адреса (`95.85.243.6`, `95.85.249.52`). Трафик в российские сети идёт напрямую с `85.172.184.54`, а на зарубежные — через VPN (разобрано в ДЗ №8).

**Решение:** в правиле VK указал все три адреса (`allowed_cidrs` в [terraform.tfvars](terraform/vkcs/terraform.tfvars), ресурс `vkcs_networking_secgroup_rule.psql`, порт 5432).

**Проблема:** в VK Cloud без floating IP (квота 0, см. п. 1) у инстанса нет публичного адреса, поэтому с моего IP к нему не подключиться.

**Решение:** проверку подключения и замеры делаю изнутри облаков. В каждом облаке поднял клиентскую VM в той же сети, что и кластер, и открыл для неё порт БД:

- VK: `vkcs_compute_instance.client` (`STD3-2-4`, Ubuntu 24.04, без публичного IP, выход в интернет через роутер) и правило `vkcs_networking_secgroup_rule.psql_subnet` на 5432 из `192.168.199.0/24` ([logs/11-vk-client-apply.log](logs/11-vk-client-apply.log));
- Yandex: `yandex_compute_instance.client` (`standard-v3`, 2 vCPU / 4 ГБ, Ubuntu 24.04) в `ru-central1-e` и правило в `otus-pg-sg` на 6432 из `10.131.0.0/24` ([terraform/yandex](terraform/yandex), [logs/12-yc-client-apply.log](logs/12-yc-client-apply.log)).

Cloud-init ([cloud-init/user-data.yaml.tftpl](cloud-init/user-data.yaml.tftpl)) ставит `postgresql-client`, `pgbench` и `ansible-core`, запускает плейбуки из [ansible](ansible) и пишет вывод в серийную консоль VM.

## 3. Проверить подключение через psql

**Yandex Cloud, с Mac** ([logs/03-psql.log](logs/03-psql.log)):

```
+ psql 'host=rc1e-6gbc9ajfe68rdr30.mdb.yandexcloud.net port=6432 sslmode=verify-full dbname=bananaflow user=banana' -c '\conninfo' -c 'select version()'
...
 Host                 | rc1e-6gbc9ajfe68rdr30.mdb.yandexcloud.net
 Host Address         | 153.51.113.144
 Server Port          | 6432
...
 SSL Connection       | true
 SSL Protocol         | TLSv1.3
...
 PostgreSQL 17.11 (Ubuntu 17.11-201-yandex.60286.5a0f49380c) on x86_64-pc-linux-gnu, compiled by gcc (Ubuntu 11.4.0-1ubuntu1~22.04.3) 11.4.0, 64-bit
```

**VK Cloud, с клиентской VM** (задача «Тестовые запросы» плейбука [ansible/playbook.yml](ansible/playbook.yml), [logs/13-vk-bench.log](logs/13-vk-bench.log)). Консоль VK отдаёт вывод без UTF-8, поэтому русские названия задач в логе заменены на `�`:

```
ok: [localhost] => (item=vk) => {
    "msg": [
        " PostgreSQL 17.11 on x86_64-pc-linux-gnu, compiled by gcc (GCC) 8.5.0 20210514 (Red Hat 8.5.0-28), 64-bit",
        ...
        " 2026-10-20 17:49:02.021378+00 | banana       | bananaflow       | f",
        ...
        " ssl | version ",
        "-----+---------",
        " f   | ",
```

В VK по умолчанию SSL не включён: с `sslmode=prefer` соединение установлено без шифрования. В Yandex `pg_stat_ssl` тоже показывает `f` ([logs/14-yc-bench.log](logs/14-yc-bench.log)), потому что запрос видит соединение пулера Odyssey с PostgreSQL на самом хосте. Клиент подключается к Odyssey по TLS (`sslmode=verify-full`, см. `\conninfo` выше).

## 4. Сравнить характеристики

### Стоимость в месяц (включая резервные копии)

Цены Yandex — из Billing API ([logs/15-yc-prices.log](logs/15-yc-prices.log)), цены VK — из [прайс-листа](https://cloud.vk.ru/pricelist) от 12.01.2026. В обоих случаях рубли с НДС, месяц = 720 часов (30 дней).

```
Managed Service for PostgreSQL. Host computing resources, Intel Cascade Lake, 50% vCPU | core*hour | 1.0892
Managed Service for PostgreSQL. Host computing resources, Intel Cascade Lake, RAM | gbyte*hour | 0.5649
Managed Service for PostgreSQL. Public IP address | fip*hour | 0.2766
Managed Service for PostgreSQL. Backups beyond storage size | gbyte*hour | 0.00307
Managed Service for PostgreSQL. Storage on network SSD disks | gbyte*hour | 0.0218
```

| Статья | Yandex Cloud (`b2.medium`: 2 vCPU 50%, 4 ГБ) | VK Cloud (`STD3-2-8`: 2 vCPU 100%, 8 ГБ) |
|---|---|---|
| vCPU | 2 × 1,0892 × 720 = 1 568,45 ₽ | 2 × 1 061,63 = 2 123,26 ₽ |
| RAM | 4 × 0,5649 × 720 = 1 626,91 ₽ | 8 × 278,31 = 2 226,48 ₽ |
| Диск данных SSD 10 ГБ | 10 × 0,0218 × 720 = 156,96 ₽ | 10 × 16,59 = 165,90 ₽ |
| Системный диск | не тарифицируется | 15 × 16,59 = 248,85 ₽ (том `root-…` 15 ГБ) |
| Публичный IP | 0,2766 × 720 = 199,15 ₽ | 188,00 ₽ |
| Резервные копии | 0 ₽ (бесплатно, пока объём не больше хранилища 10 ГБ) | ≈ 24,90 ₽ (≤ 5 ГБ × 4,98 ₽: 7 полных копий БД ~0,5 ГБ) |
| **Итого** | **≈ 3 551 ₽** | **≈ 4 977 ₽** |

### Latency при выполнении запросов

Плейбук [ansible/playbook.yml](ansible/playbook.yml) гоняет `select 1;` через `pgbench -n -f select1.sql -c 1 -T 30` (один клиент, 30 с), а [ansible/pgbench.yml](ansible/pgbench.yml) запускает `pgbench -i -s 10` и тесты на 8 клиентов по 60 с ([logs/13-vk-bench.log](logs/13-vk-bench.log), [logs/14-yc-bench.log](logs/14-yc-bench.log), [logs/16-mac-yc-ansible.log](logs/16-mac-yc-ansible.log)):

| Замер | Yandex Cloud | VK Cloud |
|---|---|---|
| `select 1`, VM в той же сети | 0.346 ms (stddev 0.197), 2889 tps | 0.162 ms (stddev 0.065), 6161 tps |
| `select 1`, с Mac через интернет | 42.559 ms, 23.5 tps | — (нет публичного IP) |
| `initial connection time` | 12.338 ms | 13.339 ms |
| `pgbench -i -s 10` | done in 18.94 s | done in 1.98 s |
| TPC-B, 8 клиентов | 816.8 tps, 9.793 ms | 1274.1 tps, 6.277 ms |
| select-only, 8 клиентов | 7415.3 tps, 1.079 ms | 27210.9 tps, 0.294 ms |

Конфигурации не равны: в VK 2 полных vCPU и 8 ГБ, в Yandex 2 vCPU с долей 50% и 4 ГБ. К тому же в Yandex запрос идёт через TLS и пулер Odyssey, а в VK — напрямую без SSL.

### Удобство управления (интерфейс, документация)

| | Yandex Cloud | VK Cloud |
|---|---|---|
| CLI | `yc postgres ...`: кластер, хосты, пользователи, БД, классы хостов | отдельного CLI для БД нет: OpenStack API (Trove) или Terraform |
| Terraform | провайдер `yandex-cloud/yandex` | провайдер `vk-cs/vkcs` (0.18.0): сеть, инстанс, БД, пользователи, бэкапы |
| Доступ снаружи | публичный IP хоста + группа безопасности, работает сразу | нужен floating IP; у нового проекта квота 0 |
| Минимальная конфигурация | 2 vCPU 50% / 4 ГБ | 2 vCPU / 8 ГБ |
| SSL и пулер | TLS с публичным CA и Odyssey из коробки | SSL не включён, пулера нет |
| Время создания | ~10 мин (ДЗ №8) | 2m19s |
| Документация | цены в документации и в Billing API | цены только в прайс-листе и калькуляторе |
| Ошибки | понятные сообщения API | `list index out of range`, остатки серверов и томов после неудачного создания |

## 5. Документировать процесс

**Какие облака выбрали и почему.** Yandex Cloud: в нём уже был кластер из ДЗ №8 и настроенный `yc`. VK Cloud: у него есть Terraform-провайдер с ресурсами для БД, сетей и бэкапов, который удобно описывает всю инфраструктуру кодом.

**С какими проблемами столкнулись.** Подробности — в пп. 1–3:

- ни одно облако не даёт 1 vCPU / 1 ГБ: в Yandex минимум 2 vCPU 50% / 4 ГБ, в VK — 2 vCPU / 8 ГБ;
- VK: у сервисного пользователя не было роли на Cloud Databases (403), понадобился второй пользователь;
- VK: опечатка `Export` в openrc и интерактивный ввод пароля через `read`;
- VK: квота floating IP равна 0. Инстанс без публичного IP недоступен с моего IP, проверки пришлось делать с VM внутри облака;
- VK: инстанс в `ERROR` оставил в проекте работающий сервер и тома, они заняли квоту дисков, удалял вручную через API;
- VK: политика паролей (16+ символов, регистры, цифра, спецсимвол);
- Yandex: внешний IP Mac зависит от направления (VPN), правило пришлось открывать для адреса, который видит Yandex.

**Вывод: какое облако лучше подходит для BananaFlow.** Для BananaFlow сейчас лучше **Yandex Cloud**:

- минимальная конфигурация дешевле (≈ 3 551 ₽ против ≈ 4 977 ₽ в месяц, бэкапы в пределах размера диска бесплатны);
- доступ с IP офиса работает сразу, без запросов квоты;
- TLS и пулер соединений включены из коробки;
- кластером можно полностью управлять через `yc`.

VK Cloud дешевле за единицу ресурса: vCPU Ice Lake 1 061,63 ₽ против 1 353 ₽ в Yandex (1,8792 × 720), RAM 278 ₽ против 407 ₽ за ГБ. На своей конфигурации 2 vCPU / 8 ГБ VK дал в 1,5–3,7 раза больше tps и вдвое меньшую задержку внутри облака. Поэтому VK стоит рассмотреть, когда BananaFlow понадобится от 2 полных vCPU / 8 ГБ и задержка внутри облака станет важнее цены.

## ⭐ Автоматизация: Terraform и Ansible

- [terraform/vkcs](terraform/vkcs): весь стенд VK — сеть, подсеть, роутер, группа безопасности, `vkcs_db_instance`, `vkcs_db_database`, `vkcs_db_user`, `vkcs_backup_plan`, клиентская VM с cloud-init.
- [terraform/yandex](terraform/yandex): клиентская VM и правило в группе безопасности существующего кластера `otus-pg` (сам кластер создан через `yc` в ДЗ №8). Запуск: `YC_TOKEN=$(yc iam create-token) terraform apply`.
- [ansible/playbook.yml](ansible/playbook.yml): настройка подключения (CA облака в `~/.postgresql`, запись в `~/.pgpass`), тестовые запросы, замер latency `select 1`.
- [ansible/pgbench.yml](ansible/pgbench.yml): `pgbench -i -s 10`, TPC-B и select-only на 8 клиентов по 60 с.
- Инвентари: [ansible/inventory/mac.yml](ansible/inventory/mac.yml) (с Mac), [yandex-vm.yml](ansible/inventory/yandex-vm.yml) и [vk-vm.yml](ansible/inventory/vk-vm.yml) (cloud-init встраивает их в VM вместе с плейбуками).

Запуск с Mac для Yandex ([logs/16-mac-yc-ansible.log](logs/16-mac-yc-ansible.log)):

```
+ ansible-playbook -i ansible/inventory/mac.yml ansible/playbook.yml
...
        "latency average = 42.559 ms",
...
localhost                  : ok=8    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

## ⭐ Тестирование под нагрузкой (pgbench)

TPC-B на 8 клиентов, scale 10, 60 с:

```
Yandex Cloud (logs/14-yc-bench.log)
        "number of transactions actually processed: 48954",
        "latency average = 9.793 ms",
        "tps = 816.799814 (without initial connection time)",

VK Cloud (logs/13-vk-bench.log)
        "number of transactions actually processed: 76412",
        "latency average = 6.277 ms",
        "tps = 1274.082803 (without initial connection time)",
```

Итог: кластеры работают в обоих облаках. Для BananaFlow по цене и простоте доступа выбираю Yandex Cloud, а VK Cloud — вариант на будущее, когда понадобится больше ресурсов.
