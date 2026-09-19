# Contact synchronization

Contacts mirror the signed-in account's public Nostr kind-3 follow list. Incoming follows are cached separately for each account and do not add contacts or session members automatically.

## Contact actions

Contact additions and removals require confirmation. Contact and session-member rows use **…** for non-destructive actions. Removal stays in the long-press menu and accessibility actions; contact detail also has a **remove contact** button. Session-member rows omit contact-status badges. The expandable **add members** list excludes existing members; adding or removing a member changes the draft only after confirmation and takes effect when the creator saves.

`ContactMutationQueue` serializes additions, removals, and account deletion so each action uses the last completed follow list. Quick-add leaves existing contacts and aliases unchanged. The manual add form can update an existing alias.

Publishing preserves non-contact tags and metadata on retained contact tags. A successful update saves the contacts, alias changes, and accepted event timestamp and ID together. Follow lists use NIP-01 ordering: the newer timestamp wins, with the lowest event ID breaking a tie.

If another device's newer list arrives during publication, the action retries using that list, up to three publication attempts. Concurrent edits from independent clients can still conflict; Nostr has no atomic merge for follow lists.

Replaying the current signed follow list restores tag metadata that older local stores did not retain. This preserves relay hints and other public tags when editing contacts after an upgrade.

Signing out cancels queued work. An action checks that its account and relay service are still current before applying a result. Rejected publications leave local contacts unchanged. If relays accept an update but local storage fails, the app reports that reconnecting is needed to sync the accepted list.

Removing a contact records a cleared private alias for backup. Shared sessions and membership stay intact. Adding a contact from session members also leaves unsaved session edits intact.

## Added you

The top-left Contacts toolbar button switches to **added you**, using the same pattern as archived sessions. Its person-with-checkmark icon fills when selected. Both lists keep their own search text and the top-right add-contact button. Use a person's **…** menu to **add contact** or **copy public key**. Leaving the tab returns it to Contacts. Contact detail has its own back and save controls.

`ContactDiscovery` shares the app's relay connections. It finds kind-3 events containing the owner's public key, then requests those authors' latest lists without requiring that tag. This second request can find unfollows. Visible rows receive live author updates, and a separate subscription finds new follows while historical pages load.

Discovery pages start at 200 events. Author queries use batches of 50, with at most two active batches. Pages include the previous page's oldest timestamp to avoid skipping events with equal timestamps. If that boundary fills a page, the limit grows to at most 1,600 events before reporting partial results. Completion and timeout are tracked for each query and expected relay. A missing response does not count as an unfollow.

Incoming event IDs and signatures are verified before saving. `FollowRelationshipEntity` stores the latest accepted follow or unfollow for each author and account. Unfollow records retain their timestamp and event ID so stale events cannot restore an old relationship. Account cleanup removes these records along with the contacts.

Opening the view, pulling to refresh, or reconnecting rechecks saved results. Leaving the view or replacing the relay service closes subscriptions and cancels query timers. Results depend on the configured relays and may omit follows stored elsewhere.

## Profile lookup and rendering

Profile lookups use at most two concurrent batches of 50 keys. Failed lookups make at most three attempts. Empty results or exhausted retries wait five minutes before another lookup can retry. Each attempt has a unique ID so a late completion cannot finish a newer request. Account changes clear lookup state; replacing the relay service cancels obsolete timers.

Public profiles use the same NIP-01 ordering as follow lists. A published empty name is valid metadata. Contact rows resolve names before searching and sorting, and session members use a public-key index to avoid repeated contact scans. Display names prefer the private alias, then the published name, then the `npub`.

## Verification

Run `scripts/test.sh` for the app and push-service suites. `ContactManagementTests` covers queued mutations, concurrent remote changes, cancellation, aliases, and profile request limits. `ContactDiscoveryTests` covers follow ordering, account isolation, invalid events, subscription lifecycle, duplicate delivery, and pagination boundaries. The disk migration fixture in `PrivatePreferenceTests` checks that adding incoming-follow storage preserves encrypted aliases.

For UI verification, check both toolbar modes, search reset, empty and partial results, adding contacts from **added you** and session members, and removal from both list and detail. Row **…** menus must omit removal; long-press menus and accessibility actions must still reach its confirmation. Verify that cancellation leaves contacts and membership unchanged, member actions preserve unsaved session edits, and the add-members list excludes people already in the draft. Returning from contact detail must restore the toolbar. Selectable public keys and post links must retain their native copy and share menus.
