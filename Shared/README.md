# Local data contract

The app and WidgetKit extension compile these same Swift sources. There are no networking calls in this module. It contains the shared durable sync ledger and scheduling models; only the app-only `Sync/` adapter talks to an explicitly paired device on the local network. Startup creates only an empty database; samples exist only in tests or separately labelled example files.

## Configuration and storage

- Both targets must have the same App Groups entitlement and `AppGroupIdentifier` Info.plist string. `SharedRepository()` throws if it is absent or unavailable; it never silently writes another database elsewhere.
- Production files live in the group's `LocalChecklist` directory: `snapshot.json`, `transaction.lock`, and, after a replacement import, `pre-import.json`.
- `SharedRepository(directory:)` is an isolated-test injection point. Do not use a purgeable cache/temp directory for production user data.
- Every read, update, and replacement obtains an exclusive POSIX `flock` on the same persistent lock file. Each operation opens its own descriptor. This protects both threads and independent app/widget processes. Never remove or atomically replace the lock file.
- Mutations read the latest state while locked, apply the intended changes, validate, write a sibling staging file, set its protection attributes, fsync it, and atomically rename it. The parent directory is then fsynced. No in-memory cache is treated as authoritative.
- iOS files use `completeUntilFirstUserAuthentication`. Mac Catalyst instead uses sandbox/POSIX file permissions and does not apply iOS DataProtection attributes. Before the first unlock after reboot, access can fail; that is an error, not an empty database.
- The directory and all committed/staging/lock files are marked `isExcludedFromBackup`, and the flag is reapplied/read back after replacement. Apple describes this as a backup-exclusion hint, not an absolute guarantee that a device backup/restore will never include the files. Local reading/writing needs no network account. Optional authenticated local-network pairing is described in `Documentation/IOS_MAC_LAN_SETUP.md`.

## API

- `read() throws -> AppSnapshot`
- `update(expectedGeneration: UUID? = nil, _ change: (inout AppSnapshot) throws -> Void) throws -> AppSnapshot`
- `updateSync(expectedGeneration: UUID? = nil, _ change: (inout AppSnapshot) throws -> Void) throws -> AppSnapshot` (coordinator-only; no fake local edits)
- `exportData() throws -> Data`
- `previewImport(_ data: Data) throws -> ImportPreview`
- `replace(with preview: ImportPreview, expectedGeneration: UUID) throws -> AppSnapshot`
- `readRecoveryPreview() throws -> ImportPreview?`
- `saveTask(_:isNew:expectedGeneration:expectedOriginal:)`, `setTaskCompleted(id:isCompleted:expectedGeneration:)`, `deleteTask(id:expectedGeneration:expectedOriginal:)`
- `saveNote(_:isNew:expectedGeneration:expectedOriginal:)`, `setNotePinned(id:isPinned:expectedGeneration:)`, `deleteNote(id:expectedGeneration:expectedOriginal:)`
- `saveAnniversary(_:isNew:expectedGeneration:expectedOriginal:)`, `deleteAnniversary(id:expectedGeneration:expectedOriginal:)`
- `saveList(_:isNew:expectedGeneration:expectedOriginal:)`, `deleteList(id:expectedGeneration:expectedOriginal:)`
- `saveSettings(_:expectedGeneration:)`, `recordSearch(_:expectedGeneration:)`

All convenience mutations return the committed snapshot. Pass the generation of the opened editor or displayed widget, including for deletions. Generation is a UUID; an AppIntent can carry `generation.uuidString`, validate it with `UUID(uuidString:)`, then pass the UUID into the repository. Replacement imports create a new generation. Ordinary edits increment revision without changing generation. An idempotent no-op keeps the revision unchanged.

`Settings.widgetCalendarMonth` is an optional `DayStamp` selecting the calendar widget's displayed month. A non-nil value must be the first day of its month; nil follows the current real month. AppIntent month navigation can update this one field in a generation-checked transaction. The current selection is included in JSON backups and recovery copies. Version-1 files that predate this optional field continue to decode as nil without a migration/reset.

Pass the original opened item in `expectedOriginal` when saving/deleting an existing item. If editable content changed meanwhile, the operation rejects the stale draft/confirmation; task completion and note pinning retain their dedicated merge behavior.

Use `isNew: true` for new drafts and `isNew: false` for existing-record editors. Leaving it nil requests upsert. `saveTask` preserves the latest completion status, timestamp, and creation timestamp; `saveNote` preserves the latest pin state. Use the dedicated explicit-state methods to change completion/pinning. List deletion retains tasks and clears their list association and any default-list preference.

Inside `update`, modify only intended fields of the supplied latest snapshot. Do not assign a stale whole snapshot, edit revision/generation, perform nested repository calls, or run slow/network work while holding the lock.

## Backup and recovery

The portable JSON object is `{ "format": "LocalChecklistBackup", "version": 2, "exportedAt": ..., "payload": ... }`. The on-disk envelope uses `LocalChecklistStore`, version 2, and a payload. Version 1 remains explicitly readable and migrates to v2 without resetting content; unknown versions fail closed. V2 requires a valid `sync` field and validates its visible projection against the main collections. Portable exports retain reviewable conflict content but remove account bindings, pairing credentials and enable/success state, and replace replica/counter/version identities with fresh anonymous roots. Date/timestamp fields are numeric milliseconds since the Unix epoch. `DayStamp` fields are Gregorian ASCII `YYYY-MM-DD` strings. JSON is UTF-8, sorted, and pretty-printed. The 20 MiB limit includes 1 KiB reserved storage headroom so a committed snapshot remains exportable.

Previewing validates the full file and reports counts without changing any disk data. Validation rejects unknown/missing fields, malformed types, invalid dates, duplicate IDs (including across record types), foreign-key references to missing lists, inconsistent completion timestamps, invalid times/ranges, and unsupported versions. It does not silently discard or repair records. Optional fields can be absent/null. Future versions are rejected before decoding their payload. Existing damaged or future-version stores are never automatically reset.

After the UI obtains explicit replacement confirmation, `replace` writes the current valid state as the one retained `pre-import.json` recovery copy before replacing the primary file. If recovery preparation fails, the primary state is unchanged and `.recoveryPreparationFailed` is thrown. Restoration uses `readRecoveryPreview` followed by the same explicit-confirmation `replace` flow; it preserves the pre-restore state as the new recovery copy. Each replacement creates a new sync epoch/causal root, pauses synchronization, and requires an explicit union-merge confirmation. Missing backup items never become automatic peer deletions.

`.committedMetadataFailure` is different: the primary atomic rename already succeeded, but protection metadata or a durability check failed afterward. Refresh/read the store before presenting this warning. Do not claim rollback or blindly replay the change. All validation and pre-rename write failures preserve the previous primary file.

## Civil days

`DayStamp(rawValue:)` is failable and validates the Gregorian leap-year rules. `DayStamp(date:calendar:)` uses the supplied time zone with Gregorian dates; its Date argument must be in years 1...9999 CE. `date(in:)` returns the first representable time on the day or nil for an entirely skipped day. `dayDifference(from:to:calendar:)` uses proleptic Gregorian civil arithmetic, so DST's 23/25-hour days and skipped time-zone days do not alter the day count.

`TodoItem.occurs(on:)` includes both boundaries of a date range. A task with one boundary occurs only on that day; an undated task does not populate every calendar day. Its `dueDay`/`scheduledDueDay` is `endDay ?? startDay`.

## Durable synchronization and schedules

Normal mutations allocate causal versions/outbox state in the same file transaction. A network acknowledgement, remote merge and acknowledgement use `updateSync`; they never infer local edits. Conflicting business fields retain every concurrent head, including delete/edit conflicts. Ordinary edits of known conflicts are blocked; explicit resolution checks the exact reviewed head-ID set. Identical business fields differing only in audit times do not trigger unnecessary review, but both causal heads remain stored. See `Documentation/IOS_MAC_LAN_SETUP.md` for the full protocol and limits.

`TodoItem.schedule` is optional for old data. It retains all-day mode, independently remembered end time, fixed schedule time zone, reminder offset/all-day clock, and daily/weekly/monthly/yearly rules with interval, optional weekdays and inclusive cutoff. Completion transactionally creates a deterministic next item when appropriate, with its ID derived only from the parent instance ID and a fixed namespace. Existing or tombstoned successors are not recreated. Uncompleting a task does not delete an already created successor. System notification permission is device-local and never exported/synced as a granted permission.

## Verification limits

XCTest coverage is provided in `Tests/SharedRepositoryTests.swift` and `Tests/DayStampTests.swift`, importing the `LocalChecklist` app module. It covers import rejection/preservation, round trips, recovery failure/restoration, stale generations, idempotent completion, concurrent independent repository instances, backup attributes, leap days, skipped days, and DST. This Linux authoring environment has no Swift or Xcode, so these tests have **not** been compiled or executed here. Python verification of the equivalent civil-day arithmetic is a supporting algorithm check, not a Swift test run. Device/simulator integration must additionally exercise app and widget as separate processes, protected data after reboot, and interrupted writes.
