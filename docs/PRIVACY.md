# privacy policy

## overview

linkstr does not collect or retain personal data on developer-controlled servers.

## data collection

**none.**

- no analytics or tracking by the developer
- no advertising
- no data sent to external servers controlled by the developer
- encrypted nostr payloads are transmitted only to relays you choose

## data you control

### local device storage

stored only on your device:

- **account keys**: nostr cryptographic keys stored in device keychain
- **contacts**: contact aliases and public keys you add
- **sessions**: session names and member lists you create
- **messages**: links, notes, and reactions you send and receive
- **media cache**: videos and thumbnails downloaded for offline viewing

this data is encrypted at rest using device-local encryption keys and never leaves your device except as described below.

### nostr network

when you use linkstr, you communicate through the decentralized nostr protocol:

- **encrypted messages**: session messages are end-to-end encrypted and transmitted through nostr relays you connect to
- **contact list**: your nostr follow list is published to relays as part of the nostr protocol (nip-02)
- **relay connections**: you choose which nostr relays to connect to; messages are transmitted through these relays

nostr relays are third-party servers not controlled by linkstr. each relay operator has their own privacy policy and data retention practices.

### optional icloud sync

if you enable iCloud keychain on your device:

- your account keys may sync across your apple devices via iCloud
- this is controlled by your ios settings, not by linkstr
- refer to apple's privacy policy for iCloud data handling

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

- **purpose**: connect to nostr relays and download media
- **usage**: required for app functionality
- **data**: encrypted messages sent to relays you configure; media downloaded from urls you share

## third-party content

when you share links to third-party platforms (tiktok, instagram, facebook, youtube, twitter, rumble):

- the app may download publicly accessible media from these platforms
- you are subject to those platforms' terms of service and privacy policies
- the app does not share your identity or personal information with these platforms
- downloaded media is stored locally on your device only

## user responsibility

you are responsible for:

- respecting intellectual property rights when downloading and sharing content
- complying with applicable laws and third-party platform terms of service
- managing your nostr private key (nsec) securely
- understanding that deleted sessions remain on local device unless explicitly cleared

## children's privacy

linkstr does not knowingly collect information from children under 13. the app does not collect any personal information from any users.

## data retention

- **local data**: remains on device until you delete app or use "log out and clear local data"
- **relay data**: controlled by individual nostr relay operators; linkstr has no control over relay data retention
- **icloud sync**: controlled by icloud settings and apple's retention policies

## data security

- end-to-end encryption for all session messages
- private keys stored in ios keychain with whenunlocked accessibility
- local data encrypted at rest using per-account encryption keys
- no external servers controlled by linkstr developer

## your rights

you have the right to:

- delete all local data using "log out and clear local data"
- export your account key (nsec) and use it in other nostr-compatible apps
- control which relays you connect to
- disable icloud sync in ios settings

## changes to privacy policy

updates will be posted at the same location with a new "last updated" date.

## international users

linkstr is designed to work globally. no data is transmitted to servers controlled by the developer, regardless of your location.

## third-party services

the app uses:

- **nostr protocol**: decentralized network; refer to individual relay privacy policies
- **apple icloud** (optional): subject to apple's privacy policy
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
