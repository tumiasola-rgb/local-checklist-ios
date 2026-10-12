# Widget extension

Two iOS 17+ WidgetKit configurations share the app's local repository:

- **月历清单** (`systemLarge`): selected Gregorian month, complete 5/6-week grid,
  Chinese weekday labels, optional Chinese lunar-day labels, two task-bar lanes,
  and per-day hidden-task counts. Month arrows change the desktop widget through
  an AppIntent; tapping the month title resets to the current month. Day and task
  cells still open the corresponding app screen. The selected month is persisted
  in shared settings, so multiple copies of this widget show the same month.
- **今天待办** (`systemMedium`): incomplete overdue tasks followed by tasks occurring
  today. The number of displayed rows adapts to available widget height. Extra
  items link to the app; the widget is not scrollable.

`CompleteTodoIntent` updates the latest snapshot under the shared repository's
cross-process lock. It sets completion to `true`, preserves an existing completion
timestamp on repeated taps, and checks the captured store generation to reject
stale actions after a replacement import. A deleted task is not recreated.

`ShowCalendarMonthIntent` also uses generation-checked locked updates. Buttons
contain a validated first-of-month destination, not a relative increment, so a
repeated delayed tap cannot advance an extra month. An empty destination clears
the override and follows the current month, including future midnight rollover.
Explicitly selected months stay selected until changed/reset. The timeline date
always remains actual time, so today's highlight and Today tasks remain correct.
Rendering after an intent remains subject to WidgetKit, not a live-refresh promise.

Both configurations have next-local-midnight entries and request another timeline
after 15 minutes. WidgetKit controls actual refresh timing. App and intent reload
requests also do not guarantee immediate display updates. No networking is used.

The widget reads the exact App Group configured by `AppGroupIdentifier` in its
Info.plist. The app and extension must carry the same App Group entitlement. A
read error displays a visible “open App” message; widgets never reset a bad store.

## Verification status

Swift and Xcode are not installed in the Linux authoring environment. Native
compilation, Canvas layout, simulator interactions, device delivery, and VoiceOver
remain unverified. `WidgetPreviews.swift` contains in-memory fixture views for
five/six-week months and overflowing/empty Today lists; it never seeds user data.

Before distributing a build, verify on Xcode and an iOS 17+ device/simulator:

1. Build the widget extension with all Shared sources and exactly one widget
   `@main`. Check App Group entitlements and `AppGroupIdentifier` for both targets.
2. Add both widgets, including a small-screen iPhone and dark mode. Test a month
   requiring six weeks, Sunday/Monday starts, lunar labels on/off, long titles,
   multiple tasks per day, ranges crossing a week/month, and +N overflow.
3. Tap a date, task title, plus button, and Today heading. Confirm each route opens
   the matching main-app screen and date. Use both month arrows without opening
   the app, then tap the month title to reset. Repeat taps quickly, test December/
   January transitions, and verify the selection persists across reloads without
   moving today's highlight to the selected month. Check multiple widget copies.
   At supported year boundaries (0001/9999), unavailable arrows must be disabled
   and out-of-range adjacent-month cells blank, with no crash.
4. Complete a task from the widget; reopen the app to confirm it is saved. Tap
   repeatedly and from two widgets: the task must stay completed with its original
   completion timestamp. Delete or complete a task in-app before tapping a stale
   widget; it must not reappear or become incomplete.
5. Restore a backup while a stale widget is visible. Its old-generation action
   must fail rather than change the restored snapshot. Check simultaneous app
   edits and widget completion preserve unrelated fields.
6. Check empty data, inaccessible/corrupt shared storage, and app/extension first
   launch. Errors must stay explicit, with no reset or silent replacement.
7. Check local midnight/month rollover, DST, a device time-zone change, and a
   non-Gregorian preferred system calendar. Allow for WidgetKit refresh budgeting.
8. Check VoiceOver labels and Home Screen tinting. System rendering and device
   widget sizes can differ from the reference screenshot.
