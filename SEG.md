# SEG — Selective Egress Gateway

## 1. Назначение

SEG — схема выборочной маршрутизации клиентского трафика через российский gateway и зарубежный exit.

Основное правило:

```text
destination ∈ seg-list
  → VPS2 → VPS1 → Internet

destination ∉ seg-list
  → DIRECT с клиента
```

Дополнительный (страховочный) механизм на VPS2: если клиент по ошибке направил на VPS2 трафик не по `seg-list`, VPS2 применяет `seg-list` сам.

```text
destination ∈ seg-list  → awg-backhaul → VPS1  (всегда, независимо от клиента)
destination ∉ seg-list  → DIRECT через VPS2    (страховка, SEG_UNMATCHED_POLICY=direct)
```

Страховка не заменяет клиентскую маршрутизацию: через VPS2 трафик выходит с IP VPS2, а наличие такого трафика считается признаком неверной настройки клиента (см. раздел 12 и `-Check`).

## 2. Общая схема

```text
Client
  │
  ├── destination ∉ seg-list
  │       └────────────────────────────► Internet напрямую
  │
  └── destination ∈ seg-list
          │
          │ VLESS + REALITY / TCP 443
          ▼
       VPS2 RU
          │
          ├── seg-list (серверная проверка)
          │       │
          │       │ AmneziaWG backhaul
          │       ▼
          │    VPS1
          │       └────────────────────► Internet
          │                              source IP = VPS1
          │
          └── не seg-list (страховка)
                  └────────────────────► Internet
                                         source IP = VPS2
```

## 3. Режимы проекта

Проект поддерживает:

```text
VPN
SEG
```

### VPN

```text
Client → vpn-server → Internet
```

### SEG

```text
Client → seg-gateway → seg-exit → Internet
```

Первая реализация:

```text
seg-gateway:
  Type = sing-box

seg-exit:
  Type = amnezia
```

## 4. Модель серверов

Формат `servers.txt`:

```text
Name;IP;Port;Role;Type;Enabled
```

Роли:

```text
vpn-server
seg-gateway
seg-exit
```

Типы:

```text
amnezia
openvpn
sing-box
...
```

Пример:

```text
vpn-01;151.236.30.153;42157;vpn-server;amnezia;true
seg-ru;1.2.3.4;443;seg-gateway;sing-box;true
seg-eu;5.6.7.8;;seg-exit;amnezia;true
```

### VPN

Режим VPN использует только:

```text
Role = vpn-server
```

`all` означает все enabled `vpn-server`.

### SEG

Первая версия требует:

```text
1 enabled seg-gateway
1 enabled seg-exit
```

`all` означает всю SEG-пару.

`vpn-server` в SEG не используется.

### Совместимость со старым форматом

Старый формат:

```text
Name;IP;Port;Enabled
```

мигрируется в новый (`Role = vpn-server`, `Type = amnezia`) только обычным запуском `sync-servers.ps1` после резервной копии и проверки.

`-Check` ничего не записывает: старый формат он читает в режиме совместимости (как `vpn-server` + `amnezia`) и сообщает «нужна миграция». Вывод `-Check` на старом и новом формате для режима VPN должен совпадать.

Пустой `Port` допустим только для `seg-exit` и не участвует в проверке уникальности портов.

## 5. Порты

`servers.txt.Port` означает публичный сервисный порт роли.

```text
vpn-server + amnezia
  → UDP-порт VPN.

seg-gateway + sing-box
  → TCP-порт VLESS/REALITY.

seg-exit
  → пусто.
```

Backhaul-порт хранится:

```text
SEG_BACKHAUL_PORT
```

Фаервол по ролям (`secure.sh`):

```text
seg-gateway
  → SSH;
  → TCP Port (VLESS/REALITY);
  → UDP SEG_BACKHAUL_PORT только от публичного IP seg-exit.

seg-exit
  → SSH;
  → входящие UDP/TCP сервисные порты не открываются
    (backhaul инициируется самим VPS1).
```

Смена публичного IP `seg-exit` требует повторного `sync` (правило источника на VPS2).

## 6. Конфигурация

SEG использует отдельный файл:

```text
config/seg.env
```

Файл `config/server.env` режимом SEG не читается и не изменяется. Параметры SEG имеют префикс:

```text
SEG_
```

Backup и restore выполняются по файлам независимо:

```text
config/server.env.<время>.bak    → VPN
config/seg.env.<время>.bak       → SEG
```

Копии `seg.env` содержат приватные ключи REALITY и backhaul, не шифруются и хранятся (последние три) так же, как копии `server.env`.

Backhaul использует отдельные:

- private/public keys VPS1;
- private/public keys VPS2;
- PSK;
- сеть;
- адреса;
- UDP-порт;
- AWG-параметры;
- интерфейс.

Интерфейс:

```text
awg-backhaul
```

Backup/restore выполняется отдельно для параметров VPN и SEG.

## 7. `seg-list.json`

Файл:

```text
config/seg-list.json
```

является единственным источником selective routing rules.

Содержит:

```text
version
groups
domains
domain_suffixes
cidrs
sources
```

Первая версия содержит:

```text
GitHub
GitHub Copilot
ChatGPT / OpenAI
Facebook / Messenger
Telegram
```

Для файла вычисляется SHA-256.

Из него генерируется sing-box `rule_set`.

Правила используются:

- на клиенте;
- на VPS2.

## 8. Клиент

Эталон:

```text
sing-box 1.14.4
```

Клиент работает в TUN-режиме.

Правило:

```text
destination ∈ seg-list
  → VLESS/REALITY → VPS2

destination ∉ seg-list
  → DIRECT
```

Клиент не знает VPS1.

Профиль клиента:

- содержит `route.auto_detect_interface`, чтобы соединение с VPS2 не попадало в собственный TUN;
- не перехватывает управляющий трафик (SSH к VPS): адреса VPS отсутствуют в `seg-list` и идут DIRECT.

SEG-клиенты:

```text
clients/seg/<client>.json
```

Generated profiles:

```text
clients/generated/seg/<client>.json
clients/generated/seg/<client>.meta.json
```

`meta.json` содержит:

```text
segListVersion
segListSha256
serverConfigSha256
generatedAt
```

## 9. Передача destination

Для selected domain:

```text
domain
  → client routing
  → VLESS destination = domain
  → VPS2
  → server-side domain rule
```

Selected domain не должен преобразовываться клиентом в destination IP до формирования VLESS-запроса.

Для прямых IP-подключений используются CIDR-правила.

## 10. DNS клиента

Клиент использует FakeIP/reverse mapping.

FakeIP применяется только к доменам `seg-list`. Остальные домены резолвятся локально (DIRECT DNS) и не получают FakeIP-адресов.

Selected DNS:

```text
Client
  → VLESS/REALITY
  → VPS2
  → awg-backhaul
  → DNS resolver VPS1
```

DIRECT DNS:

```text
Client
  → local/direct resolver
```

Для selected traffic:

```text
DNS strategy = ipv4_only
```

если IPv6 egress VPS1 не подтверждён.

Приложенческий DoH/DoT должен быть отключён или перехвачен TUN.

## 11. VPS2 — `seg-gateway`

VPS2 использует:

```text
sing-box 1.14.4
AmneziaWG
nftables
iproute2
```

Функции:

- принимает VLESS + REALITY;
- аутентифицирует клиента;
- определяет destination: домен из VLESS-запроса либо домен, восстановленный sniffing (TLS SNI, QUIC);
- проверяет destination по `seg-list`;
- selected traffic отправляет через `awg-backhaul`;
- unmatched proxy traffic обрабатывает по `SEG_UNMATCHED_POLICY`;
- поддерживает fail-closed для selected traffic.

VPS2 не является штатным Internet egress: прямой выход используется только как страховка для трафика вне `seg-list` (раздел 12).

## 12. Server-side routing и страховочный выход

Правило VPS2:

```text
destination ∈ seg-list
  → awg-backhaul → VPS1

destination ∉ seg-list
  → SEG_UNMATCHED_POLICY:
      direct → DIRECT через VPS2   (по умолчанию)
      block  → BLOCK
```

Принадлежность к `seg-list` проверяется по домену, по sniffed-домену и по CIDR. Sniffing включён на входящем соединении VPS2: это нужно, чтобы выбранный ресурс, который клиент ошибочно передал как IP, всё равно попал в `awg-backhaul`, а не ушёл с IP VPS2.

До проверки `seg-list` блокируются (при любой политике):

- loopback;
- private networks;
- link-local;
- metadata addresses;
- backhaul network;
- локальные сети VPS2.

Служебное исключение:

```text
VPS2_BACKHAUL_IP
  → VPS1_BACKHAUL_IP:DNS
  → ALLOW
```

Остальной доступ к backhaul network запрещён.

### Страховочный DIRECT

- Direct-трафик не получает `SEG_MARK` и никогда не использует `awg-backhaul`.
- Блокируется исходящий tcp/25.
- Ведутся счётчики unmatched-соединений без содержимого трафика и имён.
- Счётчик отображается в `-Check` как `UNMATCHED_DIRECT`: ненулевое значение означает, что клиент направляет на VPS2 трафик не по `seg-list`.
- Отзыв UUID выполняется через `remove-client` и `sync`.

### DNS на VPS2

```text
домен ∈ seg-list
  → DNS resolver VPS1 через awg-backhaul
     (без fallback на локальный резолвер)

домен ∉ seg-list
  → локальный резолвер VPS2
```

У selected outbound `domain_resolver` указывает только на resolver VPS1. При недоступности resolver VPS1 selected-запрос завершается ошибкой.

## 13. Policy routing VPS2

Backhaul использует:

```text
Table = off
```

Создаётся отдельная таблица:

```text
table seg
```

Selected outbound получает:

```text
routing_mark = SEG_MARK
```

`SEG_MARK` не совпадает с fwmark AmneziaWG, метками UFW и `awg-iptables`.

Правило:

```text
fwmark SEG_MARK
  → lookup table seg
```

Таблица:

```text
default dev awg-backhaul
```

Основная таблица VPS2 остаётся:

```text
main default
  → public interface VPS2
```

Selected traffic не использует main table. Привязка `bind_interface` и таблица `seg` — два независимых уровня; последний рубеж — правило nftables из раздела 14.

Ответный трафик из backhaul приходит с внешними адресами не со стороны публичного интерфейса, поэтому `rp_filter` на VPS2 не должен отбрасывать его (loose или отключённый для `awg-backhaul`).

MTU `awg-backhaul` и MSS clamp задаются явно и подтверждаются проверкой больших передач.

## 14. Fail-closed VPS2

Selected outbound sing-box использует:

```text
bind_interface = awg-backhaul
routing_mark = SEG_MARK
```

nftables:

```text
mark = SEG_MARK
AND oifname != awg-backhaul
  → DROP
```

Fail-closed:

- загружается раньше sing-box;
- не зависит от UFW;
- сохраняется после reboot;
- не удаляется `ufw reload`.

При отсутствии backhaul:

```text
selected traffic → FAIL
```

Запрещено:

```text
selected traffic → public interface VPS2
```

Страховочный DIRECT (раздел 12) этому правилу не противоречит: он относится только к трафику вне `seg-list` и не помечается.

## 15. VPS1 — `seg-exit`

Первая реализация:

```text
Type = amnezia
```

На VPS1 не создаётся:

```text
awg0
```

Создаётся только:

```text
awg-backhaul
```

VPS1:

- инициирует соединение с VPS2;
- поддерживает `PersistentKeepalive`;
- выполняет forwarding;
- выполняет NAT;
- предоставляет DNS resolver;
- выпускает selected traffic в Internet.

Входящие UDP/TCP сервисные порты VPS1 наружу не открываются: backhaul инициирует сам VPS1.

## 16. Backhaul

Первая реализация:

```text
AmneziaWG
```

### VPS2

```text
interface = awg-backhaul
Table = off
listener
Endpoint VPS1 не задаётся
```

Peer VPS1:

```text
AllowedIPs = 0.0.0.0/0
```

`::/0` добавляется только при включении SEG IPv6.

### VPS1

```text
interface = awg-backhaul
Endpoint = VPS2:SEG_BACKHAUL_PORT
PersistentKeepalive = enabled
```

Peer VPS2:

```text
AllowedIPs = VPS2_BACKHAUL_IP/32
```

Backhaul использует собственные:

- keys;
- PSK;
- сеть;
- адреса;
- порт.

## 17. DNS VPS1

DNS resolver слушает только backhaul-IP VPS1.

Разрешено:

```text
source = VPS2_BACKHAUL_IP
destination = VPS1_BACKHAUL_IP
DNS port
```

Остальные подключения к resolver запрещены.

DNS-запросы VPS1 выполняются через его зарубежный Internet egress.

## 18. Безопасность VPS1

Из `awg-backhaul` запрещены:

- SSH;
- loopback;
- private networks;
- link-local;
- metadata;
- управляющие сети.

Разрешены:

```text
DNS от VPS2

FORWARD
  → Internet

RETURN
  → established/related
```

## 19. REALITY

Параметры:

```text
private key
public key
shortId
server_name
dest
flow
fingerprint
```

x25519 keypair создаётся локальным `sing-box` (версия 1.14.4 входит в требования проекта, см. README).

`dest` должен быть доступен с VPS2.

Приватный ключ хранится:

- в локальном source of truth (`config/seg.env`);
- на VPS2.

## 20. Клиентские идентификаторы

Каждый SEG-клиент имеет отдельный:

```text
VLESS UUID
```

Реестр:

```text
clients/seg/*.json
```

Конфигурация пользователей VPS2 генерируется из этого реестра.

## 21. Версия списка

Каждый профиль связан с:

```text
segListVersion
segListSha256
```

После изменения `seg-list.json` профиль считается устаревшим.

Server-side `seg-list` применяется независимо от версии клиента: selected-ресурсы устаревшего клиента всё равно попадают на VPS1 по серверному списку, а прочий трафик обрабатывается по `SEG_UNMATCHED_POLICY`.

## 22. IPv6

DIRECT traffic клиента может использовать локальный IPv6.

Selected traffic использует IPv4, пока IPv6 egress VPS1 отдельно не включён и не проверен.

Для selected domain в этом режиме AAAA не используется.

Для включения SEG IPv6 отдельно настраиваются:

- backhaul IPv6;
- `AllowedIPs = ::/0` на VPS2;
- адрес VPS2 peer на VPS1;
- policy routing;
- VPS1 routing;
- fail-closed;
- DNS strategy.

## 23. Проверка состояния

```powershell
sync-servers.ps1 -Mode SEG -Check all
```

Проверяются:

```text
GATEWAY
EXIT
BACKHAUL
HANDSHAKE AGE
POLICY ROUTING
DNS THROUGH BACKHAUL
VPS1 EXTERNAL IP
FAIL-CLOSED
UNMATCHED_DIRECT
SEG-LIST VERSION
SEG-LIST HASH
SECURITY
```

`-Check` не изменяет конфигурацию. `FAIL-CLOSED` проверяется пассивно: наличие правила nftables и `ip rule`, содержимое таблицы `seg`, счётчики. Активная проверка (остановка backhaul) выполняется вручную.

## 24. Порядок развёртывания

```text
1. Upgrade/hardening.
2. Fail-closed VPS2.
3. Policy routing VPS2.
4. awg-backhaul VPS2.
5. awg-backhaul VPS1.
6. NAT/firewall/DNS VPS1.
7. Проверка handshake.
8. Проверка DNS через VPS1.
9. Проверка external IP = VPS1.
10. sing-box VPS2.
11. VLESS/REALITY.
12. server-side seg-list.
13. итоговый -Check.
```

При ошибке выполняется rollback предыдущей рабочей конфигурации.

При первой неуспешной установке sing-box остаётся выключенным, fail-closed сохраняется.

## 25. Риски и ограничения

- VPS2 является единой точкой входа selected traffic.
- VPS1 является единой точкой выхода selected traffic.
- Неполный `seg-list` приводит к DIRECT-маршрутизации ресурса с клиента.
- Устаревший клиентский профиль может не содержать новые правила; selected-ресурсы при этом обслуживает серверный `seg-list`.
- Изменение доменов, CDN или IP сервисов требует обновления `seg-list`.
- Прямые IP-подключения требуют CIDR-правил.
- Приложенческий DoH/DoT может обходить доменную классификацию; ECH скрывает SNI, поэтому серверный sniffing не гарантирован.
- Страховочный DIRECT выпускает неклассифицированный трафик с IP VPS2; утёкший UUID превращает VPS2 в российский прокси.
- Ресурс из `seg-list`, переданный клиентом без домена и не покрытый CIDR, уходит DIRECT через VPS2.
- Ошибка FakeIP/reverse mapping может привести к неверной классификации.
- Ошибка передачи destination domain может привести к срабатыванию страховочной политики.
- Selected IPv6 не используется без проверенного IPv6 egress VPS1.
- Падение backhaul делает selected traffic недоступным.
- Блокировка VPS2 прекращает selected ingress.
- Блокировка VPS1 прекращает selected egress.
- DPI может обнаружить или заблокировать VLESS/REALITY или AmneziaWG.
- Ошибка policy routing или fail-closed может привести к утечке через VPS2.
- Компрометация VPS2 раскрывает REALITY и backhaul credentials.
- Компрометация VPS1 раскрывает backhaul credentials.
- MTU/MSS требуют согласованной настройки backhaul.
- UDP-приложения требуют поддержки UDP/XUDP.

## 26. Документация

`README.md` является эксплуатационной документацией проекта и по завершении реализации должен покрывать всё, что описано в этом документе: режимы, `servers.txt`, `seg.env`, `seg-list.json`, клиентов, развёртывание, `-Check`, fail-closed, страховочный DIRECT, DNS, обновление, замену узлов, ротацию ключей и действия при компрометации.

`SEG.md` описывает архитектуру и требования; `README.md` — порядок работы. Расхождения между ними недопустимы.