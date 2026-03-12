# privacy policy

last updated: march 12, 2026

## overview

linkstr runs a small developer-controlled push notification service for ios delivery. your account keys and encrypted session content still stay on your device and on the nostr relays you use, but APNs device tokens and a small amount of routing state are stored by that push service.

## data collection

linkstr does not run analytics, ads, or tracking. it does operate a push notification service that stores:

- APNs device tokens
- nostr pubkey to device-token associations
- archived conversation ids used to suppress push notifications

encrypted nostr payloads are still transmitted only to the relays you choose.

## data you control

### local device storage

stored only on your device:

- **account keys**: your secret key (nsec) plus device-local encryption keys stored in keychain
- **contacts**: contact aliases and public keys you add
- **sessions**: session names and member lists you create
- **posts and reactions**: links, notes, and reactions you send and receive
- **media cache**: videos and thumbnails downloaded for offline viewing

downloaded videos are stored as device-local cache. linkstr automatically trims older cached video files with least-recently-used eviction once local video cache reaches about 1 gb.

this data is encrypted at rest using device-local encryption keys and never leaves your device except as described below.

during relay sync, linkstr may also hold out-of-order session, post, delete, or reaction events in temporary in-memory buffers until the missing session snapshot or root post arrives. if those dependencies are still missing after a relay reconnect, linkstr may request relay history again from the same relays. those transient buffers are not sent to the push service and are cleared when app runtime state resets.

### nostr network

when you use linkstr, you communicate through the decentralized nostr protocol:

- **encrypted session payloads**: posts, reactions, and membership updates are end-to-end encrypted and transmitted through nostr relays you connect to
- **contact list**: your nostr follow list is published to relays as part of the nostr protocol (nip-02)
- **relay connections**: you choose which nostr relays to connect to; encrypted session payloads are transmitted through these relays

nostr relays are third-party servers not controlled by linkstr. each relay operator has their own privacy policy and data retention practices.

### push notification service

when you allow notifications, linkstr sends limited routing data to a developer-operated push service:

- **APNs device token**: required so Apple can deliver notifications to your device
- **nostr pubkey association**: used to know which device tokens belong to which account
- **archived conversation ids**: used to suppress notifications for archived sessions

the push service does not store decrypted post text, reaction text, or session payload plaintext. notification banners use generic text such as new post or new reaction.

### optional icloud sync

if you enable iCloud keychain on your device:

- your account keys may sync across your Apple devices via iCloud
- this is controlled by your iOS settings, not by linkstr
- refer to Apple's privacy policy for iCloud data handling

## permissions

### camera

- **purpose**: scan qr codes when adding contacts
- **usage**: only when you tap scan button
- **data**: no photos or camera data stored or transmitted

### photos library (add only)

- **purpose**: save videos to photos library
- **usage**: only when you tap "save to photos"
- **data**: videos saved locally; no data uploaded

### network access

- **purpose**: connect to nostr relays, talk to the linkstr push service, and download media
- **usage**: required for app functionality
- **data**: encrypted session payloads sent to relays you configure; APNs device token and archive state sent to the linkstr push service; media downloaded from urls you share

### notifications

- **purpose**: deliver ios alerts for new posts and reactions
- **usage**: only after you grant notification permission
- **data**: APNs device token is registered with the linkstr push service and with Apple Push Notification service

## third-party content

when you share links to third-party platforms (tiktok, instagram, facebook, youtube, twitter, rumble):

- the app may download publicly accessible media from these platforms
- those platforms may still receive standard network metadata such as your ip address and user agent when content is requested
- you are subject to those platforms' terms of service and privacy policies
- downloaded media is stored locally on your device only

## user responsibility

you are responsible for:

- respecting intellectual property rights when downloading and sharing content
- complying with applicable laws and third-party platform terms of service
- managing your secret key (nsec) securely
- understanding that archived sessions remain on local device unless explicitly cleared through account cleanup

## children's privacy

linkstr does not knowingly collect information from children under 13. the app does not collect any personal information from any users.

## data retention

- **local data**: remains on device until you delete app or use "log out and clear local data"
- **media cache**: downloaded video cache may be evicted automatically by linkstr's cache cap or by ios storage pressure
- **relay data**: controlled by individual nostr relay operators; linkstr has no control over relay data retention
- **push service data**: APNs device tokens and archive-state mappings remain until you unregister, log out, the token is invalidated by APNs, or operational cleanup removes stale records
- **icloud sync**: controlled by icloud settings and apple's retention policies
- **account deletion**: linkstr can ask enabled relays to delete account data, but your nsec remains valid unless you discard it yourself

## data security

- end-to-end encryption for session payloads
- account keys stored in iOS keychain with whenunlocked accessibility
- local data encrypted at rest using per-account encryption keys
- limited developer-operated push infrastructure for notification routing

## your rights

you have the right to:

- delete all local data using "log out and clear local data"
- delete your account using the in-app delete-account flow
- export your secret key (nsec) and use it in other nostr-compatible apps
- control which relays you connect to
- disable iCloud sync in iOS settings

## changes to privacy policy

updates will be posted at the same location with a new "last updated" date.

## international users

linkstr is designed to work globally. APNs routing data may be transmitted to servers controlled by the developer so ios notifications can function.

## third-party services

the app uses:

- **nostr protocol**: decentralized network; refer to individual relay privacy policies
- **linkstr push service**: stores APNs device tokens, pubkey associations, and archived conversation ids for ios push delivery
- **apple icloud** (optional): subject to apple's privacy policy
- **apple push notification service (APNs)**: subject to apple's privacy policy
- **web content providers**: when you share links, you interact with third-party websites subject to their policies

## contact

- github: https://github.com/therealparmesh/linkstr
- email: parmesh@hey.com

## legal basis

linkstr processes data based on:

- your explicit consent (when granting permissions)
- necessity for app functionality (local storage, relay communication)
- your voluntary use of the app

## disclaimer

linkstr is provided as-is. the developer is not responsible for:

- data retention policies of third-party nostr relays
- content you choose to download or share
- compliance with third-party platform terms of service

---

by using linkstr, you acknowledge that you have read and understood this privacy policy.
