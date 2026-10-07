# Private DNS Auto Toggle (Magisk)

Модуль Magisk, который **автоматически выключает «Приватный DNS» (Private DNS) на время работы VPN** и включает его обратно, когда VPN отключается.

## Зачем это нужно

Многие VPN-клиенты не перехватывают DNS-запросы, если в системе включён Private DNS (DNS-over-TLS). В итоге запросы уходят на указанный вручную DoT-сервер мимо VPN — получается утечка DNS и часть сайтов может не открываться. Модуль решает это: пока активен VPN, Private DNS переводится в режим **Off**, а после отключения VPN возвращается ваш прежний режим и адрес сервера.

## Что делает модуль

* Раз в несколько секунд проверяет, активен ли VPN (через `dumpsys connectivity`, поле `Transports` — надёжно и без ложных срабатываний на `NOT_VPN`).
* При появлении VPN: запоминает текущие `private_dns_mode` и `private_dns_specifier`, затем ставит `private_dns_mode=off`.
* При отключении VPN: возвращает сохранённые значения (или «Автоматически» = `opportunistic`, если сохранённых нет).
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
| `INTERVAL` | `5` | Период проверки VPN, сек. |
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
* `common.sh` — вся логика: определение VPN, чтение/сохранение настроек, цикл наблюдения.
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
   При включении VPN появляется строка `VPN active -> Private DNS disabled`, при выключении — `VPN inactive -> Private DNS restored`.
3. Принудительно запустите разовую проверку (кнопка **Action** или):
   ```sh
   su -c 'sh /data/adb/modules/private_dns_auto_toggle/action.sh'
   ```
4. Проверьте, видит ли система VPN в принципе:
   ```sh
   su -c 'dumpsys connectivity | grep -m1 Transports'
   ```
   При активном VPN должно быть что-то вроде `Transports: WIFI&VPN`.

## Требования

* Android 9+ (API 28) — там появился Private DNS.
* Magisk 20.4+ (или KernelSU с поддержкой `late_start service`).
* Root (модуль сам по себе даёт root-контекст).

## Лицензия

MIT — см. [LICENSE](LICENSE).
 
