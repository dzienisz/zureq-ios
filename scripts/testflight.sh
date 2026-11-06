#!/bin/bash
# Archive ZureqShopper and upload it to TestFlight using an App Store Connect API key.
# The archive uses automatic (development) signing. The export re-signs with the
# "Apple Distribution" certificate and the "ZUREQ Shopper App Store" profile, both
# created through the App Store Connect API (an App Manager key cannot use Xcode cloud
# signing). The certificate lives in the zureq-build keychain; the profile is installed
# in ~/Library/Developer/Xcode/UserData/Provisioning Profiles.
#
# Required environment:
#   APPLE_TEAM_ID    Apple Developer Team ID
#   ASC_KEY_ID       App Store Connect API key ID
#   ASC_ISSUER_ID    App Store Connect API issuer ID
#   ASC_PRIVATE_KEY  contents of the AuthKey_<KEY_ID>.p8 file
# Optional:
#   BUILD_NUMBER     CURRENT_PROJECT_VERSION (default: UTC timestamp, always increasing)
#   KEYCHAIN / KEYCHAIN_PASSWORD_FILE  keychain holding the distribution certificate
set -euo pipefail
cd "$(dirname "$0")/.."

for v in APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY; do
  [[ -n "${!v:-}" ]] || { echo "missing $v" >&2; exit 1; }
done

BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KEY_DIR="$WORK/keys"; mkdir -p "$KEY_DIR"
KEY_PATH="$KEY_DIR/AuthKey_$ASC_KEY_ID.p8"
# Accept the .p8 either as a full PEM or as the bare base64 body (whitespace is ignored).
ruby -e 'raw = ENV["ASC_PRIVATE_KEY"].gsub(/-----(BEGIN|END) PRIVATE KEY-----/, "").gsub(/\s+/, "")
puts "-----BEGIN PRIVATE KEY-----", raw.scan(/.{1,64}/), "-----END PRIVATE KEY-----"' > "$KEY_PATH"
chmod 600 "$KEY_PATH"

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict>
    <key>com.dzienisz.zureqshopper</key><string>ZUREQ Shopper App Store</string>
  </dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

AUTH=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration
      -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/zureq-build.keychain-db}"
if [[ -f "${KEYCHAIN_PASSWORD_FILE:-$HOME/asc/kc.pass}" ]]; then
  security unlock-keychain -p "$(cat "${KEYCHAIN_PASSWORD_FILE:-$HOME/asc/kc.pass}")" "$KEYCHAIN"
fi

xcodegen generate
xcodebuild archive -project ZureqShopper.xcodeproj -scheme ZureqShopper \
  -destination 'generic/platform=iOS' -archivePath "$WORK/ZureqShopper.xcarchive" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" | tail -5
xcodebuild -exportArchive -archivePath "$WORK/ZureqShopper.xcarchive" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export" "${AUTH[@]}" | tail -5
echo "Uploaded build $BUILD_NUMBER (version $(grep MARKETING_VERSION project.yml | awk '{print $2}' | tr -d '"'))."
