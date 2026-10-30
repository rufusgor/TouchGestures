#!/bin/bash
# Сборка TouchGestures.app (значок в строке меню, без Дока) в build/.
#   scripts/build-app.sh            — собрать и подписать
#   scripts/build-app.sh --install  — ещё и скопировать в /Applications
#
# Подпись, по порядку:
#   1. CODESIGN_IDENTITY="…" scripts/build-app.sh — указанный сертификат;
#   2. собственный самоподписанный сертификат проекта из signing/TouchGestures-signing.keychain-db
#      (связка без пароля, только для подписи этого приложения);
#   3. «Apple Development» / «Developer ID Application» из связки ключей пользователя;
#   4. ad-hoc — тогда разрешения придётся выдавать заново после каждой сборки.
# С сертификатом (1–3) macOS привязывает разрешения («Мониторинг ввода», «Универсальный доступ»)
# к нему, а не к конкретной сборке, и они сохраняются между пересборками.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_KEYCHAIN="$PWD/signing/TouchGestures-signing.keychain-db"

swift build -c release --product TouchGestures

APP=build/TouchGestures.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/TouchGestures" "$APP/Contents/MacOS/"
cp Resources/TouchGestures-Info.plist "$APP/Contents/Info.plist"

signed=""
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp=none --sign "$CODESIGN_IDENTITY" "$APP" && signed="$CODESIGN_IDENTITY"
fi
if [[ -z "$signed" && -f "$PROJECT_KEYCHAIN" ]]; then
    security unlock-keychain -p "" "$PROJECT_KEYCHAIN"
    HASH=$(security find-identity -p codesigning "$PROJECT_KEYCHAIN" | awk '/1\)/ { print $2; exit }')
    if [[ -n "$HASH" ]] && codesign --force --timestamp=none --keychain "$PROJECT_KEYCHAIN" \
            --sign "$HASH" "$APP" 2>/dev/null; then
        signed="TouchGestures Local Signing"
    fi
fi
if [[ -z "$signed" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')
    if [[ -n "$IDENTITY" ]] && codesign --force --timestamp=none --sign "$IDENTITY" "$APP" 2>/dev/null; then
        signed="$IDENTITY"
    fi
fi
if [[ -n "$signed" ]]; then
    echo "Подписано: $signed"
else
    # Сертификат недоступен (например, связка ключей заблокирована) — подписываем ad-hoc.
    codesign --force --sign - "$APP"
    echo "Подписано ad-hoc: разрешения придётся выдавать заново после каждой сборки"
fi

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "TouchGestures"' 2>/dev/null || true
    rm -rf /Applications/TouchGestures.app
    cp -R "$APP" /Applications/
    echo "Установлено: /Applications/TouchGestures.app"
else
    echo "Готово: $APP"
fi
