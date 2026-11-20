#!/bin/zsh
set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
P12="${1:-$HOME/Downloads/证书_00008140-000C610434EA801C/证书文件.p12}"
PASS="${2:?用法: ./sign-fixed.sh 证书.p12 p12密码}"
PROFILE="${PROFILE:-$HOME/Downloads/证书_00008140-000C610434EA801C/描述文件.mobileprovision}"
ENTITLEMENTS="${ENTITLEMENTS:-$BASEDIR/fixed-entitlements.plist}"
BUNDLE_ID="${BUNDLE_ID:-app.bamboo3965.leo5976}"

WORK=$(mktemp -d /tmp/appsign.XXXXXX)
trap 'security delete-keychain "$WORK/sign.keychain" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "==> 解压 IPA"
unzip -qo "$BASEDIR/APP.ipa" -d "$WORK"
APP="$WORK/Payload/APP.app"

echo "==> 修正 Bundle ID: $BUNDLE_ID"
PLIST_BUDDY=/usr/libexec/PlistBuddy
$PLIST_BUDDY -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"

echo "==> 嵌入描述文件"
cp "$PROFILE" "$APP/embedded.mobileprovision"

echo "==> 导入证书到临时钥匙串"
security create-keychain -p tmppass123 "$WORK/sign.keychain" 2>/dev/null || true
security set-keychain-settings -t 3600 -u "$WORK/sign.keychain"
if ! security import "$P12" -k "$WORK/sign.keychain" -P "$PASS" -T /usr/bin/codesign 2>/dev/null; then
  echo "    原生导入失败，尝试 OpenSSL 转换 legacy 格式..."
  OPENSSL=""
  for CAND in "$OPENSSL_BIN" /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/local/bin/openssl "$(command -v openssl 2>/dev/null)"; do
    [ -n "$CAND" ] && [ -x "$CAND" ] || continue
    if "$CAND" pkcs12 -in "$P12" -passin "pass:$PASS" -nokeys -clcerts -out /dev/null 2>/dev/null; then
      OPENSSL="$CAND"; break
    fi
  done
  [ -n "$OPENSSL" ] || { echo "!! 没有能解析该 p12 的 OpenSSL（需 OpenSSL 3.x，系统自带 LibreSSL 不支持此加密格式）"; exit 1; }
  "$OPENSSL" pkcs12 -in "$P12" -passin "pass:$PASS" -nodes -out "$WORK/keycert.pem" || {
    echo "!! 密码错误或证书损坏"; exit 1; }
  "$OPENSSL" pkcs12 -export -in "$WORK/keycert.pem" -out "$WORK/legacy.p12" \
    -passout "pass:$PASS" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
  rm -f "$WORK/keycert.pem"
  security import "$WORK/legacy.p12" -k "$WORK/sign.keychain" -P "$PASS" -T /usr/bin/codesign
fi
IDENTITY=$(security find-identity -v "$WORK/sign.keychain" 2>/dev/null | /usr/bin/grep -m1 -oE '[0-9A-Fa-f]{40}') || true
[ -n "$IDENTITY" ] || { echo "!! 证书导入失败（密码不对？）"; exit 1; }
echo "    使用身份: $IDENTITY"

echo "==> 签名嵌套代码 + 主程序"
find "$APP/Frameworks" -name "*.dylib" -exec codesign -f -s "$IDENTITY" --keychain "$WORK/sign.keychain" {} \; 2>/dev/null
for FW in "$APP/Frameworks"/*.framework; do
  [ -e "$FW" ] && codesign -f -s "$IDENTITY" --keychain "$WORK/sign.keychain" "$FW"
done
[ -e "$APP/InAppPurchase.dylib" ] && codesign -f -s "$IDENTITY" --keychain "$WORK/sign.keychain" "$APP/InAppPurchase.dylib"
codesign -f -s "$IDENTITY" --keychain "$WORK/sign.keychain" \
  --entitlements "$ENTITLEMENTS" "$APP"

echo "==> 校验签名"
codesign -v --deep "$APP" && echo "签名校验通过"
codesign -d --entitlements :- "$APP" | head -8

echo "==> 打包 IPA"
rm -f "$BASEDIR/APP-signed.ipa"
(cd "$WORK" && zip -qry "$BASEDIR/APP-signed.ipa" Payload)

echo "完成: $BASEDIR/APP-signed.ipa"
