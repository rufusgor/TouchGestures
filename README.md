# TouchGestures

**[Русский](#русский) · [English](#english)**

Multi-touch gestures for external touch monitors on macOS — scrolling, pinch-to-zoom, rotation and swipes, like on a trackpad.

Мультитач-жесты для внешних сенсорных мониторов на macOS — прокрутка, масштаб, поворот и свайпы, как на тачпаде.

---

## Русский

### Зачем

macOS не поддерживает сенсорные мониторы: USB-тачскрин работает как абсолютная мышь, только одним пальцем — клик и перетаскивание. Мультитач, прокрутка двумя пальцами и pinch недоступны.

TouchGestures читает касания напрямую с HID-дигитайзера монитора и превращает их в события, которые macOS и приложения понимают как жесты тачпада и мыши.

### Возможности

| Пальцы | Жест | Что получает система |
|---|---|---|
| 1 | тап, двойной тап | левый клик, двойной клик |
| 1 | сдвиг | перетаскивание |
| 1 | удержание 0,6 с | правый клик (контекстное меню) |
| 2 | сдвиг | плавная прокрутка с инерцией, контент следует за пальцами |
| 2 | разведение / сведение | масштаб (`magnify`) — Safari, Preview, Карты… |
| 2 | поворот | поворот (`rotate`) — Preview, Фото… |
| 2 | тап (пальцы рядом) | правый клик |
| 3 | свайп вверх / вниз | Mission Control / окна приложения |
| 3 | свайп влево / вправо | соседний рабочий стол |

А также:

- **Значок в строке меню**, без Дока: состояние мониторов, настройка, автозапуск, выход.
- **Несколько сенсорных мониторов**: каждый привязывается к своему экрану автоматически (по общему порту USB-C) или калибровкой касанием — «Коснитесь этого экрана».
- **Курсор скрывается при касании** и появляется снова, когда двигают настоящую мышь или тачпад.
- **Плавность**: касания выравниваются по частоте обновления экрана (60, 144 Гц…) по аппаратным меткам времени, как touch resampling в iOS/Android.
- **Устойчивость к сбоям панели**: потеря пальца на 30–110 мс, смена ID пальца, «прыжки» при касании второго пальца не рвут жест и не дают ложных кликов.
- **При выходе** монитор возвращается в обычный режим мыши.

### Совместимость

- macOS 14 Sonoma и новее, Apple Silicon (проверено на M-серии, macOS 27).
- Мониторы с HID-дигитайзером по протоколу Windows (Precision Touchscreen / Win8+). Проверено на ILITEK-TP (мониторы AQ16TH, AQ14T). Другие тачскрины с таким протоколом, скорее всего, тоже заработают.

### Установка

1. Скачайте `TouchGestures.zip` из [Releases](../../releases), распакуйте и перенесите `TouchGestures.app` в «Программы».
2. Первый запуск: приложение подписано собственным сертификатом, а не Apple, поэтому macOS его заблокирует. Откройте его правым кликом → «Открыть» или выполните:
   ```bash
   xattr -dr com.apple.quarantine /Applications/TouchGestures.app
   ```
3. Выдайте разрешения в **Системные настройки → Конфиденциальность и безопасность**:
   - **Универсальный доступ** — чтобы отправлять клики, прокрутку и жесты;
   - **Мониторинг ввода** — чтобы читать касания с монитора.

   Пока разрешений нет, значок в строке меню перечёркнут, а в меню есть кнопки, открывающие нужные разделы. Если после выдачи «Мониторинга ввода» значок не изменился — выберите «Выйти» и запустите приложение снова.
4. При желании включите в меню «Запускать при входе в систему».

> Пока приложение не запущено, монитор работает как обычная мышь (одним пальцем). Мультитач включается при запуске и выключается при выходе.

### Несколько мониторов

У каждого сенсорного монитора свой экран. Он выбирается так:

1. по калибровке, если она делалась;
2. по общему порту USB-C — если монитор подключён одним кабелем (изображение и USB);
3. по порядку — на свободные внешние экраны слева направо.

Если касания попадают не на тот экран — меню → **«Настроить сенсорные мониторы…»** и коснитесь каждого экрана по очереди. «Сбросить настройку мониторов» возвращает автоматический выбор.

### Журнал для отладки

```bash
defaults write app.TouchGestures DebugLog -bool true
```

После перезапуска приложение пишет сырые касания и все решения распознавания в `~/Library/Logs/TouchGestures/gestures.log`. Выключить — `-bool false`.

### Сборка из исходников

**Что нужно:** macOS 14+, Apple Silicon или Intel, Xcode или только Command Line Tools (Swift 5.9+). Проверить и установить:

```bash
swift --version          # должен быть Swift 5.9 или новее
xcode-select --install   # если swift не найден
```

**1. Скачать исходники**

```bash
git clone https://github.com/rufusgor/TouchGestures.git
cd TouchGestures
```

**2. Один раз — создать сертификат подписи** (рекомендуется)

```bash
scripts/make-signing-identity.sh
```

Скрипт создаёт самоподписанный сертификат в отдельной связке ключей `signing/TouchGestures-signing.keychain-db` (без пароля, ваша основная связка не затрагивается, в git не попадает). macOS привязывает разрешения «Универсальный доступ» и «Мониторинг ввода» к подписи: с этим сертификатом они сохраняются между пересборками, без него (ad-hoc) — сбрасываются после каждой сборки.

**3. Собрать приложение**

```bash
scripts/build-app.sh            # → build/TouchGestures.app
scripts/build-app.sh --install  # то же и копия в /Applications (закрывает запущенную версию)
```

Скрипт собирает release-версию (`swift build -c release --product TouchGestures`), складывает пакет `.app` с `Resources/TouchGestures-Info.plist` и подписывает. Сертификат выбирается по порядку: `CODESIGN_IDENTITY="…"` из окружения → сертификат проекта из шага 2 → «Apple Development» / «Developer ID Application» из вашей связки ключей → ad-hoc. Какой использован, скрипт пишет в конце.

**4. Запустить**

```bash
open build/TouchGestures.app
```

Дальше — разрешения, как в разделе «Установка», шаг 3.

**Для разработки**

```bash
swift build                     # собрать всё (отладочная версия)
swift run MultiTouchDemo        # демо-окно: показывает, что распознано и что получает приложение
swift run MultiTouchDemo -touchScreen 1   # демо с явным выбором экрана (индекс в списке экранов)
```

Демо запускается из терминала, поэтому разрешения нужны самому терминалу (Terminal, iTerm…).

**Архив для релиза**

```bash
scripts/build-app.sh
ditto -c -k --keepParent build/TouchGestures.app build/TouchGestures.zip
```

### Как это устроено

| Файл | Что делает |
|---|---|
| `Sources/TouchCore/MultiTouch.swift` | Чтение HID-отчётов дигитайзера (`IOHIDManager`), разбор report descriptor, сборка кадров касаний; включение мультитач-режима панели (чтение feature-отчёта, как в Windows) и возврат в режим мыши сбросом USB |
| `Sources/TouchCore/TouchResampler.swift` | Выравнивание касаний по кадрам экрана, интерполяция по каждому пальцу |
| `Sources/TouchCore/TouchMouseEmulator.swift` | Один палец → клики, перетаскивание, правый клик удержанием |
| `Sources/TouchCore/TrackpadGestureEmulator.swift` | Два и три пальца → прокрутка с инерцией, масштаб, поворот, свайпы; выбор и исправление типа жеста |
| `Sources/TouchCore/TouchScreenMapping.swift` | Какой экран у какого монитора |
| `Sources/TouchCore/TouchCursorHider.swift` | Скрытие курсора при касании |
| `Sources/TouchGestures/` | Приложение в строке меню, калибровка, журнал |
| `Sources/MultiTouchDemo/` | Демо-окно |

### Ограничения

- Масштаб и поворот отправляются через недокументированные поля `CGEvent`, сопоставление монитора с экраном использует недокументированное `PortID`, скрытие курсора в фоне — недокументированное свойство WindowServer. В будущих версиях macOS это может перестать работать.
- В начале жеста (первые ~16 pt) масштаб с почти неподвижным пальцем и прокрутка с отстающим пальцем выглядят одинаково — жест может начаться как прокрутка и через долю секунды переключиться на масштаб.
- Если приложение аварийно завершится, монитор останется в мультитач-режиме и не будет работать как мышь, пока его не переподключить.

---

## English

### Why

macOS has no support for touch monitors: a USB touchscreen acts as an absolute mouse with a single finger — click and drag only. Multi-touch, two-finger scrolling and pinch are not available.

TouchGestures reads touches directly from the monitor's HID digitizer and turns them into events that macOS and apps understand as trackpad and mouse gestures.

### Features

| Fingers | Gesture | What the system receives |
|---|---|---|
| 1 | tap, double tap | left click, double click |
| 1 | move | drag |
| 1 | hold 0.6 s | right click (context menu) |
| 2 | move | smooth scrolling with momentum, content follows the fingers |
| 2 | pinch | magnify — Safari, Preview, Maps… |
| 2 | rotate | rotate — Preview, Photos… |
| 2 | tap (fingers close together) | right click |
| 3 | swipe up / down | Mission Control / App Exposé |
| 3 | swipe left / right | adjacent Space |

Also:

- **Menu bar icon**, no Dock icon: monitor status, setup, launch at login, quit.
- **Multiple touch monitors**: each one is mapped to its own display automatically (via the shared USB-C port) or by touch calibration — "Touch this screen".
- **The cursor hides on touch** and reappears when a real mouse or trackpad moves.
- **Smoothness**: touches are resampled to the display refresh rate (60, 144 Hz…) using hardware timestamps, like touch resampling on iOS/Android.
- **Robust against panel glitches**: a finger lost for 30–110 ms, a finger ID change, or a "jump" when the second finger lands do not break the gesture or cause false clicks.
- **On quit** the monitor switches back to the regular mouse mode.

### Compatibility

- macOS 14 Sonoma or later, Apple Silicon (tested on M-series, macOS 27).
- Monitors with a Windows-protocol HID digitizer (Precision Touchscreen / Win8+). Tested with ILITEK-TP (AQ16TH, AQ14T monitors). Other touchscreens using this protocol will most likely work too.

### Installation

1. Download `TouchGestures.zip` from [Releases](../../releases), unzip it and move `TouchGestures.app` to Applications.
2. First launch: the app is signed with a self-signed certificate, not by Apple, so macOS will block it. Open it with right click → Open, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/TouchGestures.app
   ```
3. Grant permissions in **System Settings → Privacy & Security**:
   - **Accessibility** — to send clicks, scrolling and gestures;
   - **Input Monitoring** — to read touches from the monitor.

   Until they are granted, the menu bar icon is crossed out and the menu has buttons that open the right settings pages. If the icon does not change after granting Input Monitoring, choose Quit and launch the app again.
4. Optionally enable "Launch at login" in the menu.

> While the app is not running, the monitor works as a regular mouse (one finger). Multi-touch is enabled on launch and disabled on quit.

### Multiple monitors

Each touch monitor gets its own display, chosen by:

1. calibration, if it was done;
2. the shared USB-C port — when the monitor is connected with a single cable (video and USB);
3. order — free external displays from left to right.

If touches land on the wrong display, use menu → **«Настроить сенсорные мониторы…»** ("Set up touch monitors…") and touch each screen in turn. **«Сбросить настройку мониторов»** ("Reset monitor setup") returns to automatic mapping. The app interface is in Russian.

### Debug log

```bash
defaults write app.TouchGestures DebugLog -bool true
```

After a restart the app writes raw touches and every recognition decision to `~/Library/Logs/TouchGestures/gestures.log`. Turn it off with `-bool false`.

### Building from source

**Requirements:** macOS 14+, Apple Silicon or Intel, Xcode or just the Command Line Tools (Swift 5.9+). To check and install:

```bash
swift --version          # must be Swift 5.9 or later
xcode-select --install   # if swift is not found
```

**1. Get the source**

```bash
git clone https://github.com/rufusgor/TouchGestures.git
cd TouchGestures
```

**2. Once — create a signing certificate** (recommended)

```bash
scripts/make-signing-identity.sh
```

The script creates a self-signed certificate in a separate keychain `signing/TouchGestures-signing.keychain-db` (no password, your login keychain is untouched, not committed to git). macOS ties the Accessibility and Input Monitoring permissions to the code signature: with this certificate they survive rebuilds; without it (ad-hoc) they are reset after every build.

**3. Build the app**

```bash
scripts/build-app.sh            # → build/TouchGestures.app
scripts/build-app.sh --install  # same, plus a copy in /Applications (quits the running version)
```

The script builds the release configuration (`swift build -c release --product TouchGestures`), assembles the `.app` bundle with `Resources/TouchGestures-Info.plist` and signs it. The certificate is chosen in this order: `CODESIGN_IDENTITY="…"` from the environment → the project certificate from step 2 → "Apple Development" / "Developer ID Application" from your keychain → ad-hoc. The script prints which one was used.

**4. Run**

```bash
open build/TouchGestures.app
```

Then grant permissions as in Installation, step 3.

**For development**

```bash
swift build                     # build everything (debug)
swift run MultiTouchDemo        # demo window: shows what is recognized and what the app receives
swift run MultiTouchDemo -touchScreen 1   # demo with an explicit display (index in the screen list)
```

The demo runs from a terminal, so the permissions are needed by the terminal app itself (Terminal, iTerm…).

**Release archive**

```bash
scripts/build-app.sh
ditto -c -k --keepParent build/TouchGestures.app build/TouchGestures.zip
```

### How it works

| File | What it does |
|---|---|
| `Sources/TouchCore/MultiTouch.swift` | Reads digitizer HID reports (`IOHIDManager`), parses the report descriptor, assembles touch frames; switches the panel to multi-touch mode (reading a feature report, as Windows does) and back to mouse mode via USB reset |
| `Sources/TouchCore/TouchResampler.swift` | Resamples touches to display frames, per-finger interpolation |
| `Sources/TouchCore/TouchMouseEmulator.swift` | One finger → clicks, drag, right click on hold |
| `Sources/TouchCore/TrackpadGestureEmulator.swift` | Two and three fingers → scrolling with momentum, magnify, rotate, swipes; gesture type selection and correction |
| `Sources/TouchCore/TouchScreenMapping.swift` | Which display belongs to which monitor |
| `Sources/TouchCore/TouchCursorHider.swift` | Hides the cursor on touch |
| `Sources/TouchGestures/` | Menu bar app, calibration, log |
| `Sources/MultiTouchDemo/` | Demo window |

### Limitations

- Magnify and rotate are sent via undocumented `CGEvent` fields, monitor-to-display mapping uses the undocumented `PortID`, and hiding the cursor in the background uses an undocumented WindowServer property. Future macOS versions may break them.
- At the start of a gesture (first ~16 pt) a pinch with one nearly static finger and a scroll with a lagging finger look the same — the gesture may start as a scroll and switch to magnify a fraction of a second later.
- If the app crashes, the monitor stays in multi-touch mode and will not work as a mouse until it is reconnected.
