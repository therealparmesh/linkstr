# linkstr support

_Last updated: November 12, 2026_

linkstr is a private link-sharing app built on [Nostr](https://nostr.com). You create or join private sessions, share links inside those sessions, and react with emoji. This page explains how to use the app.

---

## Quick start

### Create or import an account

1. Open linkstr.
2. Choose **create account** for a new account, import an existing secret key (`nsec`), or choose **restore backup** for a saved linkstr file.
3. If you create a new account, copy the displayed `nsec` and store it somewhere safe.
4. Optionally set a public profile name.

Your active account is stored in the device keychain. If you use iCloud Keychain, iOS may also sync that keychain item across your devices.

### Add contacts

1. Open **contacts**.
2. Tap the add-contact button.
3. Paste an `npub` or scan a QR code.
4. Optionally save a private alias.
5. Tap the top-right add icon, then confirm **add contact**.

Adding the same contact through this form updates the saved alias instead of creating a duplicate. The top-right button changes to **save contact**, and confirmation says whether the alias will be saved or cleared. To edit an alias later, tap the contact row. Compact identity rows shorten long public keys; contact detail shows the full key in its **public key (npub)** section. Long-press a contact or session-member row to copy its full public key. In the preview and contact detail, you can also long-press the key text to select and copy it.

Contacts keep their last fetched public Nostr name on this device, so names remain available after reopening or offline. Names refresh from relays when available; your private alias always takes priority.

The bottom footer shows validation and relay status only. The keyboard return key advances from the public key field into alias and asks for confirmation from alias.

### See who added you

1. Open **contacts**.
2. Tap **added you** below search.
3. Tap the add-contact button beside someone, then confirm. People already in your contacts show a checkmark.

Long-press a row to **copy public key**. Tap the back arrow to return to contacts. The top-right add-contact button is available in both lists.

The list shows public Nostr follows found on your configured relays, including follows made in other Nostr apps. Pull to refresh or use **load more** when available. Saved results remain visible offline. Empty results appear after loading finishes; if loading fails and there are no matching saved results, tap **try again**. Search covers people loaded so far, so use **load more** to search further back. People appear newest first by their latest public follow-list update. Nostr does not provide an exact date for when each person added you. People may be missing if their follow lists are unavailable on your relays.

You can also tap the add-contact button beside a member who is not in your contacts, then confirm. Any member can use it, and adding a contact leaves session membership and unsaved session edits unchanged.

### Create a session

1. Open **sessions**.
2. Tap the compose button in the top-right corner.
3. Enter a session name.
4. Optionally add contacts now, or start solo and add them later.
5. Tap the top-right create icon.

After creation, linkstr opens the session immediately.

The bottom footer shows validation and relay status only. The keyboard return key advances from the name field into member search and submits immediately when there are no contacts yet.

### Use the You tab

The **you** tab shows your public key (`npub`), QR code, and published profile name. You can copy or share your public key. Tap **edit profile** to change the name other Nostr apps see. Tap **settings** below the public key.

Submit profile name changes with the keyboard return key or the top-right **save profile name** control. To remove the name, clear its text and confirm with **clear profile name**. Validation and save progress appear in the bottom footer.

### Watch posts in a session

Open a session to see all its posts. Tap a post to open the viewer, then swipe up for the next older post or down for the previous newer one. **back to posts** returns to the post you were viewing, and **all session posts** opens the list from the top. The video icon in the post list opens **watch posts**, resuming the last viewed post or starting at the newest. Native portrait video can fill the viewer; expand the caption and choose **fit entire video**, then collapse the details, to see the full frame above the controls. Choose **fill screen** to return to the immersive layout. Tap the expand icon at the right of the playback bar to **open system player** and view the full video without post details. This also gives the video more space at larger text sizes. The app uses portrait on iPhone, with upside-down portrait where the device supports it. iPad also supports landscape. Official video players fit between the session header and the post controls while keeping their aspect ratio. Use **open in browser** to open the original link.

Long-press **all session posts** for **previous post**, **next post**, and **mark all as read** when available. These are also available as named accessibility actions on that button.

In the default local-video layout, the caption and reactions overlap the bottom of the video. Use **fit entire video** with details collapsed, or open the system player, when you need to see subtitles or content at the edges. Official players fit above the collapsed caption and reactions. Expanding details covers part of either type of video until you close them. Providers may also display their own captions and controls inside an embed.

Expand the caption row to switch players when both are available. Linkstr tries local extraction first on supported links. While the video is getting ready, expand the caption to use the official embed or open the link in your browser. **retry embed** reloads only the official player and remains available in the expanded controls even if a stuck player reports no error. Shared links show the player first, then the available title, description, and source. Scroll below the post information for **retry embed** and **open in browser**. It keeps you in embed mode. If the official player fails, use **try again**, return to extracted or downloaded playback when available, or open the source in your browser.

Tap the caption row for the full description, note, original URL, and post actions. Pull down from the top of the details to close them. **retry embed** and **open in browser** appear together when you’re using an official player. In **more post actions**, choose **refresh post** to clear cached playback, retry the media with local extraction first, and refresh the preview. The menu also contains **save video** when available and author actions. Regular links show their text in the preview card. Expanded details reserve space above the panel for that card. When the remaining area is too short, the card hides while its text and browser action remain available in the details; collapsing the panel restores the preview. Long cards and embedded posts scroll within their own area. Swipe on the viewer background to move between posts.

Tap 👍, 👎, or 👀 to add or remove your reaction. Tap the smiley with a plus for more emoji, or tap the two-person icon to see who reacted. Swipe the emoji row sideways for more counts. The picker, breakdown, and share buttons stay in place. In the emoji picker, search and tap a result to react. The keyboard’s Search key hides the keyboard without clearing your results.

### Share a link

1. Open a session.
2. Tap **share a link** at the top.
3. Paste a link.
4. Add a note if you like.
5. Tap **done** if you are editing, then **share to session**.

Regular web links are valid posts. HTTPS links to MP4, MOV, or M4V files can play directly. Playback and saving depend on the provider, link, and video format. The composer indicates when an in-app view is available.

You can also paste a shared linkstr post link into the link field, or share it back into linkstr through the iOS share sheet. The new post uses the original web URL. If the share extension can’t find a web link, it tells you what to share instead.

If you share from another app while signed out, finish signing in with linkstr still open. The composer then opens with the shared link and any note.

The footer shows relay status or errors next to the share button. The keyboard return key on the link field advances into the note field.

If the selected session becomes unavailable while sharing from another app, linkstr keeps your draft and disables sharing. If another active session is available, tap **choose a session** to select it. Otherwise, the recipient section explains that you need to create a session before sharing. Linkstr does not automatically switch to a different session.

### React, delete, rename, archive, and manage members

| Action                         | How                                                                                                                                                                                                                         |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| React to a post                | Tap 👍, 👎, or 👀 directly on the post, or tap the smiley with a plus to choose another emoji.                                                                                                                              |
| Remove a reaction              | Tap a selected quick emoji again. For another emoji, open the picker and tap your selected reaction in its top row.                                                                                                         |
| Share into linkstr             | Use the iOS share sheet from another app, choose linkstr, then **share to session**. linkstr opens with the link prefilled, an optional note, and a separate searchable picker of active sessions.                          |
| Save shared video              | Use the iOS share sheet from another app, choose linkstr, then choose **save video**. linkstr prepares supported video and lets you choose Photos or Files. If preparation fails, use **try again** or **open in browser**. |
| Share a deep link              | Tap the share button beside the quick reactions on the post. The recipient opens the original link in linkstr.                                                                                                              |
| Edit your own note             | Open **more** on a link you shared, then choose **edit note** or **add a note**. Clear the text, then confirm with **remove note** to remove it.                                                                            |
| Delete your own post           | Choose **delete post** from **more**, or long-press the post in the timeline.                                                                                                                                               |
| Archive or unarchive a session | Open **manage session** or **view members** from the post list, or tap the session name in the viewer. Use **archive session** or **unarchive session**.                                                                    |
| View archived sessions         | Tap the archive button beside **new session**.                                                                                                                                                                              |
| Rename a session               | Open **manage session**, edit the name, and save.                                                                                                                                                                           |
| Delete a session               | Open **manage session** and choose **delete session**.                                                                                                                                                                      |
| Add or remove members          | Open **manage session**. Expand **choose from contacts** to add someone, or use the remove button beside a member. Confirm the change, then save.                                                                           |
| Copy a member's public key     | Open **manage session** or **view members**, then long-press the member's row and choose **copy public key**.                                                                                                               |

Only the session creator can rename sessions, delete them, or change session membership. You can edit your own notes while you’re an active member. Edits keep the original post and its reactions in place.

### Relay settings

Open **you**, tap the gear, and find **relays**.

- If you have not changed relays, linkstr uses the current default relay set.
- You can add your own relay URLs.
- Enabled relays can be toggled on or off.
- Relay rows can be removed.
- **restore defaults** puts you back on the current default relay set.
- Tapping a relay connection alert opens relay settings.

---

## What works in-app

linkstr accepts normal web URLs, but in-app playback is provider-dependent.

**Direct video links** over HTTPS whose path ends in `.mp4`, `.mov`, or `.m4v` open in the native player. Saving is available once the video is cached.

**Extraction-preferred** (local playback attempted first, embed fallback available):

- TikTok videos
- Instagram Reels and video posts
- Facebook Reels and video posts
- Twitter/X statuses — only when provider metadata confirms video is present

**Embed-only** (web player only, no local extraction):

- YouTube videos and Shorts. Shorts use a portrait player.
- Rumble
- TikTok Photo Mode posts
- Confirmed Instagram photo posts and photo-only carousels
- Twitter/X non-video statuses — only when the official tweet embed is available

**Browser fallback** covers everything else, plus any provider URL that blocks extraction or embed playback at runtime.

Local video playback loops by default, inline and fullscreen. Turn off **loop local videos** under **you** → **settings** → **playback** to stop at the end of each video. Your choice is saved on this device and applies across accounts. Embedded playback behavior is controlled by the provider.

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

linkstr uses an APNs push service for iOS notifications. That service stores your APNs device token, your Nostr pubkey, archived conversation IDs used to suppress notifications for archived sessions, and lightweight push-dedupe bookkeeping so repeat requests do not queue the same event again. It saves pending delivery metadata and retries temporary failures for up to 15 minutes. Removing a device token or archiving a session cancels matching pending deliveries. Dedupe records older than 30 days are removed when the service starts or handles a push request. Device tokens are removed when you unregister, switch the device to another account, or Apple permanently rejects them. Archive state is removed with the last registered token for an account.

Push alerts use generic text. Tapping a new-post or reaction alert opens the session's posts list without starting a video. Reaction alerts scroll to the reacted-to post once it arrives; older alerts without a target post ID simply open the list. If you start scrolling yourself, linkstr cancels any pending jump. This replaces the current screen even if you already have a post open. Missing or deleted target posts leave you in the list. Old push notifications are not replayed during historical restore.

Opening a post clears its delivered new-post and reaction alerts from Notification Center, including when you open it manually. Alerts for other posts and older reactions without a target post ID stay there. Opening just the app or session list does not clear them. **mark all as read**, available by holding the **all session posts** list button while watching or beside the post count in the session list, marks the session’s saved incoming posts and clears their matching delivered alerts. It works offline, does not open or play posts, and leaves later arrivals unread.

Archive updates send each saved archive/unarchive choice and clear filtering for deleted sessions. Restoring a session without its preference does not send an assumed unarchive. Sessions omitted from an update stay unchanged on the server, which retains only archived IDs for notification filtering.

Older builds can still archive and unarchive, but their push updates can clear notification suppression during an incomplete restore. Update all devices using the account to use explicit archive choices.

### Can I use my account in other Nostr apps?

Yes. Your `nsec` is a Nostr secret key, not a linkstr-only credential.

### What happens if I log out?

- **log out and keep local data** removes the active identity from memory and keychain state but keeps the signed-in account's local sessions, posts, contacts, and caches on the device.
- **log out and clear local data** removes the active identity and deletes that account's local data. Cached files still used by another saved account are kept.

### What happens if I delete my account?

Deleting the account is relay-gated. linkstr only finishes the delete flow when it can reach a writable relay and get relay acceptance for the account-removal events.

When that succeeds, linkstr clears your local data on this device, logs you out, publishes an empty follow list, and sends a Nostr vanish request to your enabled relays.

Deleting the account does not invalidate the `nsec` itself. If you still have that key, you can sign in again later.

### Can I rename a session?

Yes. If you created the session, open **manage session** from the post list, edit the name, and save to publish the change to all current members. Members can see the name and current members under **view members**.

### Can I archive a session?

Yes. Open **manage session** or **view members** from the post list and choose **archive session** or **unarchive session**.

Archive changes whether the session appears in the active or archived list. This private choice syncs across linkstr devices using the same account. It does not delete the session or its posts.

### What happens when I add or remove a member?

The member list shows your draft changes. Adding or removing someone requires confirmation, then the top-right save button publishes the updated member list. Canceling the sheet discards those changes. Adding a member does not change your contacts. That person can receive content sent after they become an active member. Older posts are not retroactively shared with them.

Removing someone publishes another full snapshot. They stop receiving future posts and reactions, but anything they already received remains theirs.

If you are removed, linkstr keeps the session as read-only history. You can still view prior posts and reactions.

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

Yes. If you created the session, open **manage session** from the post list and choose **delete session**.

Delete is creator-only and requires confirmation. When it succeeds, linkstr removes the session from active and archived lists on this device, sends an encrypted delete notice to known members, and tries a best-effort relay-side delete for older transport copies when possible.

Delete is permanent for linkstr UX. There is no restore flow.

### Can I remove a contact?

Yes. Long-press the contact row and choose **remove contact**, or tap **remove contact** in the contact detail screen. After you confirm, linkstr updates your public follow list and removes the contact. Shared sessions and posts remain available. If relays reject the update, the contact stays saved and the app shows an error.

### Can I save videos?

Yes, for content you have the right to save. In a session, open **more** → **save video**, then choose Photos or Files. On a shared-link screen, use **save video**. Save and export are available only when linkstr can extract and cache a local media file. Embed-only playback is provider-dependent and may not offer save or export even if the post plays in-app.

---

## Privacy and storage

### What data is stored locally?

linkstr stores your sessions, posts, reactions, contacts, read and archive choices, and media cache on the device, separately for each account. It also keeps records of membership changes, deletions, and public follows and unfollows so older relay responses cannot undo newer changes. Sensitive content fields are encrypted with local keys for each account.

### Where are account keys stored?

In the device keychain, with iOS-controlled protection. Simulator fallback storage is used only when simulator keychain access is unavailable.

Restoring an encrypted database through an iOS system backup also requires its original per-account encryption key, not just the `nsec`. A linkstr backup file can be restored without the source device’s local key. If the key is temporarily unavailable, linkstr keeps the encrypted fields and can read them again when the original key becomes available. It does not generate a replacement key for existing encrypted data or while the persistent store cannot be opened.

If linkstr starts in temporary recovery mode, retry startup successfully before clearing local account data. The app cannot safely remove account data or its encryption key while the persistent store is unavailable.

### How do backup and restore work?

Open Settings and tap **backup**. Choose where to save the file in Files. Files remembers the last folder you selected. If it opens in local storage, use **Browse** to select **iCloud Drive** or another enabled provider, such as Google Drive or Dropbox. No linkstr folder is required.

The file includes your secret key, saved sessions and posts, contacts, membership and deletion history, reactions, read/archive choices, and app settings. It excludes cached videos, thumbnails, and previews. There is no password on the file. Keep it somewhere private: anyone with it can access your account.

On a fresh installation or after logging out, tap **restore backup**, choose the file, review its account and saved counts, then confirm. No separate secret-key entry is needed. Cancelling or choosing an invalid file leaves saved data unchanged. Restore merges that account's retained data and keeps newer changes, including removed contacts and deleted posts. Other saved accounts are not changed. Settings come from the backup.

Once the file is available locally, restore works offline. Reconnecting to relays can recover additional history they still hold. Duplicate messages merge without changing existing read choices. Keep a backup from a device with the history you need; relays may no longer retain missing messages.

### Will my aliases and archived sessions restore on a new phone?

linkstr backs up private aliases and archive choices to your Nostr relays, encrypted so only your account can read them. Importing the same `nsec` in linkstr can restore them, including cleared aliases and unarchived sessions. The contact or session must also be restored before its preference appears. This does not make your aliases public or change your public follows.

Changes made offline stay queued on the device until a relay accepts them. Keep the old installation until it has reconnected before switching phones. Restore depends on relay retention and availability; the `nsec` does not restore every local setting, read state, or cached file. Existing on-device encryption is unchanged.

These preferences sync automatically. Once the initial preference history request finishes, linkstr seeds existing aliases and archived sessions that do not have backup records yet. New changes upload while the app is active and a relay is ready, and pending uploads retry on reconnect. Restored archive choices also update push filtering before the session history arrives.

### Where are videos and previews stored?

Downloaded media and generated previews are stored in app-owned local storage. Video cache is treated as disposable device cache and trims itself automatically. Media saved via the share sheet goes to Photos or a Files location you choose. Settings can clear cached videos or saved preview metadata if you want to free space or force a preview rebuild.

If a prepared video is removed from the cache while the shared-save screen is open, **choose where to save** prepares it again before showing the destinations.

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
2. Open **you**, tap the gear, and check that at least one relay is enabled.
3. If needed, use **restore defaults** in the relays section to go back to the current default relay set.
4. Bring the app back to the foreground and leave it open for a few seconds. linkstr reconnects from a disconnected baseline after backgrounding, while retaining message deduplication for the same account. Brief interruptions such as opening Control Center do not restart the relay runtime.
5. If it still does not recover, force-quit and reopen the app.

### My posts are not syncing across devices

1. Confirm both devices are signed in with the same `nsec`.
2. Confirm both devices can connect to relays.
3. Leave the app open long enough for relay sync to complete after reconnect.

Historical replay depends on relay retention. linkstr can retry out-of-order posts, reactions, and deletes locally, but it still needs the missing relay history to arrive.

### Videos won't play

1. Check your network connection.
2. In a session, expand the caption row and try the other player when available.
3. If a cached copy was auto-trimmed, try local playback again to re-cache it.
4. Use **try again** on a playback error or **retry embed** to reload the official player. Use **refresh post** in **more post actions** to clear cached playback and retry the whole post.
5. Tap **open in browser** if the provider blocks playback.

### A preview looks stale or wrong

1. Expand the post details and choose **refresh post** from **more post actions**. This refreshes metadata, removes the cached video, and retries playback.
2. Open the post or the shared link to let linkstr rebuild a missing preview.
3. Settings can clear saved preview metadata if you want linkstr to rebuild it.
4. If the provider itself is serving bad metadata, use **open in browser**.

### Sharing from another app stays on “checking link…”

Linkstr waits for the source app to provide a web link. After 15 seconds, it replaces the spinner with recovery guidance. Close the share sheet and try sharing again from the original app. If the link arrives while the sheet is still open, the normal share and save actions appear automatically.

### A shared video won't save

1. If preparation fails, tap **try again** to check and download the video again.
2. If Photos access is denied, tap **choose where to save** and choose **save to files**, or allow Photos access in iOS Settings.
3. If a prepared file was removed from the cache, **choose where to save** downloads it again before offering destinations.
4. Use **open in browser** when the source does not provide a downloadable video.

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
