# linkstr support

Last updated: March 15, 2026

linkstr is a private link-sharing app built on nostr. You create or join private sessions, share links inside those sessions, and react with emoji. This page describes the current shipped behavior in plain language.

## Quick start

### Create or import an account

1. Open linkstr.
2. Choose `create account` for a new account, or import an existing secret key (`nsec`).
3. If you create a new account, copy the shown `nsec` and store it somewhere safe.
4. Optionally set a public profile name.

Your active account is stored in the device keychain. If you use iCloud Keychain, iOS may also sync that keychain item across your devices.

### Add contacts

1. Open the Contacts tab.
2. Tap the add contact button.
3. Paste an `npub` or scan a QR code.
4. Optionally save a private alias.
5. Tap `add contact`.

Adding the same contact again updates the saved alias instead of creating a duplicate. To edit an alias later, tap the contact row.
You can also use the top-right `add` action immediately, or dismiss the keyboard and use the footer button. The keyboard `return` key moves from the public key field into alias and submits from alias.

### Create a session

1. Open the Sessions tab.
2. Tap the compose button in the top-right corner.
3. Enter a session name.
4. Optionally add contacts now, or start solo and add them later.
5. Tap `create session`.

After creation, linkstr opens the session for you immediately.
You can also use the top-right `create` action immediately, or dismiss the keyboard and use the footer button. The keyboard `return` key moves from the name field into member search and submits immediately when there are no contacts yet.

### Use the You tab

The You tab shows your current public key (`npub`), QR code, and published profile name. You can copy the public key from there or update the profile name that other nostr apps can see.

Profile name changes can be submitted with either the keyboard return key or the save button.

### Send a post

1. Open a session.
2. Tap the compose button in the top-right corner.
3. Paste a link.
4. Optionally add a note.
5. Tap `send post`.

Generic web URLs are valid posts too. In-app playback, local caching, and save/export options depend on the provider and the specific URL.
You can also use the top-right `send` action immediately, or dismiss the keyboard and use the footer button. The keyboard `return` key on the link field moves into the note field.

### React, delete, archive, and manage members

- Reactions: open a post and tap `👍`, `👎`, `👀`, or `...` for the emoji picker.
- Share a deep link to a post: open post detail and tap the share button in the top-right corner. The shared link carries only the normalized URL, and linkstr fetches preview metadata again when the recipient opens it.
- Remove your reaction: tap the same emoji again.
- Delete your own post: long-press the post row in the session view.
- Archive a session: long-press the session row.
- View archived sessions: tap the archive icon in the sessions header.
- Add or remove members: open a session and use the members button.

Only the session creator can change session membership.

### Relay settings

Open Settings to manage relays.

- Default relays are created automatically if you do not have any yet.
- You can add your own relay URLs.
- Enabled relays can be turned on or off.
- Relay rows can be removed.
- `Reset defaults` restores the shipped relay set.

## What works in-app

linkstr accepts normal web URLs, but in-app playback is provider-dependent.

- Extraction-first playback: TikTok videos, Instagram Reels, Facebook Reels, and Twitter/X statuses when provider metadata confirms a video is present.
- Embed-first playback: YouTube, Rumble, Instagram video posts, Facebook video posts, and Twitter/X non-video statuses when the official tweet embed is available.
- Browser fallback: everything else, plus any provider URL that blocks extraction or embed playback at runtime.

When local extraction succeeds, linkstr can cache the media on-device and offer `save to photos` or `save to files`. Embed-only playback stays network-backed and does not get local export controls.

## How linkstr sessions work

linkstr is session-first. A session is a private shared feed with a name, a creator, a member list, and root link posts. Reactions and deletes belong to those root posts.

Membership changes are snapshot-based. When the creator adds or removes people, linkstr sends the full member list for that point in time. The latest valid snapshot is what defines the current member set.

That means adding someone later does not retroactively share older posts with them. It only makes them eligible to receive content sent while they are an active member. Removing someone stops future delivery, but it cannot erase content they already received earlier.

Posts, reactions, and deletes are validated against session state before they are applied locally.

- A post must belong to a real session and come from someone who was a valid member when it was sent.
- A reaction must pass the same membership check and also point to a real root post.
- A delete must match the original root sender before it becomes authoritative.

Relays can deliver messages out of order. A post may arrive before the session snapshot that makes it valid, and a reaction may arrive before the root it belongs to. linkstr handles that by temporarily staging those events in memory and retrying them when the missing session or root shows up.

If something is still waiting on missing history, linkstr keeps that event staged in memory. When another relay connects later in the same live session, linkstr widens backfill coverage and retries once the missing history arrives. Recovery still depends on whether your relays can replay that history.

Duplicate relay delivery is normal. linkstr deduplicates by event ID, so reconnects and backfill should not create duplicate posts or reactions in the app.

linkstr does not have a durable offline outbox. If a send fails, the app shows an error instead of quietly pretending the post or reaction was sent.

## FAQ

**What is nostr?**

Nostr is a decentralized protocol. Your encrypted session payloads move through the relays you connect to, and your account key can also work in other nostr apps.

**Is my data private?**

Session content is end-to-end encrypted before it goes to relays. Only session members can decrypt posts, reactions, and membership updates. Your secret key (`nsec`) stays on your device unless you choose to copy or export it.

**What goes through linkstr's push service?**

linkstr uses an APNs push service for iOS notifications. That service stores your APNs device token, your nostr pubkey, archived conversation IDs used to suppress notifications for archived sessions, and lightweight push-dedupe bookkeeping so the same event is not pushed repeatedly.

Push alerts use generic text. Old push notifications are not replayed during historical restore.

**Can I use my account in other nostr apps?**

Yes. Your `nsec` is a nostr secret key, not a linkstr-only credential.

**What happens if I log out?**

- `log out (keep local data)` removes the active identity from memory and keychain state, but keeps the signed-in account's local sessions, posts, contacts, and caches on the device
- `log out and clear local data` removes the active identity and deletes account-scoped local data for that account from the device

**What happens if I delete my account?**

Deleting the account is relay-gated. linkstr only finishes the delete flow when it can reach a writable relay and get relay acceptance for the account-removal events.

When that succeeds, linkstr clears your local data on this device, logs you out, publishes an empty follow list, and sends a nostr vanish request to your enabled relays.

Deleting the account in linkstr does not invalidate the `nsec` itself. If you still have that key, you can sign in again later.

**What happens when I add or remove a member?**

Adding someone sends a new session snapshot with the full member list. That person can receive content sent after they become an active member. Older posts are not retroactively shared with them.

Removing someone sends another full snapshot. They stop receiving future posts and reactions, but anything they already received remains theirs.

If you are removed on this device, linkstr keeps the session as local history. The session becomes read-only, so you can still view prior posts and reactions but not send new ones.

**Why can't I send a post or reaction?**

Most send failures come down to one of these:

- No enabled relays.
- Only read-only relays are connected.
- The app could not get relay acceptance before the send timeout.
- You are no longer an active member of that session.

linkstr does not queue failed sends for later automatic retry. If a send fails, the composer stays open and shows an error.

**Why didn't a post, reaction, or delete show up right away?**

The most common reason is relay ordering. linkstr may receive a reaction before the root post it belongs to, or a post before the session snapshot that makes it valid. In that case the app stages the event and retries it once the missing dependency arrives.

Delete notices are even stricter: linkstr waits until it can match the delete to the original root sender before applying it.

**Can I use the same account on multiple devices?**

Yes, but linkstr is local-first and relay-backed, so there are a couple of limits:

1. Export the `nsec` from the first device.
2. Import the same `nsec` on the second device.
3. Make sure both devices can connect to relays.

New posts and reactions should sync when both devices reconnect to relays. Historical restore depends on relay retention and what each device can replay from relay history.

If you delete and reinstall the app without restoring its local app data, linkstr rebuilds what it can from relay history. Replayed older posts are treated as history, not as fresh unread posts.

**Can I delete a session?**

Not yet. Sessions can be archived and unarchived, but there is no shipped session-delete feature.

**Can I remove a contact?**

Yes. Long-press the contact row and choose `remove contact`. linkstr publishes an updated follow list to relays and removes the contact locally.

**Can I save videos?**

Yes, for content you have the right to save. Save/export is available only when linkstr can extract and cache a local media file. Embed-only playback is provider-dependent and may not offer save/export even if the post plays in-app.

## Privacy and storage

**What data is stored locally?**

linkstr stores account-scoped sessions, member snapshots and intervals, posts, reactions, read state, archive state, contacts, and media cache references on the device. Sensitive content fields are encrypted at rest with local per-owner keys.

**Where are account keys stored?**

In the device keychain, with iOS-controlled protection. Simulator fallback storage is used only when simulator keychain access is unavailable.

**Where are videos and previews stored?**

Downloaded media and generated previews are stored in app-owned local storage. Video cache is treated as disposable device cache and auto-trims with least-recently-used eviction at about 1 GB. You can also clear cached media and previews from Settings.

**What permissions does linkstr ask for?**

- Camera: scanning contact QR codes.
- Photos add-only: exporting saved videos to Photos.
- Notifications: APNs alerts for new posts and active reactions.
- Network access: relay sync and media playback.

Archived sessions do not send notifications.

## Troubleshooting

**The app won't connect to relays**

1. Confirm your internet connection works.
2. Open Settings and check that at least one relay is enabled.
3. If needed, use `Reset defaults` in the relays section.
4. Bring the app back to the foreground and leave it open for a few seconds. linkstr treats that like a light reopen: it stops relay runtime whenever the app leaves foreground and does one clean rebuild from a disconnected baseline when it becomes active again.
5. If it still does not recover, force-quit and reopen the app.

**My posts are not syncing across devices**

1. Confirm both devices are signed in with the same `nsec`.
2. Confirm both devices can connect to relays.
3. Leave the app open long enough for relay sync to complete after reconnect.

Remember that historical replay depends on relay retention. linkstr can retry out-of-order posts, reactions, and deletes locally, but it still needs the missing relay history to arrive.

**Videos won't play**

1. Check your network connection.
2. Switch between `try local playback` and `try embed playback`.
3. If a downloaded copy was auto-trimmed, try local playback again to re-download it.
4. Clear cached media and previews from Settings if playback metadata looks stale.
5. Use `open in browser` if the provider blocks embedded playback.

**A preview looks stale or wrong**

1. Clear cached media and previews from Settings.
2. Open the session, the post detail, or the shared-link screen and let linkstr rebuild the preview.
3. If the provider itself is serving bad metadata, use `open in browser`.

**I can't scan a QR code**

1. Check camera permission in iOS Settings.
2. Use better lighting and a steady camera.
3. Paste the `npub` manually if needed.

## Contact

- GitHub issues: https://github.com/therealparmesh/linkstr
- Email: parmesh@hey.com

## Legal

By using linkstr, you agree to respect content creators' intellectual property rights and comply with applicable laws and platform terms when downloading or sharing content.

linkstr is provided as-is. The developer is not responsible for user-generated content or misuse of downloading features.

---

linkstr is open source software built on the nostr protocol.
