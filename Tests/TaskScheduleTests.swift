import XCTest
@testable import LocalChecklist

final class TaskScheduleTests: XCTestCase {
    private func day(_ value: String) -> DayStamp { DayStamp(rawValue: value)! }
    private func task(_ value: String = "2026-10-07", minutes: Int? = 540, allDay: Bool = false) -> TodoItem {
        TodoItem(title: "Private title", detail: "Never put this into notifications", startDay: day(value), timeMinutes: minutes,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            schedule: TaskScheduleOptions(isAllDay: allDay, timeZoneIdentifier: "Asia/Shanghai", reminder: TaskReminder()))
    }
    func testDraftCancelDoesNotMutateOriginal() {
        let original = task()
        var draft = TaskScheduleDraft(task: original)
        draft.startDay = day("2027-01-01"); draft.startMinutes = 1020; draft.reminder = nil; draft.clear()
        XCTAssertEqual(original.startDay, day("2026-10-07"))
        XCTAssertNotNil(original.schedule?.reminder)
        // Dropping either value-only draft commits nothing.
    }
    func testClearIsPendingUntilConfirmAndClearsAllScheduleFields() throws {
        let original = task()
        var draft = TaskScheduleDraft(task: original); draft.clear()
        XCTAssertNotNil(original.startDay)
        let result = try XCTUnwrap(draft.confirmedTask())
        XCTAssertNil(result.startDay); XCTAssertNil(result.endDay)
        XCTAssertNil(result.timeMinutes); XCTAssertNil(result.schedule)
        XCTAssertEqual(result.title, original.title); XCTAssertEqual(result.id, original.id)
    }
    func testAllDayTogglePreservesIndependentStartAndEndMinutes() throws {
        var original = task(); original.endDay = original.startDay; original.schedule?.endTimeMinutes = 1020
        var draft = TaskScheduleDraft(task: original)
        draft.isAllDay = true
        let allDay = try XCTUnwrap(draft.confirmedTask())
        XCTAssertTrue(allDay.scheduleIsAllDay)
        XCTAssertEqual(allDay.timeMinutes, 540); XCTAssertEqual(allDay.schedule?.endTimeMinutes, 1020)
        var reopened = TaskScheduleDraft(task: allDay); reopened.isAllDay = false
        let restored = try XCTUnwrap(reopened.confirmedTask())
        XCTAssertFalse(restored.scheduleIsAllDay)
        XCTAssertEqual(restored.timeMinutes, 540); XCTAssertEqual(restored.schedule?.endTimeMinutes, 1020)
    }
    func testDraftRejectsReversedDateAndTimedRange() {
        var draft = TaskScheduleDraft(task: task()); draft.isRange = true
        draft.endDay = day("2026-10-06")
        XCTAssertNotNil(draft.validationMessage); XCTAssertNil(draft.confirmedTask())
        draft.endDay = draft.startDay; draft.endMinutes = 539
        XCTAssertNil(draft.confirmedTask())
        draft.isAllDay = true
        XCTAssertNotNil(draft.confirmedTask()) // Hidden clock values do not invalidate civil all-day dates.
    }
    func testLegacyTaskInfersAllDayWithoutRequiringNewFields() {
        let original = TodoItem(title: "Legacy", startDay: day("2026-10-07"))
        XCTAssertTrue(original.scheduleIsAllDay)
        XCTAssertTrue(TaskScheduleDraft(task: original).isAllDay)
        XCTAssertNil(TaskScheduleMath.reminderDate(for: original))
    }
    func testOneCivilDayBeforeAcrossSpringDSTRemainsSameClockTime() throws {
        var original = task("2026-03-08")
        original.schedule?.timeZoneIdentifier = "America/New_York"
        original.schedule?.reminder = TaskReminder(offsetMinutes: 1440)
        let calendar = try XCTUnwrap(TaskScheduleMath.calendar(for: original))
        let reminder = try XCTUnwrap(TaskScheduleMath.reminderDate(for: original))
        XCTAssertEqual(DayStamp(date: reminder, calendar: calendar), day("2026-03-07"))
        XCTAssertEqual(calendar.component(.hour, from: reminder), 9)
        let start = try XCTUnwrap(TaskScheduleMath.startDate(for: original))
        XCTAssertEqual(start.timeIntervalSince(reminder), 23 * 60 * 60, accuracy: 0.01)
    }
    func testDSTGapUsesNextExistingTimeAndFoldUsesFirstOccurrence() throws {
        let calendar = try XCTUnwrap(TaskScheduleMath.calendar(timeZoneIdentifier: "America/New_York"))
        let gap = try XCTUnwrap(TaskScheduleMath.date(day: day("2026-03-08"), minutes: 150, calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: gap), 3)
        XCTAssertEqual(calendar.component(.minute, from: gap), 0)
        let fold = try XCTUnwrap(TaskScheduleMath.date(day: day("2026-11-01"), minutes: 90, calendar: calendar))
        XCTAssertEqual(calendar.timeZone.secondsFromGMT(for: fold), -4 * 60 * 60)
    }
    func testEntireSkippedDayDoesNotBecomeDifferentDayReminder() {
        var original = task("2011-12-30")
        original.schedule?.timeZoneIdentifier = "Pacific/Apia"
        XCTAssertNil(TaskScheduleMath.reminderDate(for: original))
    }
    func testMonthlySkipsShortMonthAndYearlySkipsNonLeapYear() {
        XCTAssertEqual(TaskScheduleMath.nextDay(after: day("2026-01-31"), rule: TaskRecurrence(frequency: .monthly)), day("2026-03-31"))
        XCTAssertEqual(TaskScheduleMath.nextDay(after: day("2024-02-29"), rule: TaskRecurrence(frequency: .yearly)), day("2028-02-29"))
        XCTAssertEqual(TaskScheduleMath.nextDay(after: day("2026-01-31"), rule: TaskRecurrence(frequency: .monthly, interval: 2)), day("2026-03-31"))
    }
    func testWeeklySelectionHonorsIntervalFromMondayAndInclusiveUntil() {
        let rule = TaskRecurrence(frequency: .weekly, interval: 2, weekdays: [2, 6], untilDay: day("2026-10-19"))
        XCTAssertEqual(TaskScheduleMath.nextDay(after: day("2026-10-05"), rule: rule), day("2026-10-09"))
        XCTAssertEqual(TaskScheduleMath.nextDay(after: day("2026-10-09"), rule: rule), day("2026-10-19"))
        XCTAssertNil(TaskScheduleMath.nextDay(after: day("2026-10-19"), rule: rule))
    }
    func testRecurrenceStopsAtPersistedDateBounds() {
        XCTAssertNil(TaskScheduleMath.nextDay(after: day("9999-12-31"), rule: TaskRecurrence(frequency: .daily)))
        XCTAssertNil(TaskScheduleMath.nextDay(after: day("9999-12-31"), rule: TaskRecurrence(frequency: .yearly)))
    }
    func testNextOccurrencePreservesRangeAndStartsIncompleteWithStableIdentity() throws {
        var original = task("2026-10-07")
        original.endDay = day("2026-10-09"); original.schedule?.endTimeMinutes = 1020
        original.schedule?.recurrence = TaskRecurrence(frequency: .weekly)
        original.isCompleted = true; original.completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let next = try XCTUnwrap(nextOccurrence(after: original))
        XCTAssertFalse(next.isCompleted); XCTAssertNil(next.completedAt)
        XCTAssertEqual(next.startDay, day("2026-10-14")); XCTAssertEqual(next.endDay, day("2026-10-16"))
        XCTAssertEqual(next.timeMinutes, 540); XCTAssertEqual(next.schedule?.endTimeMinutes, 1020)
        var otherDevice = original
        otherDevice.completedAt = Date(timeIntervalSince1970: 1_900_000_000); otherDevice.updatedAt = otherDevice.completedAt!
        XCTAssertEqual(next, nextOccurrence(after: otherDevice))
        XCTAssertNotEqual(next.id, original.id)
        otherDevice.startDay = day("2026-10-08"); otherDevice.endDay = day("2026-10-10")
        XCTAssertEqual(next.id, nextOccurrence(after: otherDevice)?.id, "Concurrent parent edits must become a same-ID conflict, never two successors")
    }
    func testPlannerIsBoundedDeduplicatedAndIgnoresCompletedPastAndUndated() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-06T00:00:00Z")!
        var tasks = (0..<80).map { _ in task() }
        tasks.append(tasks[0])
        var completed = task(); completed.isCompleted = true; tasks.append(completed)
        tasks.append(task("2026-10-01")); tasks.append(task("2027-01-01"))
        var undated = task(); undated.startDay = nil; tasks.append(undated)
        let plan = TaskNotificationPlanner.plan(tasks: tasks, now: now, otherPendingCount: 5)
        XCTAssertEqual(plan.notifications.count, 55)
        XCTAssertEqual(plan.deferredCount, 26)
        XCTAssertEqual(plan.invalidCount, 1)
        XCTAssertEqual(Set(plan.notifications.map(\.identifier)).count, 55)
        XCTAssertTrue(plan.notifications.allSatisfy { $0.date > now })
        XCTAssertFalse(plan.notifications.contains { $0.taskID == completed.id })
    }
    func testScheduleCodableRoundTripRetainsRangeReminderAndRecurrence() throws {
        var original = task(); original.endDay = day("2026-10-08")
        original.schedule?.endTimeMinutes = 1050
        original.schedule?.recurrence = TaskRecurrence(frequency: .weekly, interval: 2, weekdays: [2, 4, 6], untilDay: day("2027-01-01"))
        XCTAssertEqual(try JSONDecoder().decode(TodoItem.self, from: JSONEncoder().encode(original)), original)
    }
}

@MainActor
private final class FakeTaskNotificationCenter: TaskNotificationCenterClient {
    var grant = LocalNotificationPermission(authorization: .authorized, alertsEnabled: true, soundsEnabled: true)
    var pending: [String: PlannedTaskNotification] = [:]
    var foreign = Set<String>()
    var delivered = Set<String>()
    var requests = 0
    var requestResponse: LocalNotificationPermission?
    var addCount = 0
    var failAdd = false
    var suspendNextAdd = false
    var suspended: CheckedContinuation<Void, Never>?
    var onSuspend: (() -> Void)?
    func permission() async -> LocalNotificationPermission { grant }
    func requestAuthorization() async throws -> Bool {
        requests += 1
        if let requestResponse { grant = requestResponse }
        return grant.canSchedule
    }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) + Array(foreign) }
    func deliveredIdentifiers() async -> [String] { Array(delivered) }
    func removePending(_ identifiers: [String]) {
        for id in identifiers { pending.removeValue(forKey: id); foreign.remove(id) }
    }
    func removeDelivered(_ identifiers: [String]) { delivered.subtract(identifiers) }
    func add(_ notification: PlannedTaskNotification) async throws {
        if suspendNextAdd {
            suspendNextAdd = false
            await withCheckedContinuation { continuation in suspended = continuation; onSuspend?() }
        }
        if failAdd { throw NSError(domain: "test", code: 1) }
        addCount += 1; pending[notification.identifier] = notification
    }
}

final class TaskNotificationSchedulerTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-06T00:00:00Z")!
    private func task() -> TodoItem {
        TodoItem(title: "Private", startDay: DayStamp(rawValue: "2026-10-07")!, timeMinutes: 540,
            schedule: TaskScheduleOptions(isAllDay: false, timeZoneIdentifier: "Asia/Shanghai", reminder: TaskReminder()))
    }
    @MainActor
    func testRebuildNeverRequestsPermissionAndDeniedRemovesOnlyOwnedRequests() async {
        let client = FakeTaskNotificationCenter(); client.grant = .init(authorization: .denied, alertsEnabled: false, soundsEnabled: false)
        let task = task(); let id = TaskNotificationPlanner.identifier(for: task.id)
        client.pending[id] = PlannedTaskNotification(identifier: id, taskID: task.id, date: now)
        client.foreign = ["unrelated-feature"]
        let scheduler = LocalNotificationScheduler(client: client, now: { self.now })
        let status = await scheduler.rebuild(tasks: [task])
        XCTAssertEqual(client.requests, 0); XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(client.foreign, ["unrelated-feature"])
        XCTAssertEqual(status.permission.authorization, .denied)
        XCTAssertTrue(status.summary.contains("不会通知"))
    }
    @MainActor
    func testExplicitPermissionRequestIsContextualAndDenialIsNotRequestedAgain() async {
        let client = FakeTaskNotificationCenter()
        client.grant = .init(authorization: .notDetermined, alertsEnabled: false, soundsEnabled: false)
        client.requestResponse = .init(authorization: .denied, alertsEnabled: false, soundsEnabled: false)
        let scheduler = LocalNotificationScheduler(client: client, now: { self.now })
        _ = await scheduler.rebuild(tasks: [task()])
        XCTAssertEqual(client.requests, 0)
        let firstGrant = await scheduler.requestAuthorizationForReminder()
        let secondGrant = await scheduler.requestAuthorizationForReminder()
        XCTAssertFalse(firstGrant); XCTAssertFalse(secondGrant)
        XCTAssertEqual(client.requests, 1)
        XCTAssertEqual(scheduler.status.permission.authorization, .denied)
    }
    @MainActor
    func testRepeatedRebuildUsesOneIDAndCompletionDeletionRemoveDeliveredAndPending() async {
        let client = FakeTaskNotificationCenter(); let task = task()
        let scheduler = LocalNotificationScheduler(client: client, now: { self.now })
        _ = await scheduler.rebuild(tasks: [task]); _ = await scheduler.rebuild(tasks: [task])
        XCTAssertEqual(client.pending.count, 1)
        client.delivered = [TaskNotificationPlanner.identifier(for: task.id), "unrelated-feature"]
        var completed = task; completed.isCompleted = true
        _ = await scheduler.rebuild(tasks: [completed])
        XCTAssertTrue(client.pending.isEmpty); XCTAssertEqual(client.delivered, ["unrelated-feature"])
        _ = await scheduler.rebuild(tasks: [task]); _ = await scheduler.rebuild(tasks: [])
        XCTAssertTrue(client.pending.isEmpty)
    }
    @MainActor
    func testNewerSnapshotWinsDuringSuspendedSystemAdd() async {
        let client = FakeTaskNotificationCenter(); client.suspendNextAdd = true
        let entered = expectation(description: "old add suspended")
        client.onSuspend = { entered.fulfill() }
        let task = task(); var latest = [task]
        let scheduler = LocalNotificationScheduler(client: client, now: { self.now })
        let first = Task { await scheduler.rebuild(tasks: [task], readLatestTasks: { latest }) }
        await fulfillment(of: [entered], timeout: 2)
        latest = [] // Completion/deletion/import while the OS call was suspended.
        let second = Task { await scheduler.rebuild(tasks: [], readLatestTasks: { latest }) }
        client.suspended?.resume(); client.suspended = nil
        _ = await first.value; _ = await second.value
        XCTAssertTrue(client.pending.isEmpty, "A stale async add must be removed by the newest drain")
    }
    @MainActor
    func testUnavailableAuthoritativeStoreFailsClosedWithoutTouchingForeignNotifications() async {
        let client = FakeTaskNotificationCenter(); let task = task()
        let scheduler = LocalNotificationScheduler(client: client, now: { self.now })
        _ = await scheduler.rebuild(tasks: [task]); client.foreign = ["other"]
        let status = await scheduler.rebuild(tasks: [task], readLatestTasks: { throw NSError(domain: "repository", code: 1) })
        XCTAssertTrue(client.pending.isEmpty); XCTAssertEqual(client.foreign, ["other"])
        XCTAssertNotNil(status.failure)
    }
    @MainActor
    func testFailedReplacementRemovesOldReminderAndReportsFailure() async {
        let client = FakeTaskNotificationCenter(); var task = task()
        let scheduler = LocalNotificationScheduler(client: client, now: { self.now })
        _ = await scheduler.rebuild(tasks: [task]); client.failAdd = true
        task.timeMinutes = 600
        let status = await scheduler.rebuild(tasks: [task])
        XCTAssertTrue(client.pending.isEmpty); XCTAssertEqual(status.failureCount, 1)
    }
}
