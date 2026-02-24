# linkstr support

## getting started

### create account

- tap "create new account" for a new nostr identity
- or "import existing account" if you have an nsec

your account is stored in device keychain and optionally syncs via iCloud.

### create session

1. sessions tab → `+`
2. enter session name
3. add contacts (optional)
4. tap "create session"

### add contacts

1. settings → contacts → `+`
2. enter nostr public key (npub) or scan QR code
3. optionally add alias

### share your account

1. share tab
2. show QR code or tap "copy" for npub
3. share via messages, email, etc.

### post links

1. open session → `+`
2. paste link
3. add optional note
4. tap "send"

supported platforms: tiktok, instagram, facebook, youtube, twitter/x, rumble, any web link.

### view and save content

- tap post to view detail
- videos play in embedded web players or can be downloaded for offline viewing
- tap "save to photos" to save videos you have rights to save
- tap "save to files" to export to files app
- open in safari with browser button

### react to posts

- open post
- tap quick reaction (👍 👎 👀) or `...` for emoji picker
- tap again to remove reaction

### manage sessions

- archive: long-press session → "archive"
- view archived: tap archive icon (top right)
- add/remove members: open session → tap member count → manage
- only session creators can modify members

### relay settings

settings → relays

- default relays provided automatically
- add custom relays with `+` (wss:// urls)
- toggle relays on/off
- swipe left to remove
- reset to defaults if needed

## faq

**what is nostr?**
decentralized protocol for social communication. no central server—messages distributed across relays. your nostr identity works across any nostr-compatible app.

**is my data private?**
yes. all session content is end-to-end encrypted. only session members can read messages. your private key never leaves your device.

**can i use my nostr account in other apps?**
yes. your nsec works with any nostr app. find it in settings → account.

**what happens if i log out?**
"log out (keep local data)": messages remain on device, reappear when you log back in with same account.
"log out and clear local data": permanently deletes all local data for this account.

**why can't i send messages?**
check: internet connection, at least one relay connected (settings → relays), you are a member of the session.

**can i delete a session?**
sessions can be archived but not deleted. archived sessions don't appear in main list but data remains on device.

**can i save videos?**
yes, for content you have rights to save:

1. tap video post
2. tap "try local playback" to download
3. use "save to photos" or "save to files"

you are responsible for respecting content creators' rights and platform terms when downloading media.

## privacy & data

**what data does linkstr collect?**
none. linkstr does not collect, store, or transmit any personal data. all data remains on your device and syncs only through device iCloud keychain (optional) and nostr relays you connect to (encrypted messages only).

**what permissions does linkstr need?**

- camera: scan contact QR codes
- photos (add only): save videos to photos library
- network: connect to nostr relays and download media

**where is my data stored?**

- account keys: device keychain (optionally iCloud synced)
- messages & sessions: local device storage only
- media cache: local device storage only

## troubleshooting

**app won't connect to relays**

1. check internet connection
2. settings → relays → "reset default relays"
3. force-quit and reopen app

**videos won't play**

1. check internet connection
2. try switching "try local playback" ↔ "try embed playback"
3. use "open in safari"

**can't scan qr codes**

1. check camera permission in settings → privacy & security → camera
2. ensure good lighting
3. alternatively paste npub manually

**messages not syncing across devices**
linkstr stores data locally on each device. to use same account on multiple devices:

1. export nsec from settings on first device
2. import same nsec on second device
3. both devices must connect to relays to sync new messages

note: historical messages may not sync automatically—only new messages distribute via relays.

## contact

- github issues: https://github.com/therealparmesh/linkstr
- email: parmesh@hey.com

## legal

by using linkstr, you agree to respect content creators' intellectual property rights and comply with applicable laws and platform terms when downloading or sharing content.

linkstr is provided as-is. the developer is not responsible for user-generated content or misuse of downloading features.

---

linkstr is open source software built on the nostr protocol.
