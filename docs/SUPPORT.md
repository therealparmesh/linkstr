# linkstr support

_Last updated: September 19, 2026_

linkstr is a private link-sharing app built on [Nostr](https://nostr.com). You create or join private sessions, share links inside those sessions, and react with emoji. This page explains how to use the app.

---

## Quick start

### Create or import an account

1. Open linkstr.
2. Choose **create account** for a new account, or import an existing secret key (`nsec`).
3. If you create a new account, copy the displayed `nsec` and store it somewhere safe.
4. Optionally set a public profile name.

Your active account is stored in the device keychain. If you use iCloud Keychain, iOS may also sync that keychain item across your devices.

### Add contacts

1. Open the Contacts tab.
2. Tap the add-contact button.
3. Paste an `npub` or scan a QR code.
4. Optionally save a private alias.
5. Tap the top-right add icon, then confirm **add contact**.

Adding the same contact through this form updates the saved alias instead of creating a duplicate. The top-right button changes to **save contact**, and confirmation says whether the alias will be saved or cleared. To edit an alias later, tap the contact row. Public keys wrap in full in contact and member lists, the preview, and contact detail. Long-press a contact or session-member row to copy its public key. In the preview and contact detail, you can also long-press the key text to select and copy it.

Contacts keep their last fetched public Nostr name on this device, so names remain available after reopening or offline. Names refresh from relays when available; your private alias always takes priority.

The bottom footer shows validation and relay status only. The keyboard return key advances from the public key field into alias and asks for confirmation from alias.

### See who added you

1. Open the Contacts tab.
2. Tap the person with a checkmark in the top-left toolbar to open **added you**.
3. Tap the add-contact button beside someone, then confirm. People already in your contacts show a checkmark.

Long-press a row to **copy public key**. Tap the toolbar button again to return to contacts. The top-right add-contact button is available in both lists.

The list shows public Nostr follows found on your configured relays, including follows made in other Nostr apps. Pull to refresh or use **load more** when available. Saved results remain visible offline. The status tells you when some results could not be checked, and people may be missing if their follow lists are unavailable on your relays.

You can also tap the add-contact button beside a member who is not in your contacts, then confirm. Any member can use it, and adding a contact leaves session membership and unsaved session edits unchanged.

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

| Action                         | How                                                                                                                                                                                             |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| React to a post                | Open a post and tap 👍, 👎, 👀, or **…** for the emoji picker.                                                                                                                                  |
| Remove a reaction              | Tap the same emoji again.                                                                                                                                                                       |
| Share into linkstr             | Use the iOS share sheet from another app, choose linkstr, then choose share link. linkstr opens with the link prefilled, an optional note, and a separate searchable picker of active sessions. |
| Save shared media              | Use the iOS share sheet from another app, choose linkstr, then choose save media. linkstr prepares supported media and lets you choose Photos or Files.                                         |
| Share a deep link              | Open post detail and tap the share button in the top-right corner. The shared link carries only the normalized URL; linkstr fetches preview metadata again when the recipient opens it.         |
| Delete your own post           | Long-press the post row in the session view.                                                                                                                                                    |
| Archive or unarchive a session | Open a session, tap the members button, and use **archive session** or **unarchive session**.                                                                                                   |
| View archived sessions         | Tap the archive icon in the top-left Sessions toolbar.                                                                                                                                          |
| Rename a session               | Open a session, tap the members button, and edit the session name.                                                                                                                              |
| Delete a session               | Open a session, tap the members button, and use **delete session** in the manage sheet.                                                                                                         |
| Add or remove members          | Open session members. Expand **choose from contacts** to add someone, or long-press their row to **remove from session**. Confirm the change, then save.                                        |
| Copy a member's public key     | Open a session, tap the members button, then long-press a member's row and choose **copy public key**.                                                                                          |

Only the session creator can rename sessions, delete them, or change session membership.

### Relay settings

Open Settings to manage relays.

- If you have not changed relays, linkstr uses the current default relay set.
- You can add your own relay URLs.
- Enabled relays can be toggled on or off.
- Relay rows can be removed.
- **restore defaults** puts you back on the current default relay set.
- Tapping a relay connection alert opens relay settings.

---

## What works in-app

linkstr accepts normal web URLs, but in-app playback is provider-dependent.

**Extraction-preferred** (local playback attempted first, embed fallback available):

- TikTok videos
- Instagram Reels and video posts
- Facebook Reels and video posts
- Twitter/X statuses — only when provider metadata confirms video is present

**Embed-only** (web player only, no local extraction):

- YouTube
- Rumble
- TikTok Photo Mode posts
- Confirmed Instagram photo posts and photo-only carousels
- Twitter/X non-video statuses — only when the official tweet embed is available

**Browser fallback** covers everything else, plus any provider URL that blocks extraction or embed playback at runtime.

Local video playback loops without a repeat limit by default, inline and fullscreen. Turn off **loop local videos** in Settings → Playback to stop at the end of each video. Your choice is saved on this device and applies across accounts. Embedded playback behavior is controlled by the provider.

When local extraction succeeds, linkstr can cache the media on-device and offer **save to photos** or **save to files**. Embed-only playback stays network-backed and does not offer local export controls.

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

linkstr uses an APNs push service for iOS notifications. That service stores your APNs device token, your Nostr pubkey, archived conversation IDs used to suppress notifications for archived sessions, and lightweight push-dedupe bookkeeping so the same event is not pushed repeatedly. Dedupe records older than 30 days are removed when the service starts or handles a push request. Device tokens are removed when you unregister, switch the device to another account, or Apple permanently rejects them. Archive state is removed with the last registered token for an account.

Push alerts use generic text. Tapping a new-post or reaction alert opens the session's posts list without starting a video. Reaction alerts scroll to the reacted-to post once it arrives; older alerts without a target post ID simply open the list. If you start scrolling yourself, linkstr cancels any pending jump. This replaces the current screen even if you already have a post open. Missing or deleted target posts leave you in the list. Old push notifications are not replayed during historical restore.

Opening a post clears its delivered new-post and reaction alerts from Notification Center, including when you open it manually. Alerts for other posts and older reactions without a target post ID stay there. Opening just the app or session list does not clear them.

Archive updates send each saved archive/unarchive choice and clear filtering for deleted sessions. Restoring a session without its preference does not send an assumed unarchive. Sessions omitted from an update stay unchanged on the server, which retains only archived IDs for notification filtering.

Older builds can still archive and unarchive, but their push updates can clear notification suppression during an incomplete restore. Update all devices using the account to use explicit archive choices.

### Can I use my account in other Nostr apps?

Yes. Your `nsec` is a Nostr secret key, not a linkstr-only credential.

### What happens if I log out?

- **log out (keep local data)** removes the active identity from memory and keychain state but keeps the signed-in account's local sessions, posts, contacts, and caches on the device.
- **log out and clear local data** removes the active identity and deletes that account's local data. Cached files still used by another saved account are kept.

### What happens if I delete my account?

Deleting the account is relay-gated. linkstr only finishes the delete flow when it can reach a writable relay and get relay acceptance for the account-removal events.

When that succeeds, linkstr clears your local data on this device, logs you out, publishes an empty follow list, and sends a Nostr vanish request to your enabled relays.

Deleting the account does not invalidate the `nsec` itself. If you still have that key, you can sign in again later.

### Can I rename a session?

Yes. Open the session and tap the members button. That sheet shows the session name and current members for everyone. If you are the session creator, you can edit the name there and save to publish the updated name to all current members.

### Can I archive a session?

Yes. Open the session, tap the members button, and use **archive session** or **unarchive session**.

Archive changes whether the session appears in the active or archived list. This private choice syncs across linkstr devices using the same account. It does not delete the session or its posts.

### What happens when I add or remove a member?

The member list shows your draft changes. Adding or removing someone requires confirmation, then the top-right save button publishes the updated member list. Canceling the sheet discards those changes. Adding a member does not change your contacts. That person can receive content sent after they become an active member. Older posts are not retroactively shared with them.

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

Yes. Open the session, tap the members button, and use **delete session** in the manage sheet.

Delete is creator-only and requires confirmation. When it succeeds, linkstr removes the session from active and archived lists on this device, sends an encrypted delete notice to known members, and tries a best-effort relay-side delete for older transport copies when possible.

Delete is permanent for linkstr UX. There is no restore flow.

### Can I remove a contact?

Yes. Long-press the contact row and choose **remove contact**, or tap **remove contact** in the contact detail screen. After you confirm, linkstr updates your public follow list and removes the contact. Shared sessions and posts remain available. If relays reject the update, the contact stays saved and the app shows an error.

### Can I save videos?

Yes, for content you have the right to save. Save and export are available only when linkstr can extract and cache a local media file. Embed-only playback is provider-dependent and may not offer save or export even if the post plays in-app.

---

## Privacy and storage

### What data is stored locally?

linkstr stores your sessions, posts, reactions, contacts, read and archive choices, and media cache on the device, separately for each account. It also keeps records of membership changes, deletions, and public follows and unfollows so older relay responses cannot undo newer changes. Sensitive content fields are encrypted with local keys for each account.

### Where are account keys stored?

In the device keychain, with iOS-controlled protection. Simulator fallback storage is used only when simulator keychain access is unavailable.

Restoring encrypted local data also requires its original per-account encryption key, not just the `nsec`. If the key is temporarily unavailable, linkstr keeps the encrypted fields and can read them again when the original key becomes available. It does not generate a replacement key for existing encrypted data or while the persistent store cannot be opened.

If linkstr starts in temporary recovery mode, retry startup successfully before clearing local account data. The app cannot safely remove account data or its encryption key while the persistent store is unavailable.

### Will my aliases and archived sessions restore on a new phone?

linkstr backs up private aliases and archive choices to your Nostr relays, encrypted so only your account can read them. Importing the same `nsec` in linkstr can restore them, including cleared aliases and unarchived sessions. The contact or session must also be restored before its preference appears. This does not make your aliases public or change your public follows.

Changes made offline stay queued on the device until a relay accepts them. Keep the old installation until it has reconnected before switching phones. Restore depends on relay retention and availability; the `nsec` does not restore every local setting, read state, or cached file. Existing on-device encryption is unchanged.

There is no manual backup step. Once the initial preference subscription finishes, linkstr seeds existing aliases and archived sessions that do not have backup records yet. New changes upload while the app is active and a relay is ready, and pending uploads retry on reconnect. Restored archive choices also update push filtering before the session history arrives.

### Where are videos and previews stored?

Downloaded media and generated previews are stored in app-owned local storage. Video cache is treated as disposable device cache and trims itself automatically. Media saved via the share sheet goes to Photos or a Files location you choose. Settings can clear cached videos or saved preview metadata if you want to free space or force a preview rebuild.

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
3. If needed, use **restore defaults** in the relays section to go back to the current default relay set.
4. Bring the app back to the foreground and leave it open for a few seconds. linkstr treats this like a light reopen: it stops relay runtime whenever the app leaves the foreground and does one clean rebuild from a disconnected baseline when it becomes active again.
5. If it still does not recover, force-quit and reopen the app.

### My posts are not syncing across devices

1. Confirm both devices are signed in with the same `nsec`.
2. Confirm both devices can connect to relays.
3. Leave the app open long enough for relay sync to complete after reconnect.

Historical replay depends on relay retention. linkstr can retry out-of-order posts, reactions, and deletes locally, but it still needs the missing relay history to arrive.

### Videos won't play

1. Check your network connection.
2. Switch between **try local playback** and **use embedded**.
3. If a cached copy was auto-trimmed, try local playback again to re-cache it.
4. Use the refresh button in post detail if that post's metadata seems stale or missing.
5. Use **open in browser** if the provider blocks embedded playback.

### A preview looks stale or wrong

1. Use the refresh button in post detail to re-fetch metadata for that post.
2. Open the session, the post detail, or the shared-link screen and let linkstr rebuild the preview if metadata is still missing.
3. Settings can clear saved preview metadata if you want linkstr to rebuild it.
4. If the provider itself is serving bad metadata, use **open in browser**.

### I can't scan a QR code

1. Check camera permission in iOS Settings.
2. Use better lighting and a steady camera.
3. Paste the `npub` manually if needed.

---

## Contact

- GitHub issues: <https://github.com/therealparmesh/linkstr>
- Email: <parmesh@hey.com>

## Legal

By using linkstr, you agree to respect content creators' intellectual property rights and comply with applicable laws and platform terms when saving or sharing content.

linkstr is provided as-is. The developer is not responsible for user-generated content or misuse of saving features.

---

linkstr is open-source software built on the Nostr protocol.
