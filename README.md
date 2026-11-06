# ZUREQ Shopper for iOS

Native SwiftUI app that searches products across independent shops through the [ZUREQ API](https://docs.zureq.io), shows live price and stock, and opens the shop's own checkout in Safari.

## Requirements

- Xcode 26+, iOS 17+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A ZUREQ account. Users sign in with ZUREQ (OAuth) or paste an API key (`zmcp_…`) from https://chat.zureq.io/developers

## Build

```sh
xcodegen generate
xcodebuild test -project ZureqShopper.xcodeproj -scheme ZureqShopper \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`ZureqShopper.xcodeproj` is generated from `project.yml`; edit `project.yml`, not the project.

## Simulator testing

Debug builds seed the Keychain from the `ZUREQ_API_KEY` environment variable:

```sh
SIMCTL_CHILD_ZUREQ_API_KEY=zmcp_… xcrun simctl launch booted com.dzienisz.zureqshopper
```

## TestFlight

`scripts/testflight.sh` archives the app, signs it with Xcode cloud signing and uploads it to TestFlight. It needs an App Store Connect API key (role App Manager) in the environment: `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_PRIVATE_KEY` (the `.p8` contents). The build number defaults to a UTC timestamp; override it with `BUILD_NUMBER`. Bump `MARKETING_VERSION` in `project.yml` for a new version.

## Sign in with ZUREQ

OAuth authorization code + PKCE S256 against `chat.zureq.io`, for resource `https://api.zureq.io/mcp`. The app registers itself dynamically (`ZureqAuth.fixedClientId` is `nil` until ZUREQ issues a pre-registered client) and catches the redirect on `http://localhost:47823/callback` with a loopback listener. Use `localhost`, not `127.0.0.1`: the login page rewrites `127.0.0.1` to `localhost`, which then no longer matches the registration. Tokens live in the Keychain; refresh tokens are single-use, so concurrent refreshes share one request.

## Credits

Search costs 3 credits (1 when nothing is found), live price and checkout links cost 1, usage and markets are free.
