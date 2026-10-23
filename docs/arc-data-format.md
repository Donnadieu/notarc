# Arc on-disk data format (Arc 1.169.0, macOS)

Observed from a live install. Location: `~/Library/Application Support/Arc/`.
Everything here was learned by reading the export files in a user's own Arc data folder, so NotArc can import them. Nothing comes from Arc's source code or program files.

## Files

| File | Purpose |
|---|---|
| `StorableSidebar.json` | Spaces, pinned/unpinned tabs, folders, sync state. Main import source. |
| `StorableWindows.json` | Open windows: focused Space, sidebar width/mode, split view, expanded folders. |
| `StorableArchiveItems.json` | Archived (auto-closed) tabs, the Library archive. |
| `StorableCommandBarAdditionalRanking.json` | Command bar ranking history. |
| `StorableKeyBindings.json` | Custom keyboard shortcuts. |
| `StorableLinkRouting.json` | Link routing rules (which Space opens which links). |
| `StorableHome.json`, `StorableSessionRestorationData.json` | Startup and session restore. |
| `StorableAuthState.json`, `StorableFirebaseEncryptionKey.json`, `StorableMembershipCard.json` | Arc account and Firebase sync. Not needed for a local port. |
| `Storable*.YYYY-MM-DD-HH-MM-SS-mmm.json` | Arc's rolling backups of each file. |
| `User Data/` | Standard Chromium profile directory (`Profile N/`: history, cookies, passwords, extensions). |

Timestamps are seconds since 2001-01-01 UTC (Apple `NSDate` reference date), not Unix time.

## StorableSidebar.json

Top level:

```
version: int
sidebar.containers: [ {global:{}}, <main container>, {littleBrowser:{}}?, <extra container>? ]
# Extra containers appear while Little Arc / standalone windows exist: same shape, one untitled Space.
# Pick the container with the most titled Spaces as the main sidebar.
sidebarSyncState: CloudKit sync state (serverChangeToken, encodedCKRecordFields)
firebaseSyncState: Firebase sync state (syncData, unacknowledgedItemDeletions, syncHealthStatus)
```

### Encoding rule

Swift `Dictionary` values are serialised as flat alternating arrays: `[key, value, key, value, ...]`.
This applies to `spaces`, `items` and `windowContentSidebarItemMap.keysToValues`.
For example, `items` with 108 entries holds 54 items.

### Main container

```
spaces: [id, Space, ...]
items: [id, Item, ...]
topAppsContainerIDs: [...]    # per-profile favourites ("top apps") containers
```

### Space

```
id: UUID
title: string
profile: {custom: {_0: {directoryBasename: "Profile 4", machineID: UUID}}}  # Chromium profile backing this Space
containerIDs: ["pinned", <UUID>, "unpinned", <UUID>]
newContainerIDs: [{pinned:{}}, <UUID>, {unpinned:{_0:{shared:{}}}}, <UUID>]
customInfo: {}   # theme/icon when set
```

Each Space owns two root item containers: pinned and unpinned (Today).
Each Space maps to its own Chromium profile directory, which is how Arc isolates cookies per Space.

### Item

```
id: UUID
parentID: UUID | null
childrenIds: [UUID]   # ordered; this is sidebar order
title: string | null  # user rename overrides savedTitle
isUnread: bool
createdAt: NSDate seconds
originatingDevice: UUID
data: one of
  tab: {savedTitle, savedURL, savedMuteStatus, timeLastActiveAt, activeTabBeforeCreationID}
  itemContainer: {containerType: spaceItems | topApps{custom{machineID, directoryBasename}}}
  (folders: nested containers; none present in the sample, still to be confirmed)
```

Tree: Space → pinned/unpinned container (`itemContainer`, `spaceItems`) → items via `childrenIds` → nested items for folders.
Sample: 3 Spaces, 42 tabs, 6 Space containers, 6 top-apps containers.

### Favorites (`topApps`)

The icon grid at the top of Arc's sidebar. It is not stored per Space: there is one `topApps` container per Chromium profile
(`containerType.topApps._0.custom._0.directoryBasename`, or `topApps._0.default = true` for the `Default` profile).
Spaces that share a profile share the same Favorites. Confirmed against the live data: 3 Spaces on Profiles 2/3/4 plus a
`Default`-profile Favorites set (6 tabs) that no Space currently uses. 34 of 40 tabs belong to a Space; the other 6 are those
Default-profile favourites.

## StorableWindows.json

```
windows: [{
  id, sidebarWidth, sidebarMode: "anchored" | ..., stayOnTop,
  focusedSpaceID,
  expandedItems: [UUID],                     # open folders
  spacesWithCollapsedPinnedSection: [...],
  itemLastActiveDates: [id, NSDate, ...],
  contents: {
    windowContents: [id, {id}, ...],
    splitViewState: {windowContentIDs, focusedContentID},
    windowContentSidebarItemMap: {keysToValues: [contentID, sidebarItemID, ...]}
  },
  style: {standard: {sidebarContext: {global:{}}}}
}]
```

## What NotArc does with this

1. Importer: parse `StorableSidebar.json` → Spaces, pinned/unpinned trees, folders; convert NSDate times.
2. One CEF request context per Space, pointed at the matching Chromium profile, to keep cookie isolation and reuse existing logins.
3. Local-only storage. CloudKit and Firebase sync fields are ignored.

## StorableArchiveItems.json (Archive)

```
version: 1
items: [id, {reason, sidebarItem: <Item as in the sidebar>, source, archivedAt: NSDate}, ...]
reason: "manual" (closed by user) | "auto" (auto-archive) | "clearTabGroup"
source: {space:{_0: spaceID}} | {littleArc:{}} | {standaloneSidebar:{}} | {unknown:{}}
```

Sample: 7,055 archived tabs (6,663 manual, 389 auto, 3 clearTabGroup), Aug 24 to Oct 23 2026.

Auto-archive, as seen in the data:
- Arc's settings offer 6 hours, 12 hours, 24 hours, 7 days, 30 days or never, chosen per profile
  (preference key `autoArchiveTimeThresholdsPerProfile`).
- For auto-archived tabs, `archivedAt - timeLastActiveAt` is 12.0 hours at both the 10th and 50th percentile and
  12.1 hours at the 90th, so the default is 12 hours of inactivity. One profile shows 6.0 hours.
- Only Today (unpinned) tabs are archived. Pinned tabs and Favorites are not.

## Open questions

- Exact folder (`list`) encoding and nesting limits.
- Space theme/icon fields inside `customInfo`.
- Auto-archive rules for unpinned tabs (`StorableArchive.autoArchiveStartTime`, `StorableArchiveItems.json`).
