# Contact synchronization

Contacts mirror the signed-in account's public Nostr kind-3 follow list. Incoming follows are cached separately for each account and do not add contacts or session members automatically.

## Contact actions

Contact additions and removals require confirmation. Tap a contact row to edit it; long-press for **copy public key** followed by **remove contact**. Both actions are available as accessibility actions. Contact detail also has a **remove contact** button.

The **added you** list has a compact add-contact button and supports copying public keys from its long-press menu. Saved contacts show a checkmark with a descriptive accessibility label.

Session-member rows show a compact add-contact button only for people outside your contacts, with no **…** menus or contact-status badges. Copying and creator-only removal stay in the long-press menu and accessibility actions. The expandable **add members** list excludes existing members; adding or removing a member changes the draft only after confirmation and takes effect when the creator saves.

`ContactMutationQueue` serializes additions, removals, and account deletion so each action uses the last completed follow list. Quick-add leaves existing contacts and aliases unchanged. The manual add form can update an existing alias.

Publishing preserves non-contact tags and metadata on retained contact tags. A successful update saves the contacts, alias changes, and accepted event timestamp and ID together. Follow lists use NIP-01 ordering: the newer timestamp wins, with the lowest event ID breaking a tie.

If another device's newer list arrives during publication, the action retries using that list, up to three publication attempts. Concurrent edits from independent clients can still conflict; Nostr has no atomic merge for follow lists.

Replaying the current signed follow list restores tag metadata that older local stores did not retain. This preserves relay hints and other public tags when editing contacts after an upgrade.

Signing out cancels queued work. An action checks that its account and relay service are still current before applying a result. Rejected publications leave local contacts unchanged. If relays accept an update but local storage fails, the app reports that reconnecting is needed to sync the accepted list.

Removing a contact records a cleared private alias for backup. Shared sessions and membership stay intact. Adding a contact from session members also leaves unsaved session edits intact.

## Added you

The top-left Contacts toolbar button switches to **added you**, using the same pattern as archived sessions. Its person-with-checkmark icon fills when selected. Both lists keep their own search text and the top-right add-contact button. Incoming follows are ordered by follow-list timestamp, newest first, with public keys breaking ties. Nostr follow lists do not include a separate timestamp for adding each person; unrelated follow-list updates can also move someone up the list. The list has no status caption or inline loading indicator. Use the add-contact button beside a person to add them, or long-press their row to **copy public key**. Leaving the tab returns it to Contacts. Contact detail has its own back and save controls.

`ContactDiscovery` shares the app's relay connections. It finds kind-3 events containing the owner's public key, then requests those authors' latest lists without requiring that tag. This second request can find unfollows. Visible rows receive live author updates, and a separate subscription finds new follows while historical pages load.

Both screens keep cached rows visible during loading. Empty and search-empty messages wait for a completed request; failed or incomplete requests show a retry action when no matching rows are available. Contacts syncs the complete follow list without pagination. Added you searches the cached pages and offers **load more** when more results may be available. Neither screen adds a status caption or inline spinner.

Discovery pages start at 200 events. Author queries use batches of 50, with at most two active batches. Pages include the previous page's oldest timestamp to avoid skipping events with equal timestamps. If that boundary fills a page, the limit grows to at most 1,600 events before stopping pagination. Completion and timeout are tracked for each query and expected relay. A missing response does not count as an unfollow or a completed empty result. Failed pages do not advance the cursor.

Incoming event IDs and signatures are verified before saving. `FollowRelationshipEntity` stores the latest accepted follow or unfollow for each author and account. Unfollow records retain their timestamp and event ID so stale events cannot restore an old relationship. Account cleanup removes these records along with the contacts.

Opening the view, pulling to refresh, or reconnecting rechecks saved results. Leaving the view or replacing the relay service closes subscriptions and cancels query timers. Results depend on the configured relays and may omit follows stored elsewhere.

## Profile lookup and rendering

Profile lookups use at most two concurrent batches of 50 keys. Failed lookups make at most three attempts. Empty results or exhausted retries wait five minutes before another lookup can retry. Each attempt has a unique ID so a late completion cannot finish a newer request. Account changes clear lookup state; replacing the relay service cancels obsolete timers.

Public profiles use the same NIP-01 ordering as follow lists. A published empty name is valid metadata. Contact rows resolve names before searching and sorting, and session members use a public-key index to avoid repeated contact scans. Display names prefer the private alias, then the published name, then the `npub`. Public keys wrap in full without hyphenation in contact rows, member lists, previews, and contact detail. Name line limits do not apply to keys. Row menus, including member pickers, copy the complete key without changing selection; preview and detail text also support native selection and copying.

## Verification

Run `scripts/test.sh` for the app and push-service suites. `ContactManagementTests` covers queued mutations, concurrent remote changes, cancellation, aliases, and profile request limits. `ContactLoadingTests` checks relay completion and follow-list retries. `ContactDiscoveryTests` covers follow ordering, account isolation, invalid events, subscription lifecycle, duplicate delivery, and pagination boundaries. The disk migration fixture in `PrivatePreferenceTests` checks that adding incoming-follow storage preserves encrypted aliases.

For UI verification, check both toolbar modes, search reset, empty and partial results, adding contacts from **added you** and session members, and removal from both list and detail. Contact and session-member lists must have no **…** menus. Tapping a contact must open editing; long-press must show **copy public key** above **remove contact**. Session-member add-contact buttons must appear only for unsaved contacts and open confirmation. Long-press menus and accessibility actions must still reach removal confirmation. Verify that cancellation leaves contacts and membership unchanged, member actions preserve unsaved session edits, and the add-members list excludes people already in the draft. Returning from contact detail must restore the toolbar. Check named and unnamed contacts at larger text sizes: public keys must wrap without an ellipsis, and the add-contact preview must support native copying. Selecting a key must not add, remove, or edit a contact or member. Selectable public keys and post links must retain their native copy and share menus.
