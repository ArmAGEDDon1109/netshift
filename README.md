<div align="center">

# NetShift

<p align="center">
  <img src="./docs/icon.png" alt="NetShift" width="128" />
  <br>
  <br>
  <a href="https://github.com/ArmAGEDDon1109/netshift/actions">
    <img src="https://img.shields.io/github/actions/workflow/status/ArmAGEDDon1109/netshift/ci-main.yml?branch=main&label=CI">
  </a>
  <a href="https://github.com/ArmAGEDDon1109/netshift/actions/workflows/build-packages.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/ArmAGEDDon1109/netshift/build-packages.yml?branch=main&label=Build%20OWRT%2024%2F25">
  </a>
</p>
<h3 align="center"><a href="https://github.com/sagernet/sing-box">Sing-box</a> client for OpenWrt — extended fork</h3>
</div>

---

**NetShift** ([fork](https://github.com/ArmAGEDDon1109/netshift)) — форк [upstream NetShift](https://github.com/yandexru45/netshift) / [podkop](https://github.com/itdoginfo/podkop): маршрутизатор трафика для OpenWrt на базе [sing-box](https://github.com/SagerNet/sing-box). Нужные домены и подсети — в туннель, остальное — напрямую.

**Чем отличается от upstream NetShift:**

- **Локальный DNS** — dnsmasq перенаправляет запросы на sing-box (`127.0.0.42:53`), FakeIP `198.18.0.0/15`, split-DNS без утечек на WAN; опционально DNS через outbound.
- **Автоопределение блокировок (auto-learn)** — мониторинг DNS LAN-клиентов, TLS-пробы и автоматический выбор: Zapret exclude → desync → NetShift hot-patch. Подробные схемы — в разделе [Автоопределение блокировок](#автоопределение-блокировок-auto-learn) ниже.

Пакеты в OpenWrt по-прежнему называются `netshift` / `luci-app-netshift` (совместимость с конфигом `/etc/config/netshift`).

> [!WARNING]
> Проект находится в стадии бета-версии. Возможны ошибки, нестабильная работа и существенные изменения функциональности.

---

## Автоопределение блокировок (auto-learn)

NetShift следит за DNS-запросами **LAN-клиентов** (dnsmasq `logqueries`), для новых доменов запускает **TLS-пробу** (не HTTP 200 — именно handshake: Zapret часто ломает TLS, а TCP ещё «живой») и выбирает исход:

| Стадия | Что произошло |
|--------|----------------|
| `resolved_direct` | Домен в exclude Zapret (или exclude не нужен) и **TLS с LAN-пути** проходит |
| `resolved_desync` | TLS ок при **desync вкл** (домен не в exclude) — обход DPI достаточен |
| `resolved_zapret` | **Desync ломает TLS** (в браузере часто `SSL_ERROR_RX_MALFORMED_SERVER_HELLO`), exclude восстанавливает handshake → домен в **exclude** Zapret |
| `netshift` | Прямой путь не работает — домен добавлен в ruleset **hot-patch без restart** |
| `failed` | Недоступен ни напрямую, ни через туннель |

Список и история — LuCI **Services → NetShift → Auto-detection** (блоки «Detection log» и **«Zapret exclude list»** — всё, что в `zapret-hosts-user-exclude.txt`, с пометкой Auto-learn / вручную). CLI: `netshift auto_learn probe <domain>`, `netshift auto_learn zapret-excludes`.

### Схема: цикл auto-learn

```mermaid
flowchart TD
    A["LAN-клиент резолвит домен"] --> B["dnsmasq + logqueries"]
    B --> C["Монитор auto-learn\n(netshift __auto_learn_monitor)"]
    C --> D{".ru / .lan / Yandex /\nлокальные имена?"}
    D -->|да| SKIP["Пропуск"]
    D -->|нет| LAN["TLS-проба: veth netns\n(FORWARD как у ПК)"]
    LAN --> EX{уже в exclude\nZapret?}
    EX -->|да| E["TLS с exclude"]
    E -->|OK| R1["resolved_direct"]
    EX -->|нет| F["① TLS: desync ON\n(тот же LAN-путь)"]
    F -->|OK| R2["resolved_desync"]
    F -->|fail| G["② TLS: добавить exclude\n(desync OFF)"]
    G -->|OK| R3["resolved_zapret\nпостоянный exclude"]
    G -->|fail| H["④ TLS через NetShift\n(service proxy)"]
    H -->|OK| R4["hot-patch ruleset\n→ netshift"]
    H -->|fail| R5["failed"]
```

### Схема: интеграция с Zapret (`90-script.sh`)

При включении **Integrate with Zapret** в LuCI NetShift копирует `90-script.sh` в Zapret и даёт API для exclude без ручного редактирования файлов:

```mermaid
sequenceDiagram
    participant LuCI
    participant NetShift
    participant Script as 90-script.sh
    participant Zapret as /etc/init.d/zapret
    participant List as zapret-hosts-user-exclude.txt

    LuCI->>NetShift: zapret_enabled = 1, Save
    NetShift->>Script: deploy → /opt/zapret/.../custom.d/
    NetShift->>Zapret: reload

    Note over NetShift,Script: auto-learn probe
    NetShift->>Script: add-exclude example.com
    Script->>List: append domain
    Script->>Zapret: reload
    Note over List: домен не попадает под nfqws v10 desync
```

Файлы exclude:

- `/opt/zapret/ipset/zapret-hosts-user-exclude.txt` — общий список (ручной + auto-learn)
- `/opt/zapret/ipset/zapret-hosts-netshift-auto-exclude.txt` — только домены, добавленные NetShift

### Схема: ручное исключение из Zapret (без auto-learn)

Если auto-learn не нужен, домен можно исключить **вручную** — трафик к нему идёт в WAN **минуя nfqws desync**, NetShift не участвует:

```mermaid
flowchart LR
    subgraph manual ["Ручной exclude (без NetShift auto-learn)"]
        M["echo domain >>\nzapret-hosts-user-exclude.txt"] --> R["/etc/init.d/zapret reload"]
        R --> P["Клиент → роутер → WAN\nбез v10 desync"]
    end

    subgraph compare ["Для сравнения: домен НЕ в exclude"]
        C["Клиент"] --> RT["Роутер"] --> N["nfqws v10 desync"] --> W["WAN"]
        N -.->|часто| X["TLS ломается,\nHTTP «кажется» живым"]
    end
```

Тот же exclude-лист использует auto-learn на шагах ① и ③; отличие в том, что auto-learn **сам** находит домен по DNS, проверяет TLS и решает: оставить exclude, полагаться на desync или отправить в NetShift.

### TLS-проба с LAN (только на роутере)

Обычный `curl` **на самом роутере** часто идёт не тем же путём, что браузер на ПК (nfqws/Zapret цепляется к **FORWARD** LAN→WAN). Поэтому auto-learn поднимает **синтетического LAN-клиента** на роутере:

| Компонент | Назначение |
|-----------|------------|
| `kmod-veth` | Модуль ядра для пары veth (обязательная зависимость пакета `netshift`) |
| `nsp-lan` | Конец veth, подключён к `br-lan` |
| `netshift-probe` | Network namespace с адресом «как у ПК» |
| DNS `192.168.1.1` | Тот же dnsmasq, что видят LAN-клиенты |
| `curl` из namespace | Трафик уходит в **FORWARD**, как с компьютера в сети |

**Зависимости пакета** (OpenWrt `opkg` / `apk` при `install.sh` или установке `.ipk`/`.apk`):

- `kmod-veth` — **подтягивается автоматически** вместе с `netshift` (`DEPENDS` в Makefile).
- Если ставили вручную без зависимостей: `opkg install kmod-veth` или `apk add kmod-veth`.

**Настройка IP «клиента»** (должен быть свободен и **вне пула DHCP**):

```uci
config auto_learn 'auto_learn'
	option enabled '1'
	option probe_lan_ip '192.168.1.242'
```

В LuCI: **Auto-detection → LAN probe client IP** (по умолчанию `192.168.1.242`).

Проверка вручную:

```sh
netshift auto_learn probe example.com
logread -e netshift | tail -20
```

При старте монитора создаётся veth; при остановке NetShift — удаляется. В `fw4` добавляется правило `forward_lan` для `nsp-lan` (комментарий `netshift-probe`).

Домены из **пользовательских списков секции** NetShift дополнительно проверяются через **mixed inbound** sing-box (путь в туннель).

<details>
<summary><b>Ограничения auto-learn</b></summary>

- Видны только DNS-запросы **LAN-клиентов** через dnsmasq; DNS самого роутера (например ACME на роутере) не мониторится — используйте `netshift auto_learn probe <domain>`.
- Пробуется **точное имя** из DNS, не родительский домен (`acme-v02.api.letsencrypt.org`, не `letsencrypt.org`).
- TLS-проба для Zapret идёт через **синтетического LAN-клиента на роутере** (veth в `br-lan` + network namespace, пакетный путь FORWARD как у ПК). Нужен пакет `kmod-veth` (зависимость `netshift`). IP задаётся `auto_learn.probe_lan_ip` (по умолчанию `192.168.1.242`, вне пула DHCP). Домены из списков секции NetShift дополнительно проверяются через mixed inbound sing-box.
- **Zapret / desync и TLS:** nfqws может портить ServerHello (Firefox: `SSL_ERROR_RX_MALFORMED_SERVER_HELLO`). Auto-learn сравнивает handshake **с desync** и **с exclude** на клиентском пути; `resolved_zapret` только если exclude реально восстанавливает TLS. Если домен в списке NetShift, а TLS через туннель всё равно падает → `failed` / `tunnel_tls_fail` (исключение Zapret браузер не починит — смотрите outbound/CDN).
- Игнорируются: `*.ru`, Yandex (`*.yandex.*`, `ya.ru`), `*.lan`, `*.local`, `*.home.arpa`, неполные hostname.

</details>

---

## Функции

- [x] **Маршрутизация по доменам и подсетям** - нужное в туннель, остальное напрямую<br><sub>VLESS · Shadowsocks · Trojan · Hysteria2 · VMess · SOCKS · готовые community-списки</sub>
- [x] **Subscription URL** - ссылки подписки от провайдера с автообновлением и автовыбором лучшего сервера<br><sub>любая подписка remnawave · 3x-ui · marzban · github · форматы base64 / URI / Clash / Xray JSON</sub>
- [x] **Несколько подписок и фильтры** - несколько фидов в одной секции, фильтр серверов по ключевым словам (include / exclude)<br><sub>объединение без дублей · регистронезависимо · работает и по эмодзи</sub>
- [x] **Группировка серверов** - по флагу страны или по префиксу имени, с авто-выбором «⚡ Самый быстрый» среди всех групп<br><sub>URLTest внутри группы · URLTest над группами · ручной выбор сохранён</sub>
- [x] **Переключаемое ядро sing-box** - стабильное ↔ sing-box-extended прямо из веб-интерфейса<br><sub>клиентский транспорт xhttp · самовосстановление и автооткат · установка в один клик</sub>
- [x] **Самообновление из веб-интерфейса** - проверка и установка обновлений NetShift прямо из LuCI<br><sub>асинхронно · бэкап конфига · без риска «окирпичивания»</sub>
- [x] **Веб-интерфейс LuCI** - дашборд, менеджер компонентов, диагностика и настройки без ручной правки конфигов<br><sub>статус серверов · проверка соединения · логи · вкладки-карточки</sub>
- [x] **IPv6, блокировка DoH, глобальный прокси** - полная маршрутизация v6 через туннель, защита DNS роутера, режим «весь трафик в туннель»<br><sub>v6 tproxy / DNS / FakeIP · DNS через прокси · фоновый watchdog sing-box</sub>
- [x] **Автоматическая миграция** - обновление со старого podkop переносит конфиг без перенастройки
- [x] **Локальный DNS** - dnsmasq → sing-box, FakeIP, маршрутизация DNS-запросов LAN-клиентов через роутер<br><sub>127.0.0.42:53 · split-DNS · DNS via outbound · блокировка DoH</sub>
- [x] **Автоопределение блокировок** - Zapret exclude → NetShift hot-patch, runtime-список без UCI-restart storm<br><sub>интеграция с `90-script.sh` · LuCI «Auto-detection» · `netshift auto_learn` CLI</sub>


---

<div align="center">

<img src="docs/screenshot.png" alt="NetShift в LuCI" width="800" />

</div>

---

## Вещи, которые необходимо знать перед установкой

<details open>
<summary><b>Системные требования</b></summary>

- OpenWrt **24.10** или выше (поддерживаются и сборки на `opkg`/`.ipk`, и новые на `apk`/`.apk` - OpenWrt 25.12+).
- Минимум **25 МБ** свободного места. Устройства с флеш-памятью 16 МБ не поддерживаются.
- На устройстве: `sing-box >= 1.12.0`, `jq >= 1.7.1`, `coreutils-base64 >= 9.7`, `kmod-nft-tproxy`, **`kmod-veth`** (TLS-пробы auto-learn с LAN-пути), `curl`, `bind-dig` — зависимости пакета **`netshift`** (`opkg`/`apk` ставят их вместе с пакетом).
- Без `kmod-veth` auto-learn использует запасной путь (dnsmasq + `curl` на роутере); для Zapret это менее точно — см. [TLS-проба с LAN](#tls-проба-с-lan-только-на-роутере).

</details>

<details>
<summary><b>Обновления и конфигурация</b></summary>

- При обновлении **обязательно** [очищайте кэш LuCI](https://podkop.net/docs/clear-browser-cache/).
- После обновления проверяйте конфигурацию - она может меняться между версиями.
- При старте NetShift модифицирует конфигурацию Dnsmasq.
- NetShift изменяет конфигурацию sing-box. Если используете собственную - заранее сохраните её.

</details>

<details>
<summary><b>Ограничения и особенности</b></summary>

- Если установлен **Getdomains**, его [необходимо удалить](https://github.com/itdoginfo/domain-routing-openwrt?tab=readme-ov-file#скрипт-для-удаления).
- **Dashboard** работает только по HTTP (особенность Clash API). По HTTPS или через домен может быть недоступен.

</details>

<details>
<summary><b>Поддержка и диагностика</b></summary>

- [Руководство по диагностике](https://podkop.net/docs/diagnostics/)
- Актуальные изменения - в [Telegram-чате](https://t.me/netshift_chat/2) (читайте закреплённые сообщения).
- При проблемах оставляйте технически грамотный фидбэк в GitHub Issues и Telegram-чате.

</details>

<details>
<summary><b>Миграция с podkop (0.8.0) и смена формата конфига (0.7.0)</b></summary>

**0.8.0 - переименование в NetShift.** Пакет теперь `netshift` (бинарь `/usr/bin/netshift`), конфиг - `/etc/config/netshift`, LuCI-приложение - `luci-app-netshift`. При обновлении старый конфиг `/etc/config/podkop` автоматически мигрируется в `/etc/config/netshift`, резервная копия сохраняется в `/etc/config/podkop.bak.pre-netshift`. туннель продолжит работать без перенастройки.

**0.7.0 - несовместимый формат конфига.** Старые значения несовместимы - нужно настроить заново. Скрипт установки обнаружит старую версию и предложит сделать это автоматически. Вручную:

```sh
mv /etc/config/netshift /etc/config/netshift-070
wget -O /etc/config/netshift https://raw.githubusercontent.com/ArmAGEDDon1109/netshift/refs/heads/main/netshift/files/etc/config/netshift
# затем настроить заново через LuCI или UCI
```

</details>

## Установка NetShift

Полная инструкция - в [документации](https://podkop.net/docs/install/).

Для установки и обновления достаточно одного скрипта:

```sh
sh <(wget -O - https://raw.githubusercontent.com/ArmAGEDDon1109/netshift/refs/heads/main/install.sh)
```

Интерфейс появится в LuCI: **Services → NetShift**.

`install.sh` после установки пакетов проверяет **`kmod-veth`** (если `.ipk` ставили без зависимостей — доустановит из фида OpenWrt).

<details>
<summary><b>Готовые community-списки</b></summary>

Готовые наборы доменов/подсетей, которые можно добавить в секцию через `community_lists` (в UI - чекбоксами). Списки обновляются автоматически:

`russia_inside` · `russia_outside` · `ukraine_inside` · `geoblock` · `block` · `porn` · `news` · `anime` · `youtube` · `hdrezka` · `tiktok` · `google_ai` · `google_play` · `hodca` · `discord` · `meta` · `twitter` · `cloudflare` · `cloudfront` · `digitalocean` · `hetzner` · `ovh` · `telegram` · `roblox`

```sh
uci add_list netshift.my_sub.community_lists='youtube'
uci add_list netshift.my_sub.community_lists='telegram'
uci commit netshift
```

</details>

<details>
<summary><b>Настройка подписки (Subscription URL) через UCI</b></summary>

Поддерживаются любые подписки (remnawave · 3x-ui · marzban · github) в форматах **base64 · список URI · Clash · Xray JSON**, в т.ч. **gzip-сжатые** ответы. При скачивании подписки отправляются заголовки:

| Заголовок | Значение |
|---|---|
| `User-Agent` | подбирается автоматически (`singbox/<версия>` или клиентский, см. формат) |
| `X-HWID` | уникальный идентификатор роутера |
| `X-Device-OS` | `OpenWrt Linux` |
| `X-Device-Model` | модель роутера |
| `X-Ver-OS` | версия ядра |

```sh
uci set netshift.my_sub=section
uci set netshift.my_sub.connection_type='proxy'
uci set netshift.my_sub.proxy_config_type='subscription'
uci set netshift.my_sub.subscription_url='https://your-provider.com/api/sub'
uci set netshift.my_sub.subscription_update_interval='1h'
uci add_list netshift.my_sub.community_lists='russia_inside'
uci commit netshift
```

**Несколько подписок** в одной секции - добавьте `subscription_url` списком (в UI - поле с «+»); все фиды скачиваются и объединяются в один набор узлов без дублей:

```sh
uci add_list netshift.my_sub.subscription_url='https://provider-a.com/sub'
uci add_list netshift.my_sub.subscription_url='https://provider-b.com/sub'
```

**Фильтр серверов** по ключевым словам - белый/чёрный список (регистр не важен, работает и по эмодзи):

```sh
uci add_list netshift.my_sub.subscription_filter_include='🇩🇪'
uci add_list netshift.my_sub.subscription_filter_exclude='trial'
```

**Группировка серверов** - собирает узлы в URLTest-группы и добавляет авто-выбор «⚡ Самый быстрый» среди всех групп (при ≥2 группах он же выбор по умолчанию; ручной выбор группы сохраняется):

```sh
# off | country (по флагу страны) | prefix (по первым N символам имени)
uci set netshift.my_sub.subscription_group_mode='country'
# для prefix: сколько первых символов имени брать (по умолчанию 2)
uci set netshift.my_sub.subscription_group_prefix_len='2'
```

**Предпочтительный формат** - для панелей, которые отдают нужные узлы (например xhttp / Hysteria2) только под определённым клиентом:

```sh
# auto | xray (Xray JSON, UA как у Happ) | singbox
uci set netshift.my_sub.subscription_format_preference='auto'
```

**Подписки по IP-хосту и «кривой» HTTPS** - можно указать подписку с IP вместо домена (например `https://22.23.43.52:2096/sub/xxxx`); для панелей с самоподписанным / несовпадающим сертификатом включите небезопасный TLS:

```sh
uci set netshift.my_sub.subscription_allow_insecure='1'
```

Ручное обновление подписки и очистка кеша:

```sh
/usr/bin/netshift subscription_update          # перечитать и применить
# Очистка кеша всех подписок и повторное скачивание - кнопка во вкладке «Диагностика»
```

</details>

<details>
<summary><b>Менеджер компонентов: ядро sing-box-extended (xhttp) и самообновление</b></summary>

Вкладка **Менеджер компонентов** в LuCI управляет NetShift и ядром sing-box в одном месте - три карточки: **NetShift** / **sing-box (stock)** / **sing-box (extended)**. Установленная версия видна сразу, статус (актуально / устарело / не установлено) и кнопка «Проверить обновление» - по нажатию.

**Переключение ядра** между стабильным sing-box и сборкой **sing-box-extended**:

- **Install extended** - расширенное ядро (даёт клиентский транспорт **xhttp**, только клиентский режим). Также поддерживается **VMess**.
- **Install stable** - вернуться на стабильное ядро.

Смена ядра безопасна: перед переключением проверяется и при необходимости чинится связь, делается бэкап; при сбое - **автооткат**, роутер никогда не остаётся без рабочего ядра. По умолчанию стоит стабильное - extended включается по желанию.

**Самообновление NetShift** - кнопка обновления прямо из веб-интерфейса: асинхронно, с бэкапом конфига, проверкой фактической версии после установки и без риска «окирпичивания». Русская локализация обновляется только если уже установлена.

</details>

<details>
<summary><b>Дополнительные настройки (IPv6, блокировка DoH, глобальный прокси, DNS через прокси)</b></summary>

Все опции - в секции `settings` (`0` - выкл, `1` - вкл):

```sh
# Полная маршрутизация IPv6 через туннель (v6 tproxy / DNS / FakeIP). По умолчанию выкл.
uci set netshift.settings.enable_ipv6='1'

# Блокировка DoH: клиенты в сети не обойдут DNS роутера через DNS-over-HTTPS
# (режет известные DoH-эндпоинты IPv4 + IPv6 на уровне маршрутов sing-box).
uci set netshift.settings.block_doh='1'

# Глобальный прокси: ВЕСЬ трафик через выбранный outbound (а не только избранное).
# Только при явном включении - иначе действует выборочная маршрутизация.
uci set netshift.settings.global_proxy='1'

# DNS через прокси (detour): DNS-запросы идут через туннель.
uci set netshift.settings.dns_via_outbound='1'

# Блокировать QUIC (заставляет приложения откатываться на TCP/TLS).
uci set netshift.settings.disable_quic='1'

uci commit netshift
```

> По умолчанию NetShift гонит в sing-box **только** проксируемые подсети/домены, остальное - напрямую (выборочная маркировка). Режим «весь трафик в туннель» включается **только** опцией `global_proxy`.

</details>

## История изменений

Полный список изменений по версиям - на странице [Releases](https://github.com/ArmAGEDDon1109/netshift/releases) (OpenWrt **24.10** — `.ipk`, **25.12** — `.apk`). Анонсы обновлений публикуются в [Telegram-канале](https://t.me/netshift_news).

Коротко о крупных вехах:

| Версия | Главное |
|---|---|
| **0.9.1** | Авто-выбор «⚡ Самый быстрый» среди групп (URLTest над URLTest'ами) |
| **0.9.0** | Меньше ошибок «лимит GitHub API» (обход через redirect-путь github.com); фикс старого `option subscription_url` |
| **0.8.9** | Универсальная группировка подписки (страна / префикс имени); поддержка gzip-подписок; фикс ложного «версия устарела» |
| **0.8.7-0.8.8** | Критфикс маршрутизации 2-й секции; выборочная маркировка (меньше нагрузки CPU); Hysteria2 + xhttp везде; несколько подписок; надёжное самообновление |
| **0.8.6** | IPv6 · блокировка DoH · вкладка «Менеджер компонентов» · самообновление · подписки по IP / небезопасный TLS · глобальный прокси · DNS через прокси · watchdog |
| **0.8.5** | VMess (extended) · надёжная смена ядра с автооткатом · фильтр серверов по ключевым словам · Xray JSON + автоподбор User-Agent |
| **0.8.0** | Переименование podkop → NetShift с авто-миграцией конфигов; sing-box-extended (xhttp) из веб-интерфейса |

## Project Structure

```
.
├── netshift/                       # Бэкенд-пакет (POSIX ash + jq)
│   ├── Makefile                    # Описание OpenWrt-пакета
│   └── files/
│       ├── etc/config/netshift     # UCI-конфиг по умолчанию
│       ├── etc/init.d/netshift     # procd init-скрипт
│       └── usr/
│           ├── bin/netshift        # Точка входа CLI (диспетчер команд)
│           └── lib/                # constants, helpers, nft, rulesets,
│                                   #   sing_box_config_*, updater, logging
│
├── luci-app-netshift/              # LuCI веб-интерфейс
│   ├── Makefile
│   ├── htdocs/.../view/netshift/   # main.js (автоген) + hand-written views
│   ├── po/                         # Переводы (генерируются из fe-app)
│   └── root/                       # menu.d · acl.d · uci-defaults
│
├── fe-app-netshift/                # TypeScript-исходник для main.js (tsup)
│   ├── src/netshift/               # fetchers · methods · services · tabs
│   ├── src/{validators,helpers,icons,partials}
│   └── locales/                    # Исходные переводы (netshift.pot / .po)
│
├── sdk/                            # Базовые образы OpenWrt SDK
├── Dockerfile-ipk · Dockerfile-apk # Сборка пакетов
└── install.sh                      # Установщик + миграция с podkop
```

## Build Artifacts

Пакеты собираются в Docker-образах OpenWrt SDK (`.ipk` — OpenWrt 24.10, `.apk` — OpenWrt 25.12):

- **CI на `main`:** [`.github/workflows/build-packages.yml`](.github/workflows/build-packages.yml) — артефакты `openwrt-24.10-ipk-*` и `openwrt-25.12-apk-*` в Actions после каждого push.
- **Релиз:** [`.github/workflows/build.yml`](.github/workflows/build.yml) — GitHub Release при push git-тега.

| Пакет | Формат | Назначение |
|---|---|---|
| `netshift` | `.ipk` / `.apk` | Бэкенд: CLI, init-скрипт, библиотеки, UCI-конфиг |
| `luci-app-netshift` | `.ipk` / `.apk` | Веб-интерфейс LuCI |
| `luci-i18n-netshift-ru` | `.ipk` / `.apk` | Русская локализация интерфейса |

Локальная сборка:

```sh
# ipk (OpenWrt 24.10, opkg)
docker build -f Dockerfile-ipk --build-arg NETSHIFT_VERSION=0.9.1 -t netshift:ipk .

# apk (новые сборки OpenWrt 25.12+, apk)
docker build -f Dockerfile-apk --build-arg NETSHIFT_VERSION=0.9.1 -t netshift:apk .
```

> Требуется sing-box >= 1.12.0, jq >= 1.7.1 и coreutils-base64 >= 9.7 на целевом устройстве.

## Star History

<a href="https://www.star-history.com/#yandexru45/netshift&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=yandexru45/netshift&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=yandexru45/netshift&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=yandexru45/netshift&type=Date" />
 </picture>
</a>

## Credits

- [itdoginfo/podkop](https://github.com/itdoginfo/podkop) - исходный проект, форком которого является NetShift.
- [sing-box](https://github.com/SagerNet/sing-box) - движок маршрутизации.

Лицензия: **GPL-2.0-or-later** - см. [LICENSE](LICENSE).

> [!IMPORTANT]
> Pull Request принимаются только после согласования с авторами в [Telegram-чате](https://t.me/netshift_chat/17).
