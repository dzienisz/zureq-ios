# ZUREQ Shopper for iOS

Native SwiftUI app that searches products across independent shops through the [ZUREQ API](https://docs.zureq.io), shows live price and stock, and opens the shop's own checkout in Safari.

## Requirements

- Xcode 26+, iOS 17+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A ZUREQ API key (`zmcp_…`) from https://chat.zureq.io/developers

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

## Credits

Search costs 3 credits (1 when nothing is found), live price and checkout links cost 1, usage and markets are free.
