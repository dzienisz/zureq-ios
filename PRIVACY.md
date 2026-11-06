# ZUREQ Shopper – Privacy Policy

_Last updated: 6 November 2026_

ZUREQ Shopper is an independent iOS app by Kamil Dzieniszewski that searches products in independent online shops through the ZUREQ API. This policy describes what the app does with your data.

## What the app stores on your device

- **Your ZUREQ sign-in.** When you sign in with ZUREQ, the app keeps the access and refresh tokens in the iOS Keychain. If you use an API key instead, the key is stored in the Keychain too. Nothing is sent anywhere except to ZUREQ.
- **Your lists.** The watchlist, shopping list, recent searches and the selected market are stored only on your device (UserDefaults). They are removed when you delete the app.

The app has no account system of its own, no analytics, no advertising and no third-party SDKs.

## What is sent to ZUREQ

Searches, product lookups, checkout-link requests and usage checks are sent to `api.zureq.io` together with your ZUREQ credential, so ZUREQ can answer them and count credits. ZUREQ's handling of that data is described in ZUREQ's own privacy policy at https://zureq.io.

## What is sent to shops

When you open a checkout link, Safari opens the shop's own website. From that point the shop's privacy policy applies. The app does not place orders or handle payments.

## Your choices

- **Sign out** (Settings → Sign out) revokes the ZUREQ token and removes it from the device.
- **Disconnect API key** removes the key from the Keychain.
- Deleting the app removes everything it stored.

## Contact

Questions about this policy: kamil.dzieniszewski@gmail.com. Source code: https://github.com/dzienisz/zureq-ios.
