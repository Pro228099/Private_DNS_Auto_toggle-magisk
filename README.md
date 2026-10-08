# Private DNS Auto Toggle (Magisk)

Модуль Magisk, который **автоматически выключает «Приватный DNS» (Private DNS) на время работы VPN** и включает его обратно, когда VPN отключается.

## Зачем это нужно

Многие VPN-клиенты не перехватывают DNS-запросы, если в системе включён Private DNS (DNS-over-TLS). В итоге запросы уходят на указанный вручную DoT-сервер мимо VPN — получается утечка DNS и часть сайтов может не открываться. Модуль решает это: пока активен VPN, Private DNS переводится в режим **Off**, а после отключения VPN возвращается ваш прежний режим и адрес сервера.

## Что делает модуль

* **Реагирует на событие, а не на таймер.** Модуль слушает системный лог (`logcat -s Vpn`) и переключается в тот момент, когда Android сообщает о подключении/отключении VPN.
* Рядом с потоком событий крутится редкая страховочная проверка (раз в `POLL_INTERVAL` секунд). Она нужна потому, что поток лога не всегда можно считать надёжным (прошивки, урезанные логи), и гарантирует, что модуль не «зависнет» в неправильном состоянии. Пока события работают, проверка ничего не логирует и почти ничего не стоит.
* Активность VPN проверяется тремя независимыми признаками: наличие интерфейса туннеля (`tun*`/`ppp*`/`pptp*`/`tap*`/`wg*`/`ipsec*`), токен `VPN` в **любой** строке `Transports` из `dumpsys connectivity` и блок `NetworkAgentInfo [VPN …]`. Раньше смотрелась только первая строка `Transports`, а на Android 12+ она часто принадлежит нижележащему Wi-Fi/мобильной сети — VPN не определялся и Private DNS не выключался. Ложные срабатывания на `NOT_VPN` из блока Capabilities исключены (матч только внутри поля `Transports`).
* При появлении VPN: запоминает текущие `private_dns_mode` и `private_dns_specifier`, затем ставит `private_dns_mode=off`.
* При отключении VPN: возвращает сохранённые значения. Если сохранённого состояния нет (Private DNS изначально был выключен), модуль ничего не меняет.
* Аккуратно переживает перезагрузку: watcher поднимается в `late_start service` после `sys.boot_completed`.
* При удалении модуля возвращает настройку Private DNS, если она была выключена.

## Установка

1. Скачайте `private_dns_auto_toggle.zip` (см. раздел «Сборка»).
2. Установите через приложение Magisk (Модули → Установить из хранилища) или KernelSU.
3. Перезагрузитесь.

После перезагрузки модуль работает автоматически. Кнопка **Action** в приложении Magisk запускает разовую проверку.

## Настройка

Файл конфигурации: `/data/adb/private_dns_auto_toggle.conf`. Формат `KEY=value`:

| Ключ | По умолчанию | Описание |
|------|--------------|----------|
| `EVENT_MODE` | `true` | Переключаться по событию из лога. `false` — старый режим с таймером. |
| `INTERVAL` | `5` | Период проверки, сек (только при `EVENT_MODE=false`). |
| `POLL_INTERVAL` | `30` | Период страховочного опроса, сек. Работает всегда, параллельно событиям. |
| `SETTLE` | `1` | Пауза после события VPN, сек, чтобы туннель успел подняться. |
| `CHECK_INTERVAL` | `10` | Задержка после загрузки перед первой проверкой, сек. |
| `AUTO_START` | `true` | Запускать watcher автоматически при загрузке. |
| `RESTORE_ON_EXIT` | `true` | Вернуть Private DNS при удалении модуля. |
| `DNS_MODE` | `off` | Режим, который ставится при активном VPN (`off` / `opportunistic` / `hostname`). |
| `LOG` | `true` | Писать лог в `/data/adb/private_dns_auto_toggle.log`. |
| `DRY_RUN` | `false` | Только логировать, ничего не менять (для отладки). |

После правки конфига перезагрузитесь либо выполните от root:

```sh
sh /data/adb/modules/private_dns_auto_toggle/action.sh
```

### Ручное управление

```sh
# разовая проверка (то же, что кнопка Action)
su -c 'sh /data/adb/modules/private_dns_auto_toggle/action.sh'

# посмотреть лог (нужно LOG=true)
su -c 'cat /data/adb/private_dns_auto_toggle.log'

# текущие настройки Private DNS
su -c 'settings get global private_dns_mode'
su -c 'settings get global private_dns_specifier'
```

## Сборка zip

В корне репозитория:

```sh
zip -r9 private_dns_auto_toggle.zip \
  module.prop common.sh service.sh action.sh uninstall.sh customize.sh \
  private_dns_auto_toggle.conf META-INF
```

Либо запустите workflow **Package Magisk module** в GitHub Actions — он соберёт zip и приложит его к релизу на тег `v*`.

## Как это работает (для разработчиков)

* `service.sh` — точка входа `late_start service`: ждёт загрузку, создаёт конфиг, запускает фоновый цикл.
* `common.sh` — вся логика: определение VPN, чтение/сохранение настроек, событийный цикл (`logcat -s Vpn` → `reconcile`) и резервный таймер.
* `reconcile` идемпотентен: файл-флаг `/data/adb/private_dns_auto_toggle.vpn` отмечает, что модуль сейчас держит Private DNS выключенным, поэтому пропущенное или лишнее событие не приводит к двойному переключению.
* `action.sh` — разовая проверка (кнопка Action).
* `uninstall.sh` — остановка watcher и восстановление Private DNS.
* `customize.sh` — права доступа и миграция конфига при обновлении.

Ключи настроек Android: `global/private_dns_mode` (`off` / `opportunistic` / `hostname`) и `global/private_dns_specifier`.

## Если не работает

1. Проверьте, что файлы модуля на месте:
   ```sh
   su -c 'ls /data/adb/modules/private_dns_auto_toggle'
   ```
   Там должны быть `service.sh`, `common.sh`, `action.sh`, `module.prop`.
2. Посмотрите лог:
   ```sh
   su -c 'cat /data/adb/private_dns_auto_toggle.log'
   ```
   При включении VPN появляется строка `VPN active -> Private DNS disabled`, при выключении — `VPN inactive -> Private DNS restored`. В скобках указан источник: `event` — сработал лог, `safety` — страховочный опрос, `startup` — проверка при старте. Если вы видите только `safety`, значит поток событий из лога в этой прошивке недоступен, но модуль всё равно работает.
3. Принудительно запустите разовую проверку (кнопка **Action** или):
   ```sh
   su -c 'sh /data/adb/modules/private_dns_auto_toggle/action.sh'
   ```
4. Проверьте, видит ли система VPN в принципе:
   ```sh
   su -c 'dumpsys connectivity | grep Transports'
   ```
   При активном VPN где-то среди сетей появляется блок с `Transports: VPN` (например `Transports: WIFI&VPN`). Модуль сканирует ВСЕ строки `Transports`, а не только первую. Если виден tun-интерфейс, модуль определит VPN и без этого.
5. Запустите кнопку **Action** — она печатает: найден ли бинарник `settings`, текущие значения, причину определения VPN и результат записи. Это самый быстрый способ понять, на каком шаге затык.

## Требования

* Android 9+ (API 28) — там появился Private DNS.
* Magisk 20.4+ (или KernelSU с поддержкой `late_start service`).
* Root (модуль сам по себе даёт root-контекст).

## Лицензия

MIT — см. [LICENSE](LICENSE).
 
(всё что сверху писал ИИ, меня не хвалите, более того, он полностью сам сделал этот репо)
