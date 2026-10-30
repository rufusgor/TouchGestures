#!/bin/bash
# Создаёт собственный самоподписанный сертификат подписи для TouchGestures в отдельной связке ключей
# signing/TouchGestures-signing.keychain-db (без пароля; основная связка ключей не затрагивается).
#
# Зачем: macOS привязывает разрешения «Универсальный доступ» и «Мониторинг ввода» к подписи.
# С ad-hoc-подписью каждая пересборка — для системы новое приложение, и разрешения сбрасываются.
# С этим сертификатом они сохраняются между пересборками. scripts/build-app.sh найдёт его сам.
#
# Запускать один раз. Повторный запуск создаёт новый сертификат — разрешения придётся выдать заново.
set -euo pipefail
cd "$(dirname "$0")/.."

KEYCHAIN="$PWD/signing/TouchGestures-signing.keychain-db"
NAME="TouchGestures Local Signing"
mkdir -p signing

if [[ -f "$KEYCHAIN" && "${1:-}" != "--force" ]]; then
    echo "Сертификат уже есть: $KEYCHAIN (пересоздать: $0 --force)"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config signing/cert.cnf \
    -keyout "$TMP/key.pem" -out signing/cert.pem 2>/dev/null
PASS=$(openssl rand -hex 12)
# -legacy: связка ключей macOS не читает PKCS#12 в формате OpenSSL 3+ по умолчанию.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in signing/cert.pem -name "$NAME" \
    -out "$TMP/cert.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in signing/cert.pem -name "$NAME" \
    -out "$TMP/cert.p12" -passout "pass:$PASS"

rm -f "$KEYCHAIN"
security create-keychain -p "" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"       # не блокировать по таймауту
security unlock-keychain -p "" "$KEYCHAIN"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null

echo "Создан сертификат «$NAME»: $KEYCHAIN"
