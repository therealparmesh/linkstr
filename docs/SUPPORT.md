# linkstr support

last updated: march 11, 2026

## getting started

### create account

- tap "create account" for a new account
- copy and store the shown secret key (nsec). it works like your account password
- optionally add a profile name others can see
- or sign in with an existing secret key (nsec) if you already have one

your account stays in the device keychain and can sync through iCloud keychain if you enable it.

### create session

1. sessions tab → top-right compose button
2. enter session name
3. add contacts (optional)
4. tap the bottom "create session" button

### add contacts

1. contacts tab → top-right add-contact button
2. enter public key (npub) or scan qr code
3. optionally add alias
4. tap the bottom "add contact" button once the key is valid

tap a contact row to edit its alias. long-press a contact row to remove it.

### use the you tab

1. you tab
2. use the profile card, qr code, or "copy public key"
3. share it over messages, email, or any other app.

profile name changes apply from the keyboard return key or the save button, and both dismiss the keyboard.

### post links

1. open session → top-right compose button
2. paste link
3. add optional note
4. tap the bottom "send post" button

supported platforms: tiktok, instagram, facebook, youtube, twitter/x, rumble, any web link.

### view and save content

- tap post to view detail
- videos play in embedded web players or can be downloaded for offline viewing
- tap "save to photos" to save videos you have rights to save
- tap "save to files" to export to files app
- long-press/select the raw link text to copy it
- open in browser with browser button
- delete your own post by long-pressing its row in the session post list

### react to posts

- open post
- tap quick reaction (👍 👎 👀) or `...` for emoji picker
- tap again to remove reaction

### manage sessions

- archive: long-press session → "archive"
- delete your post: long-press your post row → "delete post"
- view archived: tap archive icon on the left side of the sessions header
- add/remove members: open session → tap the members button in the top-right corner
- only session creators can modify members

### relay settings

settings tab → relays section

- default relays provided automatically
- add custom relays with the relay URL field and "add relay"
- toggle relays on/off
- use the "remove" button to delete a relay
- reset to defaults if needed

## faq

**what is nostr?**
decentralized protocol for social communication. encrypted session payloads move across relays, and your nostr identity works across any nostr-compatible app. linkstr also runs a small push service for ios notifications.

**is my data private?**
yes. all session content is end-to-end encrypted. only session members can read posts and reactions. your secret key (nsec) never leaves your device.

**can i use my nostr account in other apps?**
yes. your secret key (nsec) works with any nostr app. find it in settings → identity.

**what happens if i log out?**

- "log out (keep local data)": local sessions, posts, and contacts stay on device and reappear when you sign in again with the same account
- "log out and clear local data": permanently deletes all local data for this account

**what happens if i delete my account?**

- linkstr sends a nostr vanish request to your enabled relays, clears local data on this device, and logs you out
- if you keep the secret key (nsec), it still works and can sign in again later

**what if i add the same contact again?**

- linkstr keeps one contact per key
- adding the same contact again updates the saved alias for that contact
- this does not publish a new follow-list event because the followed account did not change

**why can't i send posts?**
check: internet connection, at least one relay connected (settings tab → relays section), you are a member of the session.

**can i delete a session?**
sessions can be archived but not deleted. archived sessions don't appear in main list but data remains on device.

**can i remove a contact?**
yes. long-press the contact row and choose "remove contact." this publishes your updated follow list to relays, removes that person from your contact list, and removes the contact locally.

**can i save videos?**
yes, for content you have rights to save:

1. tap video post
2. tap "try local playback" to download
3. use "save to photos" or "save to files"

you are responsible for respecting content creators' rights and platform terms when downloading media.

## privacy & data

**what data does linkstr collect?**
linkstr does not run analytics or ads, but it does operate a push notification service. that service stores your APNs device token, your nostr pubkey, and archived conversation ids so ios push can work. encrypted post and reaction content still travels through nostr relays, not through the push service.

**what permissions does linkstr need?**

- camera: scan contact qr codes
- photos (add only): save videos to photos library
- notifications: deliver ios alerts for new posts and reactions
- network: connect to nostr relays and download media

**where is my data stored?**

- account keys: device keychain (optionally iCloud synced)
- sessions, posts, and reactions: local device storage only
- media cache: local device storage only
- push routing data: linkstr push service stores APNs device tokens, pubkey associations, and archived conversation ids

downloaded video cache is device-local, auto-trims with least-recently-used eviction at about 1 gb, and can also be cleared from settings tab → storage section. that screen shows an estimate of how much local storage the signed-in account can clear.

## troubleshooting

**app won't connect to relays**

1. check internet connection
2. settings tab → relays section → "reset defaults"
3. force-quit and reopen app

**videos won't play**

1. check internet connection
2. try switching "try local playback" ↔ "try embed playback"
3. if a previously downloaded local copy was auto-trimmed, try "try local playback" again to re-download it
4. settings tab → storage section → "clear cached media and previews"
5. use "open in browser"

**link preview looks stale or wrong**

1. settings tab → storage section → "clear cached media and previews"
2. return to sessions/posts and let the app rebuild previews
3. if the provider still serves bad metadata, use "open in browser"

**can't scan qr codes**

1. check camera permission in settings → privacy & security → camera
2. ensure good lighting
3. alternatively paste public key (npub) manually

**posts not syncing across devices**
linkstr stores posts, reactions, contacts, and caches locally on each device. to use the same account on multiple devices:

1. export secret key (nsec) from settings on first device
2. import the same secret key (nsec) on second device
3. both devices must connect to relays to sync new posts and reactions

note: historical posts depend on relay retention and what each device has already received locally. new posts sync when both devices reconnect to relays.
historical restore after a fresh sign-in does not replay old push notifications.

## contact

- github issues: https://github.com/therealparmesh/linkstr
- email: parmesh@hey.com

## legal

by using linkstr, you agree to respect content creators' intellectual property rights and comply with applicable laws and platform terms when downloading or sharing content.

linkstr is provided as-is. the developer is not responsible for user-generated content or misuse of downloading features.

---

linkstr is open source software built on the nostr protocol.
