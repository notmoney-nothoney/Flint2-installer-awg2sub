<div align="center">

**🌐 Language / Язык:** [🇷🇺 Русский](#-русский) · [🇬🇧 English](#-english)

</div>

---

<a id="-русский"></a>

# Flint2-installer-awg2sub 🇷🇺

Автоматический установщик для **GL.iNet Flint 2 (GL-MT6000)**, который связывает **штатный WireGuard Server (`wgserver`)** с ядром **Mihomo (Clash.Meta)** поверх вашей proxy-подписки.

В отличие от сборок со сторонними виртуальными интерфейсами, решение работает **нативно поверх встроенного VPN-сервера GL.iNet**: вы продолжаете управлять клиентами и QR-кодами из стандартного веб-интерфейса роутера, а весь входящий VPN-трафик прозрачно уходит в подписку с обходом блокировок и умной маршрутизацией.

---

## Как это работает

```
    [Телефон / Ноутбук (вне дома)]
                  │
                  ▼  (штатная обфускация WG)
           [ wgserver ]  ◄── (127.0.0.1:51820) ── [ VPN Client (10.1.1.2) ]
                  │                                        ▲
                  ▼  (Policy Routing: priority 50)         │ (штатные политики GL.iNet, добавить конфиг)
             [ utun ]  (Mihomo TUN, gvisor stack)   [ Домашние устройства ]
                  │
                  ├──► RU / Локальные сети ──► DIRECT (напрямую через домашний WAN)
                  └──► Остальной мир ────────► url-test (лучший сервер из подписки)
```

### Как течёт трафик в итоге
- **Телефон в мобильной сети** → внешний IP роутера `:51820` → `wgserver` → `utun` (Mihomo) → сервер из подписки (российские сайты и локальная сеть идут напрямую через `DIRECT`).
- **Домашний ПК / ТВ** → политика GL.iNet → локальный `VPN Client` (`10.1.1.2`) → петля `127.0.0.1:51820` → `wgserver` → `utun` (Mihomo) → сервер из подписки.

---

## Часть 1. Что делает скрипт `setup_awg_sub.sh` (6 шагов)

1. **Скачивает ядро Mihomo:** проверяет наличие утилит `awg`/`wg` и скачивает актуальный бинарник Mihomo (Clash Meta) под ARM64 в `/usr/bin/mihomo`.
2. **Поднимает штатный WG-сервер (`wgserver`) и создаёт локального пира:**
   * Если роутер чистый и VPN-сервер ни разу не включался — скрипт сам генерирует ключи, создаёт сервер `wireguard_server.main_server` на порту `51820` с включённой обфускацией AmneziaWG, открывает порт в файрволе и запускает интерфейс `wgserver`. Если сервер уже работает — просто подхватывает его.
   * Создаёт внутри штатного сервера специального пира `peer_router` (`router-local`) с изолированным адресом `10.1.1.2/32` и сохраняет готовый клиентский конфиг в `/root/router-local.conf` (уже с `Endpoint = 127.0.0.1:51820`, `DNS = 1.1.1.1` и параметрами обфускации сервера).
3. **Привязывает подписку к Mihomo (`/etc/mihomo/config.yaml`):**
   * Записывает вашу ссылку подписки в `proxy-providers` (запрашивает её с `User-Agent: clash.meta` и обновляет каждый час).
   * Поднимает виртуальный сетевой интерфейс `utun` и локальный DNS-сервер на порту `1053` (`fake-ip`).
   * Настраивает группу `PROXY` в режиме `url-test` (автоматически пингует все серверы из подписки каждые 5 минут и выбирает самый быстрый, отфильтровывая информационные строки вроде «Остаток трафика»).
   * Загружает базы `geoip.metadb` и `geosite.dat`, направляя российские домены, IP-адреса и локальные подсети напрямую (`DIRECT`), а зарубежный трафик — в подписку.
4. **Замыкает трафик `wgserver` на Mihomo:**
   * Запускает службу `/etc/init.d/mihomo` в автозагрузку.
   * Добавляет правило ядра (`priority 50: iif wgserver lookup 200`), которое перехватывает весь трафик, входящий на штатный `wgserver`, и отправляет его в туннель `utun` (Mihomo).
   * Прописывает в `/etc/firewall.user` правила NAT, перехвата DNS (порт `53` → `1053`) и корректировки MTU (`TCPMSS`).
5. **Ставит веб-интерфейс (по желанию):** скачивает панель управления **Metacubexd**, которая открывается по адресу `http://192.168.0.1:9090/ui` (там можно при желании вручную выбрать конкретную страну из подписки).
6. **Защищает от сброса при обновлении прошивки:** добавляет все скрипты, конфиги и бинарник Mihomo в `/etc/sysupgrade.conf`.

---

## Требования

- Роутер **GL.iNet Flint 2 (GL-MT6000)** (или другая модель GL.iNet на OpenWrt 21.02+ / `arm64` с поддержкой AmneziaWG в прошивке). Проверено на 4.11.1 beta1.
- Ссылка на подписку в формате Clash / Mihomo.
- Для доступа с мобильных устройств извне — публичный IPv4 от провайдера или настроенный штатный DDNS в веб-интерфейсе роутера.

---

## Установка в одну строку

Подключитесь к роутеру по SSH (`ssh root@192.168.0.1`) и выполните команду, подставив свою ссылку на подписку:

```bash
curl -fsSL https://raw.githubusercontent.com/notmoney-nothoney/Flint2-installer-awg2sub/main/setup_awg_sub.sh -o /root/setup_awg_sub.sh && chmod +x /root/setup_awg_sub.sh && sh /root/setup_awg_sub.sh "https://your-provider.com/sub/YOUR_TOKEN"
```

### Полностью автоматический режим (`--auto`)
Разворачивает всю связку без пауз и вопросов, устанавливает веб-панель и прописывает сохранение при обновлении прошивки:

```bash
sh /root/setup_awg_sub.sh "https://your-provider.com/sub/YOUR_TOKEN" --auto
```

---

## Часть 2. Что делаете вы после запуска скрипта

1. **Для домашних устройств (ПК, телевизор, приставка):**
   * Откройте в веб-морде GL.iNet **VPN → WireGuard / AmneziaWG Client**.
   * Найдите автоматически созданную группу **`Mihomo-Sub`** с профилем **`router-local`** и просто нажмите **Start** (вручную ничего копировать и вставлять не нужно; при необходимости резервный файл лежит в `/root/router-local.conf`).
   * В стандартном разделе **VPN Dashboard** назначьте этот туннель нужным домашним устройствам или сайтам.
   * Или готовый конфиг командой:

     ```bash
     cat /root/router-local.conf
     ```

2. **Для телефона и ноутбука вне дома:**
   * В веб-морде GL.iNet зайдите в **VPN → WireGuard / AmneziaWG Server → Profiles**, создайте обычный профиль (или возьмите уже созданный) и сканируйте QR-код в приложении **AmneziaWG**. Весь трафик с телефона сразу пойдёт в подписку (пир `router-local` в списке сервера не трогайте — он зарезервирован для самого роутера).
3. **Веб-панель мониторинга Mihomo:**
   * Для просмотра трафика или ручного выбора локации откройте в браузере (сразу привязывается к IP роутера):

     ```
     http://192.168.0.1:9090/ui/ или http://192.168.0.1:9090/ui/?hostname=192.168.0.1&port=9090
     ```

---

## Полное удаление (без следов)

Скачайте и запустите деинсталлятор — он остановит Mihomo, удалит пира `peer_router`, очистит правила маршрутизации, `iptables`, `sysctl.conf`, `/etc/sysupgrade.conf` и сотрёт все файлы проекта, не затрагивая штатный `wgserver` и ваши основные профили:

```bash
curl -fsSL https://raw.githubusercontent.com/notmoney-nothoney/Flint2-installer-awg2sub/main/uninstall_awg_sub.sh -o /root/uninstall_awg_sub.sh && chmod +x /root/uninstall_awg_sub.sh && sh /root/uninstall_awg_sub.sh
```

Для удаления без запроса подтверждения:

```bash
sh /root/uninstall_awg_sub.sh --force
```

---

## Отказ от ответственности

Проект предоставляется «как есть» исключительно в ознакомительных и образовательных целях для администрирования собственных сетевых устройств.

---
---

<a id="-english"></a>

# Flint2-installer-awg2sub 🇬🇧

An automatic installer for **GL.iNet Flint 2 (GL-MT6000)** that connects the **stock WireGuard Server (`wgserver`)** to the **Mihomo (Clash.Meta)** core over your proxy subscription.

Unlike builds with third-party virtual interfaces, this solution works **natively on top of GL.iNet's built-in VPN server**: you keep managing clients and QR codes from the router's standard web UI, while all incoming VPN traffic transparently flows into your subscription with censorship circumvention and smart routing.

---

## How it works

```
    [Phone / Laptop (outside home)]
                  │
                  ▼  (stock WG obfuscation)
           [ wgserver ]  ◄── (127.0.0.1:51820) ── [ VPN Client (10.1.1.2) ]
                  │                                        ▲
                  ▼  (Policy Routing: priority 50)         │ (stock GL.iNet policies, add config)
             [ utun ]  (Mihomo TUN, gvisor stack)   [ Home devices ]
                  │
                  ├──► RU / Local networks ──► DIRECT (straight through home WAN)
                  └──► Rest of the world ────► url-test (best server from subscription)
```

### How traffic flows in the end
- **Phone on mobile network** → router's public IP `:51820` → `wgserver` → `utun` (Mihomo) → server from subscription (Russian sites and the local network go directly via `DIRECT`).
- **Home PC / TV** → GL.iNet policy → local `VPN Client` (`10.1.1.2`) → loopback `127.0.0.1:51820` → `wgserver` → `utun` (Mihomo) → server from subscription.

---

## Part 1. What the `setup_awg_sub.sh` script does (6 steps)

1. **Downloads the Mihomo core:** checks for the `awg`/`wg` utilities and downloads the latest Mihomo (Clash Meta) ARM64 binary to `/usr/bin/mihomo`.
2. **Brings up the stock WG server (`wgserver`) and creates a local peer:**
   * If the router is clean and the VPN server has never been enabled, the script generates keys, creates the server `wireguard_server.main_server` on port `51820` with AmneziaWG obfuscation enabled, opens the port in the firewall, and starts the `wgserver` interface. If the server is already running, it simply picks it up.
   * Creates a special peer `peer_router` (`router-local`) inside the stock server with an isolated address `10.1.1.2/32` and saves a ready client config to `/root/router-local.conf` (already with `Endpoint = 127.0.0.1:51820`, `DNS = 1.1.1.1` and the server's obfuscation parameters).
3. **Binds the subscription to Mihomo (`/etc/mihomo/config.yaml`):**
   * Writes your subscription link into `proxy-providers` (requests it with `User-Agent: clash.meta` and updates hourly).
   * Brings up the virtual network interface `utun` and a local DNS server on port `1053` (`fake-ip`).
   * Configures the `PROXY` group in `url-test` mode (automatically pings all servers from the subscription every 5 minutes and picks the fastest, filtering out informational lines like "Traffic remaining").
   * Loads the `geoip.metadb` and `geosite.dat` databases, routing Russian domains, IP addresses, and local subnets directly (`DIRECT`), and foreign traffic into the subscription.
4. **Routes `wgserver` traffic into Mihomo:**
   * Starts the `/etc/init.d/mihomo` service on boot.
   * Adds a kernel rule (`priority 50: iif wgserver lookup 200`) that intercepts all traffic entering the stock `wgserver` and sends it into the `utun` tunnel (Mihomo).
   * Adds NAT rules to `/etc/firewall.user` for DNS interception (port `53` → `1053`) and MTU adjustment (`TCPMSS`).
5. **Installs the web UI (optional):** downloads the **Metacubexd** control panel, available at `http://192.168.0.1:9090/ui` (where you can manually pick a specific country from the subscription if desired).
6. **Protects against reset on firmware upgrade:** adds all scripts, configs, and the Mihomo binary to `/etc/sysupgrade.conf`.

---

## Requirements

- Router **GL.iNet Flint 2 (GL-MT6000)** (or another GL.iNet model on OpenWrt 21.02+ / `arm64` with AmneziaWG support in firmware). Tested on 4.11.1 beta1.
- A subscription link in Clash / Mihomo format.
- For access from mobile devices outside — a public IPv4 from your ISP or a configured stock DDNS in the router's web UI.

---

## One-line installation

Connect to the router via SSH (`ssh root@192.168.0.1`) and run the command, substituting your subscription link:

```bash
curl -fsSL https://raw.githubusercontent.com/notmoney-nothoney/Flint2-installer-awg2sub/main/setup_awg_sub.sh -o /root/setup_awg_sub.sh && chmod +x /root/setup_awg_sub.sh && sh /root/setup_awg_sub.sh "https://your-provider.com/sub/YOUR_TOKEN"
```

### Fully automatic mode (`--auto`)
Deploys the entire setup without pauses or questions, installs the web panel, and enables persistence across firmware upgrades:

```bash
sh /root/setup_awg_sub.sh "https://your-provider.com/sub/YOUR_TOKEN" --auto
```

---

## Part 2. What you do after running the script

1. **For home devices (PC, TV, set-top box):**
   * Open **VPN → WireGuard / AmneziaWG Client** in the GL.iNet web UI.
   * Find the automatically created group **`Mihomo-Sub`** with the profile **`router-local`** and just click **Start** (nothing to copy or paste manually; a backup file is available at `/root/router-local.conf` if needed).
   * In the standard **VPN Dashboard**, assign this tunnel to the desired home devices or sites.
   * Or get the ready config with:

     ```bash
     cat /root/router-local.conf
     ```

2. **For phone and laptop outside home:**
   * In the GL.iNet web UI go to **VPN → WireGuard / AmneziaWG Server → Profiles**, create a regular profile (or use an existing one), and scan the QR code in the **AmneziaWG** app. All phone traffic will immediately go into the subscription (don't touch the `router-local` peer in the server list — it's reserved for the router itself).
3. **Mihomo monitoring web panel:**
   * To view traffic or manually choose a location, open in your browser (it's bound to the router's IP automatically):

     ```
     http://192.168.0.1:9090/ui/ or http://192.168.0.1:9090/ui/?hostname=192.168.0.1&port=9090
     ```

---

## Complete removal (no traces)

Download and run the uninstaller — it stops Mihomo, removes the `peer_router` peer, clears routing rules, `iptables`, `sysctl.conf`, `/etc/sysupgrade.conf`, and erases all project files without touching the stock `wgserver` or your main profiles:

```bash
curl -fsSL https://raw.githubusercontent.com/notmoney-nothoney/Flint2-installer-awg2sub/main/uninstall_awg_sub.sh -o /root/uninstall_awg_sub.sh && chmod +x /root/uninstall_awg_sub.sh && sh /root/uninstall_awg_sub.sh
```

To remove without confirmation:

```bash
sh /root/uninstall_awg_sub.sh --force
```

---

## Disclaimer

The project is provided "as is" for informational and educational purposes only, for administering your own network devices.