# privacy policy

Last updated: March 12, 2026

## Overview

linkstr is a private link-sharing app built on nostr. Your account keys stay on your device. Encrypted session content moves through the nostr relays you choose. If you enable notifications, a small amount of routing data is also stored by the developer-operated push service so Apple Push Notification service can reach your device.

linkstr does not run ads, analytics, or behavioral tracking.

## What linkstr stores

### On your device

linkstr stores app data locally for the signed-in account, including:

- Account keys in the device keychain.
- Contacts, including private aliases you save locally.
- Sessions, member snapshots, and membership intervals.
- Posts, reactions, delete watermarks, read state, and archive state.
- Media cache references, downloaded videos, and generated previews.
- Local per-account encryption keys used to protect sensitive stored fields at rest.

Sensitive local fields are encrypted at rest with per-account local keys. Operational identifiers and timestamps may remain plaintext locally for indexing and query purposes.

Downloaded videos and generated previews are device-local. Video cache is treated as disposable cache and may be trimmed automatically with least-recently-used eviction once local video cache reaches about 1 GB.

### In temporary runtime memory

During relay sync, linkstr may temporarily stage out-of-order session, post, delete, or reaction events in memory until the missing session snapshot or root post arrives. If reconnect happens while required history is still missing, linkstr may ask the same relays for history again so those staged events can be retried.

Those in-memory buffers are not sent to the push service. They are cleared when app runtime state resets.

### On nostr relays

When you use linkstr, encrypted session payloads are transmitted through the nostr relays you configure. Depending on what you do in the app, relays may receive:

- Encrypted session payloads for session creation, membership updates, posts, reactions, and delete notices.
- Your nostr follow list when you add or remove contacts.
- Standard relay connection metadata that any relay operator can observe, such as connection timing and network-level information.

nostr relays are third-party services. linkstr does not control their retention policies, logs, or privacy practices.

### In the push service

If you allow notifications, linkstr sends limited routing data to a developer-operated push service:

- APNs device tokens.
- Associations between your nostr pubkey and those device tokens.
- Archived conversation IDs used to suppress notifications for archived sessions.

The push service is used for notification routing, not message transport. Encrypted session content still travels through nostr relays, not through the push service.

The push service does not store decrypted post text, reaction text, or session payload plaintext. Push banners use generic notification text. Historical relay restore does not replay old push notifications.

## What linkstr does not do

linkstr does not:

- Run ads or third-party analytics.
- Sell your data.
- Store your decrypted session payloads in the push service.
- Queue failed outbound posts or reactions in a durable offline outbox.

## Permissions

### Camera

- Purpose: scan QR codes when adding contacts.
- Used only when you explicitly choose to scan.
- Camera images are not uploaded by linkstr as part of QR scanning.

### Photos library (add only)

- Purpose: export videos to Photos.
- Used only when you choose `save to photos`.
- Content is saved locally to your library; linkstr does not upload it as part of that action.

### Notifications

- Purpose: deliver iOS alerts for new posts and active reactions.
- Used only after you grant notification permission.
- Requires APNs device token registration with Apple and the linkstr push service.

Archived sessions do not notify.

### Network access

- Purpose: connect to relays, talk to the push service, and download shared media.
- Required for relay-backed syncing and remote media playback.
- Network requests may reach relays you configure, the linkstr push service, Apple Push Notification service, and third-party content providers whose links you open or preview.

## Account keys and iCloud

Your active account keys are stored in the device keychain with iOS-managed protection. If you enable iCloud Keychain, Apple may sync that keychain data across your devices according to your iCloud settings and Apple's policies.

If encrypted local app data is restored without the matching local key material, some encrypted fields may be unreadable until the correct keys are available again.

## Third-party content and providers

When you share or open links from third-party platforms such as TikTok, Instagram, Facebook, YouTube, X, or Rumble, those providers may receive standard network metadata such as your IP address, user agent, and request timing. Their own terms and privacy policies apply.

Downloaded media from those providers is stored locally on your device only, unless you separately export or share it.

## Data retention

- Local app data remains on your device until you delete it, log out and clear local data, or remove the app.
- Media cache may also be removed automatically by cache eviction or iOS storage pressure.
- Relay-side data retention depends on each relay operator.
- Push-service routing data remains until you unregister, log out, APNs invalidates the token, or operational cleanup removes stale records.
- If you delete your account in linkstr and relays are available, the app can publish an empty follow list and a nostr vanish request to enabled relays, but your `nsec` remains valid unless you discard it yourself.

## Your choices

You can:

- Control which relays you use.
- Disable notifications in iOS settings.
- Disable iCloud Keychain in Apple settings.
- Log out while keeping local data.
- Log out and clear local data for the signed-in account.
- Delete your account in-app.
- Export your `nsec` and use it in other nostr apps.

## Children's privacy

linkstr is not directed to children under 13, and the app is not intended to knowingly collect personal information from children.

## International use

linkstr is designed to work globally. If notifications are enabled, APNs routing data may be transmitted to infrastructure controlled by the developer and to Apple services as part of notification delivery.

## Contact

- GitHub: https://github.com/therealparmesh/linkstr
- Email: parmesh@hey.com

## Changes

This policy may be updated as the app changes. The `Last updated` date above will change when the policy is revised.

---

By using linkstr, you acknowledge that you have read and understood this privacy policy.
