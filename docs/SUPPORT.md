# linkstr support

_Last updated: March 31, 2026_

linkstr is a private link-sharing app built on [Nostr](https://nostr.com). You create or join private sessions, share links inside those sessions, and react with emoji. This page describes the current shipped behavior in plain language.

---

## Quick start

### Create or import an account

1. Open linkstr.
2. Choose **Create account** for a new account, or import an existing secret key (`nsec`).
3. If you create a new account, copy the displayed `nsec` and store it somewhere safe.
4. Optionally set a public profile name.

Your active account is stored in the device keychain. If you use iCloud Keychain, iOS may also sync that keychain item across your devices.

### Add contacts

1. Open the Contacts tab.
2. Tap the add-contact button.
3. Paste an `npub` or scan a QR code.
4. Optionally save a private alias.
5. Tap the top-right add icon.

Adding the same contact again updates the saved alias instead of creating a duplicate. To edit an alias later, tap the contact row.

The bottom footer shows validation and relay status only. The keyboard return key advances from the public key field into alias and submits from alias.

### Create a session

1. Open the Sessions tab.
2. Tap the compose button in the top-right corner.
3. Enter a session name.
4. Optionally add contacts now, or start solo and add them later.
5. Tap the top-right create icon.

After creation, linkstr opens the session immediately.

The bottom footer shows validation and relay status only. The keyboard return key advances from the name field into member search and submits immediately when there are no contacts yet.

### Use the You tab

The You tab shows your current public key (`npub`), QR code, and published profile name. You can copy the public key or update the profile name that other Nostr apps can see.

Profile name changes can be submitted with either the keyboard return key or the save button.

### Send a post

1. Open a session.
2. Tap the compose button in the top-right corner.
3. Paste a link.
4. Optionally add a note.
5. Tap the top-right send icon.

Generic web URLs are valid posts too. In-app playback, local caching, and save/export options depend on the provider and the specific URL. The composer indicates when an in-app view is available.

The bottom footer shows validation and relay status only. The keyboard return key on the link field advances into the note field.

### React, delete, rename, archive, and manage members

| Action                 | How                                                                                                                                                                                     |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| React to a post        | Open a post and tap 👍, 👎, 👀, or **…** for the emoji picker.                                                                                                                          |
| Remove a reaction      | Tap the same emoji again.                                                                                                                                                               |
| Share a deep link      | Open post detail and tap the share button in the top-right corner. The shared link carries only the normalized URL; linkstr fetches preview metadata again when the recipient opens it. |
| Delete your own post   | Long-press the post row in the session view.                                                                                                                                            |
| Archive a session      | Long-press the session row.                                                                                                                                                             |
| View archived sessions | Tap the archive icon in the sessions header.                                                                                                                                            |
| Rename a session       | Open a session, tap the members button, and edit the session name.                                                                                                                      |
| Delete a session       | Open a session, tap the members button, and use **Delete Session** in the manage sheet.                                                                                                 |
| Add or remove members  | Open a session and use the members button.                                                                                                                                              |

Only the session creator can rename sessions, delete them, or change session membership.

### Relay settings

Open Settings to manage relays.

- Default relays are created automatically if you do not have any yet.
- You can add your own relay URLs.
- Enabled relays can be toggled on or off.
- Relay rows can be removed.
- **Reset defaults** restores the shipped relay set.

---

## What works in-app

linkstr accepts normal web URLs, but in-app playback is provider-dependent.

**Extraction-preferred** (local playback attempted first, embed fallback available):

- TikTok videos
- Instagram Reels
- Facebook Reels
- Twitter/X statuses — only when provider metadata confirms video is present

**Embed-only** (web player only, no local extraction):

- YouTube
- Rumble
- Instagram video posts
- Facebook video posts
- Twitter/X non-video statuses — only when the official tweet embed is available

**Browser fallback** covers everything else, plus any provider URL that blocks extraction or embed playback at runtime.

When local extraction succeeds, linkstr can cache the media on-device and offer **Save to Photos** or **Save to Files**. Embed-only playback stays network-backed and does not offer local export controls.

---

## How sessions work

linkstr is session-first. A session is a private shared feed with a name, a creator, a member list, and root link posts. Reactions and deletes belong to those root posts.

**Membership is snapshot-based.** When the creator adds or removes people, linkstr publishes the full member list as it exists at that moment. The latest valid snapshot defines the current member set.

- Adding someone later does not retroactively share older posts with them. It only makes them eligible to receive content sent while they are an active member.
- Removing someone stops future delivery but cannot erase content they already received.

**Validation happens before anything is applied locally.**

- A post must belong to a real session and come from someone who was a valid member when it was sent.
- A reaction must pass the same membership check and point to a real root post.
- A delete must match the original root sender before it becomes authoritative.

**Relay ordering is not guaranteed.** A post may arrive before the session snapshot that makes it valid, and a reaction may arrive before its root post. linkstr handles this by temporarily staging those events in memory and retrying them when the missing dependency arrives. If another relay connects later in the same live session, linkstr widens backfill coverage and retries once the missing history arrives. Recovery still depends on whether your relays can replay that history.

**Deduplication is automatic.** Duplicate relay delivery is normal. linkstr deduplicates by event ID, so reconnects and backfill do not create duplicate posts or reactions.

**No offline outbox exists.** If a send fails, the app shows an error instead of quietly pretending the post or reaction was sent.

---

## FAQ

### What is Nostr?

Nostr is a decentralized protocol. Your encrypted session payloads move through the relays you connect to, and your account key can also work in other Nostr apps.

### Is my data private?

Session content is end-to-end encrypted before it reaches relays. Only session members can decrypt posts, reactions, and membership updates. Your secret key (`nsec`) stays on your device unless you choose to copy or export it.

### What goes through linkstr's push service?

linkstr uses an APNs push service for iOS notifications. That service stores your APNs device token, your Nostr pubkey, archived conversation IDs used to suppress notifications for archived sessions, and lightweight push-dedupe bookkeeping so the same event is not pushed repeatedly.

Push alerts use generic text. Old push notifications are not replayed during historical restore.

### Can I use my account in other Nostr apps?

Yes. Your `nsec` is a Nostr secret key, not a linkstr-only credential.

### What happens if I log out?

- **Log out (keep local data)** removes the active identity from memory and keychain state but keeps the signed-in account's local sessions, posts, contacts, and caches on the device.
- **Log out and clear local data** removes the active identity and deletes all account-scoped local data for that account from the device.

### What happens if I delete my account?

Deleting the account is relay-gated. linkstr only finishes the delete flow when it can reach a writable relay and get relay acceptance for the account-removal events.

When that succeeds, linkstr clears your local data on this device, logs you out, publishes an empty follow list, and sends a Nostr vanish request to your enabled relays.

Deleting the account does not invalidate the `nsec` itself. If you still have that key, you can sign in again later.

### Can I rename a session?

Yes. Open the session and tap the members button. If you are the session creator, you can edit the session name at the top of the manage session sheet. Saving publishes the updated name to all current members.

### What happens when I add or remove a member?

Adding someone publishes a new session snapshot with the full member list. That person can receive content sent after they become an active member. Older posts are not retroactively shared with them.

Removing someone publishes another full snapshot. They stop receiving future posts and reactions, but anything they already received remains theirs.

If you are removed, linkstr keeps the session as local history. The session becomes read-only — you can still view prior posts and reactions but not send new ones.

### Why can't I send a post or reaction?

Most send failures come down to one of these:

- No enabled relays.
- Only read-only relays are connected.
- The app could not get relay acceptance before the send timeout.
- You are no longer an active member of that session.

linkstr does not queue failed sends for later automatic retry. If a send fails, the composer stays open and shows an error.

### Why didn't a post, reaction, or delete show up right away?

The most common reason is relay ordering. linkstr may receive a reaction before the root post it belongs to, or a post before the session snapshot that makes it valid. In that case the app stages the event and retries it once the missing dependency arrives.

Delete notices are even stricter: linkstr waits until it can match the delete to the original root sender before applying it.

### Can I use the same account on multiple devices?

Yes, but linkstr is local-first and relay-backed, so there are a couple of limits:

1. Export the `nsec` from the first device.
2. Import the same `nsec` on the second device.
3. Make sure both devices can connect to relays.

New posts and reactions should sync when both devices reconnect to relays. Historical restore depends on relay retention and what each device can replay from relay history.

If you delete and reinstall the app without restoring its local data, linkstr rebuilds what it can from relay history. Replayed older posts are treated as history, not as fresh unread posts.

### Can I delete a session?

Yes. Open the session, tap the members button, and use **Delete Session** in the manage sheet.

Delete is creator-only and requires confirmation. When it succeeds, linkstr removes the session from active and archived lists on this device, sends an encrypted delete notice to known members, and makes a best-effort relay deletion request for stored root-post wrappers when those relay event IDs are known.

Delete is permanent for linkstr UX. There is no restore flow.

### Can I remove a contact?

Yes. Long-press the contact row and choose **Remove contact**. linkstr publishes an updated follow list to relays and removes the contact locally.

### Can I save videos?

Yes, for content you have the right to save. Save and export are available only when linkstr can extract and cache a local media file. Embed-only playback is provider-dependent and may not offer save or export even if the post plays in-app.

---

## Privacy and storage

### What data is stored locally?

linkstr stores account-scoped sessions, member snapshots and intervals, session deletion tombstones, posts, reactions, read state, archive state, contacts, and media cache references on the device. Sensitive content fields are encrypted at rest with local per-owner keys.

### Where are account keys stored?

In the device keychain, with iOS-controlled protection. Simulator fallback storage is used only when simulator keychain access is unavailable.

### Where are videos and previews stored?

Downloaded media and generated previews are stored in app-owned local storage. Video cache is treated as disposable device cache and auto-trims with least-recently-used eviction at approximately 1 GB. Settings can clear downloaded videos, while saved metadata and thumbnails stay on-device until they are replaced or account data is removed.

### What permissions does linkstr ask for?

| Permission        | Purpose                                        |
| ----------------- | ---------------------------------------------- |
| Camera            | Scanning contact QR codes                      |
| Photos (add-only) | Exporting saved videos to Photos               |
| Notifications     | APNs alerts for new posts and active reactions |
| Network access    | Relay sync and media playback                  |

Archived sessions do not send notifications.

---

## Troubleshooting

### The app won't connect to relays

1. Confirm your internet connection works.
2. Open Settings and check that at least one relay is enabled.
3. If needed, use **Reset defaults** in the relays section.
4. Bring the app back to the foreground and leave it open for a few seconds. linkstr treats this like a light reopen: it stops relay runtime whenever the app leaves the foreground and does one clean rebuild from a disconnected baseline when it becomes active again.
5. If it still does not recover, force-quit and reopen the app.

### My posts are not syncing across devices

1. Confirm both devices are signed in with the same `nsec`.
2. Confirm both devices can connect to relays.
3. Leave the app open long enough for relay sync to complete after reconnect.

Historical replay depends on relay retention. linkstr can retry out-of-order posts, reactions, and deletes locally, but it still needs the missing relay history to arrive.

### Videos won't play

1. Check your network connection.
2. Switch between **Try local playback** and **Try embed playback**.
3. If a downloaded copy was auto-trimmed, try local playback again to re-download it.
4. Try local playback again to clear a stale local failure and force a fresh retry.
5. Use the refresh button in post detail if that post's metadata seems stale or missing.
6. Use **Open in browser** if the provider blocks embedded playback.

### A preview looks stale or wrong

1. Use the refresh button in post detail to re-fetch metadata for that post.
2. Open the session, the post detail, or the shared-link screen and let linkstr rebuild the preview if metadata is still missing.
3. Settings only clears downloaded videos; it does not wipe saved metadata or thumbnails.
4. If the provider itself is serving bad metadata, use **Open in browser**.

### I can't scan a QR code

1. Check camera permission in iOS Settings.
2. Use better lighting and a steady camera.
3. Paste the `npub` manually if needed.

---

## Contact

- GitHub issues: <https://github.com/therealparmesh/linkstr>
- Email: <parmesh@hey.com>

## Legal

By using linkstr, you agree to respect content creators' intellectual property rights and comply with applicable laws and platform terms when downloading or sharing content.

linkstr is provided as-is. The developer is not responsible for user-generated content or misuse of downloading features.

---

linkstr is open-source software built on the Nostr protocol.
