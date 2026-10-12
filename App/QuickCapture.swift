import Foundation

// MARK: - Pure, local draft parsing (no model, network, or executable input)

enum QuickCaptureKind: String, CaseIterable, Codable, Sendable {
    case task, note
    var label: String { self == .task ? "待办" : "备忘" }
}

struct QuickCaptureDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: QuickCaptureKind
    var title: String
    var body: String
    /// The unedited line represented by this candidate.
    var originalText: String
    /// The entire unedited input, including blank lines and other candidates.
    var sourceText: String
    var dueDate: Date?
    var hasTime = false
    var dateNeedsReview = false
    var dateReviewNote: String?
    var isSelected = true
}

enum QuickCaptureParser {
    /// Intentionally conservative rules, not general language understanding.
    /// Nothing in the input is executed or treated as an instruction to this app.
    static func parse(_ source: String, now: Date = Date(), calendar: Calendar = .current) -> [QuickCaptureDraft] {
        source.components(separatedBy: .newlines).compactMap { original in
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let text = replacing(#"^\s*(?:[-*•]\s+|\[[ xX]\]\s*|\d+[.)、]\s*)"#, in: trimmed, with: "")
            let normalized = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
            let parsed = parseDate(normalized, now: now, calendar: calendar)
            let hasTaskCue = matches(#"提醒|记得|記得|待办|待辦|TODO|to-do|remind|remember|别忘|別忘"#, in: text, insensitive: true).count > 0
            let hasListCue = matches(#"^(?:[-*•]\s+|\[[ xX]\]|\d+[.)、])"#, in: trimmed).count > 0
            let kind: QuickCaptureKind = hasTaskCue || hasListCue || parsed.hasDateCue ? .task : .note
            let titleText = replacing(#"^(?:提醒我|提醒|记得|記得|待办[:：]?|待辦[:：]?|备忘[:：]?|備忘[:：]?)\s*"#, in: text, with: "")
            // Only the display title is shortened. Body, originalText, and sourceText remain complete.
            let title = titleText.isEmpty ? String(text.prefix(64)) : String(titleText.prefix(64))
            return QuickCaptureDraft(kind: kind, title: title, body: text,
                                     originalText: original, sourceText: source,
                                     dueDate: parsed.date, hasTime: parsed.hasTime,
                                     dateNeedsReview: parsed.needsReview, dateReviewNote: parsed.note)
        }
    }

    private struct ParsedDate {
        var date: Date?
        var hasTime = false
        var needsReview = false
        var note: String?
        var hasDateCue = false
    }

    private static func parseDate(_ text: String, now: Date, calendar: Calendar) -> ParsedDate {
        // Numeric full dates are interpreted in the Gregorian calendar, in the device time zone.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        var output = ParsedDate()
        let fullPattern = #"(?<!\d)(\d{4})[年/\-](\d{1,2})[月/\-](\d{1,2})(?:日|号|號)?(?!\d)"#
        let fullDates = matches(fullPattern, in: text)
        let relatives = matches(#"大后天|大後天|后天|後天|明天|今天|今日|今晚|昨天|前天"#, in: text)
        let allShortDates = matches(#"(?<!\d)\d{1,2}月\d{1,2}(?:日|号|號)?|(?<![\d/\-])\d{1,2}[/\-]\d{1,2}(?![\d/\-])"#, in: text)
        let shortDates = allShortDates.filter { short in
            !fullDates.contains { NSLocationInRange(short.range.location, $0.range) }
        }
        let unsupportedDate = matches(#"(?:下|本|这|這|上)?(?:周|週|星期)[一二三四五六日天1-7]|(?:下|本|这|這|上)个?月|月底|月末|明年|年底|周末|週末|(?:每|隔)(?:天|日|周|週|月)|一会|一會|稍后|稍後|晚点|晚點|过几天|過幾天|过[一二两三四五六七八九十\d]+天|[一二两三四五六七八九十\d]+(?:分钟|分鐘|小时|小時|天)后|[零〇一二两三四五六七八九十]+月[零〇一二两三四五六七八九十]+[日号號]|(?i:tomorrow|today|tonight|next (?:week|month|monday|tuesday|wednesday|thursday|friday|saturday|sunday))"#, in: text)
        output.hasDateCue = !fullDates.isEmpty || !relatives.isEmpty || !shortDates.isEmpty || !unsupportedDate.isEmpty
        if fullDates.count + relatives.count + shortDates.count > 1 || !unsupportedDate.isEmpty {
            output.needsReview = true
            output.note = "有多个日期、重复安排或未支持的相对日期，请手动核对；不会自动设置提醒。"
        } else if let full = fullDates.first,
                  let year = integer(group: 1, match: full, text: text),
                  let month = integer(group: 2, match: full, text: text),
                  let day = integer(group: 3, match: full, text: text) {
            output.date = exactDate(year: year, month: month, day: day, calendar: gregorian)
            if output.date == nil {
                output.needsReview = true
                output.note = "日期无效，请手动选择正确日期或不设日期。"
            }
        } else if let relative = relatives.first, let range = Range(relative.range, in: text) {
            let token = String(text[range])
            let offsets = ["今天": 0, "今日": 0, "今晚": 0, "明天": 1, "后天": 2, "後天": 2, "昨天": -1, "前天": -2]
            if let offset = offsets[token] {
                output.date = gregorian.date(byAdding: .day, value: offset, to: gregorian.startOfDay(for: now))
            } else {
                output.needsReview = true
                output.note = "这个相对日期需要手动确认。"
            }
        } else if !shortDates.isEmpty {
            output.needsReview = true
            output.note = "日期没有年份或格式不明确，请手动确认；不会猜测年份。"
        }

        let timePattern = #"(?:(上午|早上|早晨|凌晨|中午|下午|晚上|傍晚|晚间)\s*)?([零〇一二两三四五六七八九十\d]{1,3})(?:[:：]([0-9]{2})|[点點时時](?:(半|一刻|三刻)|([零〇一二两三四五六七八九十\d]{1,3})分?)?)"#
        let times = matches(timePattern, in: text)
        if !times.isEmpty { output.hasDateCue = true }
        if times.count > 1 {
            output.needsReview = true
            output.note = "有多个时间，请逐条拆开或手动选择日期时间。"
            output.date = nil
        } else if let match = times.first {
            output.hasDateCue = true
            let period = group(1, match: match, text: text)
            let rawHour = chineseInteger(group(2, match: match, text: text))
            let colonMinute = group(3, match: match, text: text)
            let fraction = group(4, match: match, text: text)
            let spokenMinute = group(5, match: match, text: text)
            let minute = colonMinute.flatMap(Int.init) ?? ["半": 30, "一刻": 15, "三刻": 45][fraction ?? ""] ?? chineseInteger(spokenMinute) ?? 0
            var hour = rawHour
            var ambiguous = false
            if let value = rawHour, let period {
                if ["下午", "晚上", "傍晚", "晚间"].contains(period) {
                    if (1...11).contains(value) { hour = value + 12 }
                    else if value == 12 && period != "下午" { ambiguous = true }
                    else if value != 12 { ambiguous = true }
                } else if period == "中午" {
                    if value == 12 { hour = 12 }
                    else if value == 1 || value == 2 { hour = value + 12 }
                    else { ambiguous = true }
                } else if period == "凌晨", value == 12 {
                    hour = 0
                } else if value >= 12 {
                    ambiguous = true
                }
            } else if let value = rawHour, colonMinute == nil, (1...12).contains(value) {
                ambiguous = true // “3点” does not say AM or PM.
            }
            if let hour, (0...23).contains(hour), (0...59).contains(minute), !ambiguous,
               let day = output.date, !output.needsReview {
                var components = gregorian.dateComponents([.year, .month, .day], from: day)
                components.hour = hour
                components.minute = minute
                if let date = gregorian.date(from: components),
                   gregorian.component(.hour, from: date) == hour,
                   gregorian.component(.minute, from: date) == minute {
                    // A repeated clock time during DST has two possible instants.
                    let start = gregorian.startOfDay(for: day).addingTimeInterval(-1)
                    let clock = DateComponents(hour: hour, minute: minute, second: 0)
                    let first = gregorian.nextDate(after: start, matching: clock, matchingPolicy: .strict, repeatedTimePolicy: .first)
                    let last = gregorian.nextDate(after: start, matching: clock, matchingPolicy: .strict, repeatedTimePolicy: .last)
                    if let first, let last, first != last {
                        output.date = nil
                        output.needsReview = true
                        output.note = "此时间处于时区夏令时切换的重复时段，请手动确认。"
                    } else {
                        output.date = date
                        output.hasTime = true
                    }
                } else {
                    output.date = nil
                    output.needsReview = true
                    output.note = "这个时间在当前时区不存在，请手动确认。"
                }
            } else {
                output.date = nil
                output.hasTime = false
                output.needsReview = true
                output.note = "时间缺少日期、上午/下午不明确或数值无效，请手动确认。"
            }
        } else if !matches(#"上午|下午|中午|晚上|傍晚|早上|今晚|早晨|凌晨"#, in: text).isEmpty {
            output.hasDateCue = true
            output.needsReview = true
            output.note = "只有大致时段，未猜测具体时间；可保留日期或手动补充时间。"
        }
        if !matches(#"(?:大约|大約|大概|差不多|左右|前后|前後|[点點]多)|(?i:\d{1,2}\s*(?:a\.?m\.?|p\.?m\.?))"#, in: text).isEmpty && output.hasDateCue {
            output.needsReview = true
            output.note = "时间含大致范围或未支持的写法，请核对日期时间；不会自动设置提醒。"
        }
        if let date = output.date, date < (output.hasTime ? now : gregorian.startOfDay(for: now)) {
            output.needsReview = true
            output.note = "识别到的日期时间已经过去，请核对后再保存。"
        }
        return output
    }

    private static func exactDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    private static func chineseInteger(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        if let number = Int(text) { return number }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text.count == 1, let character = text.first { return character == "十" ? 10 : digits[character] }
        let parts = text.components(separatedBy: "十")
        guard parts.count == 2, parts[0].count <= 1, parts[1].count <= 1 else { return nil }
        let tens = parts[0].isEmpty ? 1 : parts[0].first.flatMap { digits[$0] }
        let ones = parts[1].isEmpty ? 0 : parts[1].first.flatMap { digits[$0] }
        guard let tens, let ones else { return nil }
        return tens * 10 + ones
    }

    private static func matches(_ pattern: String, in text: String, insensitive: Bool = false) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : []) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ index: Int, match: NSTextCheckingResult, text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func integer(group index: Int, match: NSTextCheckingResult, text: String) -> Int? {
        group(index, match: match, text: text).flatMap(Int.init)
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}

#if os(iOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import Combine
@preconcurrency import Vision
@preconcurrency import Speech
@preconcurrency import AVFoundation

// MARK: - On-device OCR

private enum QuickCaptureError: LocalizedError {
    case unreadableImage, imageTooLarge, chineseOCRUnavailable, noText
    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "无法读取这张图片。请选择已下载到本机的 JPEG、PNG 或 HEIC 图片。"
        case .imageTooLarge: return "图片超过 30 MB，请缩小图片后重试；没有保存或截断识别文字。"
        case .chineseOCRUnavailable: return "当前系统无法使用中文图片识别，请手动输入。"
        case .noText: return "没有识别到文字。请换一张清晰图片，或手动输入。"
        }
    }
}

private enum LocalImageOCR {
    static func recognize(_ data: Data) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard data.count <= 30 * 1024 * 1024 else { throw QuickCaptureError.imageTooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw QuickCaptureError.unreadableImage }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // Chinese correction is not supported.
            let supported = try request.supportedRecognitionLanguages()
            let languages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
            guard languages.contains(where: { $0.hasPrefix("zh") }) else { throw QuickCaptureError.chineseOCRUnavailable }
            request.recognitionLanguages = languages
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            try Task.checkCancellation()
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QuickCaptureError.noText }
            return text
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

// SFSpeechAudioBufferRecognitionRequest is a reference type shared only between
// the audio render callback and main-actor shutdown. Locking serializes append
// and endAudio; no UI or actor state is captured by the audio callback.
private final class AudioRequestBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var ended = false
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if !ended { request.append(buffer) }
    }
    func end() {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        ended = true
        request.endAudio()
    }
}

// MARK: - Deliberately offline-only speech capture

@MainActor
private final class OfflineSpeechCapture: ObservableObject {
    enum State { case idle, preparing, recording, finishing }
    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var seconds = 0
    @Published private(set) var message: String?
    var isBusy: Bool { state != .idle }

    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioBridge: AudioRequestBridge?
    private var tapInstalled = false
    private var sessionActive = false
    private var sessionID = UUID()
    private var recordingTimer: Task<Void, Never>?
    private var finishTimer: Task<Void, Never>?

    /// Invoked only from the user's Start button. Never automatically resumes.
    func start(localeIdentifier: String) async {
        guard state == .idle else { return }
        cancel(clearText: true)
        let id = UUID()
        sessionID = id
        state = .preparing
        message = nil
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let candidate = SFSpeechRecognizer(locale: requestedLocale),
              candidate.locale.language.languageCode?.identifier == requestedLocale.language.languageCode?.identifier,
              candidate.locale.region?.identifier == requestedLocale.region?.identifier,
              candidate.supportsOnDeviceRecognition else {
            finishWithMessage("此设备或语言尚不能离线转写，请手动输入；不会改用云端识别。")
            return
        }
        let speechAllowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
        guard sessionID == id, !Task.isCancelled else { return }
        guard speechAllowed else {
            finishWithMessage("未获得语音识别权限。可在系统设置中开启，也可以直接手动输入。")
            return
        }
        let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
        guard sessionID == id, !Task.isCancelled else { return }
        guard microphoneAllowed else {
            finishWithMessage("未获得麦克风权限。可在系统设置中开启，也可以直接手动输入。")
            return
        }
        guard candidate.supportsOnDeviceRecognition, candidate.isAvailable else {
            finishWithMessage("当前离线转写不可用，请手动输入；不会连接云端识别。")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
            sessionActive = true
            let newEngine = AVAudioEngine()
            engine = newEngine
            let input = newEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                finishWithMessage("没有可用的麦克风输入，请检查设备后重试。")
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true // NEVER false; no cloud fallback.
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            let bridge = AudioRequestBridge(request)
            audioBridge = bridge
            recognizer = candidate
            recognitionTask = candidate.recognitionTask(with: request) { [weak self] result, error in
                // Copy only Sendable values before crossing onto the main actor.
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let errorText = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    if let text { self.transcript = text }
                    if isFinal || errorText != nil {
                        self.finishWithMessage(errorText == nil ? "转写完成，请核对文字。" : "离线转写已停止，已识别文字仍可编辑。若没有文字，请手动输入。")
                    }
                }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in bridge.append(buffer) }
            tapInstalled = true
            newEngine.prepare()
            try newEngine.start()
            state = .recording
            recordingTimer = Task { @MainActor [weak self] in
                for elapsed in 1...55 {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.sessionID == id, self.state == .recording else { return }
                    self.seconds = elapsed
                }
                guard let self, self.sessionID == id else { return }
                self.stop()
                self.message = "已达到本次 55 秒上限，录音停止。请核对文字；可保存后再录下一段。"
            }
        } catch {
            finishWithMessage("无法开始离线录音，请检查麦克风后重试，或手动输入。")
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .finishing
        stopMicrophone()
        recognitionTask?.finish()
        let id = sessionID
        finishTimer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.sessionID == id, self.state == .finishing else { return }
            self.finishWithMessage("录音已停止，保留当前识别文字。请核对末尾内容，可手动补充。")
        }
    }

    func interrupt() {
        guard isBusy else { return }
        finishWithMessage("录音已因切后台或音频中断而停止。已识别文字保留，请核对后继续；不会自动恢复录音。")
    }

    func cancel(clearText: Bool = false) {
        sessionID = UUID() // Invalidates permission continuations and late recognition callbacks.
        stopMicrophone()
        finishTimer?.cancel(); finishTimer = nil
        recognitionTask?.cancel(); recognitionTask = nil
        recognizer = nil
        state = .idle
        if clearText { transcript = ""; seconds = 0 }
    }

    private func finishWithMessage(_ text: String) {
        cancel()
        message = text
    }

    private func stopMicrophone() {
        recordingTimer?.cancel(); recordingTimer = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        audioBridge?.end(); audioBridge = nil
        engine = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
}

// MARK: - Preview first, persist only after explicit confirmation

@MainActor
struct QuickCaptureView: View {
    let onConfirm: ([QuickCaptureDraft]) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speech = OfflineSpeechCapture()
    @State private var inputText = ""
    @State private var originalInput = ""
    @State private var drafts: [QuickCaptureDraft] = []
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showFiles = false
    @State private var isRecognizing = false
    @State private var importTask: Task<Void, Never>?
    @State private var speechStartTask: Task<Void, Never>?
    @State private var importID = UUID()
    @State private var errorMessage: String?
    @State private var localeIdentifier = "zh-CN"
    @State private var recordingBase = ""
    @State private var recordingOriginalBase = ""
    @State private var showOriginal = false
    @State private var isSubmitting = false
    @State private var saveFailed = false
    @State private var isVisible = true

    private var busy: Bool { isRecognizing || speech.isBusy }
    private var selectedCount: Int { drafts.filter(\.isSelected).count }
    private var canConfirm: Bool {
        !busy && !isSubmitting && selectedCount > 0 && !drafts.contains {
            $0.isSelected && ($0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.dateNeedsReview)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("图片识字、语音转文字和规则整理均在本机完成。确认后只保存文字，不保存原图或录音。原文中的“提醒我”“每天”等不会自动开启通知或重复，请保存后进入待办的日期设置核对开启。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if drafts.isEmpty {
                    inputSection
                    captureSection
                } else {
                    Section {
                        Text("已整理 \(drafts.count) 条候选，选中 \(selectedCount) 条。请核对类型、文字和日期，再保存。")
                        Text("这是本地规则草稿，可能识别错误。复杂、重复或模糊日期需要手动确认。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("返回修改输入") { drafts = [] }
                    }
                    ForEach($drafts) { $draft in
                        QuickCaptureDraftEditor(draft: $draft)
                    }
                    Section {
                        DisclosureGroup("完整原始输入", isExpanded: $showOriginal) {
                            Text(originalInput.isEmpty ? inputText : originalInput)
                                .font(.body).textSelection(.enabled)
                        }
                    }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("快速新建")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancelAll(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if drafts.isEmpty {
                        Button("预览") { makeDrafts() }
                            .disabled(busy || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("保存 \(selectedCount) 条") {
                            guard canConfirm else { return }
                            isSubmitting = true
                            let saved = onConfirm(drafts.filter(\.isSelected))
                            // Lock after success until the parent dismisses. Failure keeps editable drafts.
                            if !saved { isSubmitting = false; saveFailed = true }
                        }
                        .disabled(!canConfirm)
                    }
                }
            }
            .alert("保存未完成", isPresented: $saveFailed) {
                Button("继续编辑", role: .cancel) { }
            } message: {
                Text("当前草稿仍在此页，请重试。退出前可复制完整原始输入，以免丢失这次尚未保存的文字。")
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { beginFileImport(url) }
                case .failure(let error):
                    errorMessage = "未导入图片：\(error.localizedDescription)"
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                beginPhotoImport(item)
            }
            .onChange(of: speech.transcript) { _, text in
                // Only update text, never persist a record from partial/final results.
                inputText = joined(recordingBase, text)
                originalInput = joined(recordingOriginalBase, text)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    speechStartTask?.cancel()
                    speech.interrupt()
                    cancelImport()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   AVAudioSession.InterruptionType(rawValue: raw) == .began { speech.interrupt() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                // Starting/deactivating our own session also changes the route. Only external
                // device loss/configuration changes should stop an active recording.
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                      [.oldDeviceUnavailable, .noSuitableRouteForCategory, .routeConfigurationChange].contains(reason) else { return }
                speech.interrupt()
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
                speech.interrupt()
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false; cancelAll() }
        }
    }

    private var inputSection: some View {
        Section {
            TextEditor(text: $inputText)
                .frame(minHeight: 180)
                .disabled(speech.isBusy)
                .accessibilityLabel("识别文字或手动输入")
            Text("可直接输入。多条内容请换行，预览时可逐条选择。全部文字保留，长标题会缩短显示，正文不截断。")
                .font(.footnote).foregroundStyle(.secondary)
        } header: { Text("文字") }
    }

    private var captureSection: some View {
        Group {
            Section {
                PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current) {
                    Label("从照片选一张图片", systemImage: "photo")
                }
                .disabled(busy)
                Button { showFiles = true } label: { Label("从文件选一张图片", systemImage: "doc") }
                    .disabled(busy)
                if isRecognizing {
                    HStack { ProgressView(); Text("正在本机识别文字…"); Spacer(); Button("取消识别") { cancelImport() } }
                }
                Text("只读取你选中的单张图片，无需全相册权限。离线时请选择已下载到此设备的图片；系统照片或文件选择器可能需要先下载云端原图。图片会缩放后识别，细小文字请核对。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("图片识字") }
            Section {
                Picker("转写语言", selection: $localeIdentifier) {
                    Text("普通话").tag("zh-CN")
                    Text("English (US)").tag("en-US")
                }.disabled(busy)
                switch speech.state {
                case .idle:
                    Button {
                        errorMessage = nil
                        recordingBase = inputText
                        recordingOriginalBase = originalInput.isEmpty ? inputText : originalInput
                        speechStartTask = Task { await speech.start(localeIdentifier: localeIdentifier) }
                    } label: { Label("开始离线录音", systemImage: "mic") }
                    .disabled(isRecognizing)
                case .preparing:
                    HStack { ProgressView(); Text("检查权限和离线能力…") }
                    Button("取消本次录音", role: .cancel) { cancelRecording() }
                case .recording:
                    Label("正在录音 \(speech.seconds) / 55 秒", systemImage: "record.circle.fill")
                        .foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently)
                    Button("停止录音并保留文字") { speech.stop() }
                    Button("取消本次录音", role: .cancel) { cancelRecording() }
                case .finishing:
                    HStack { ProgressView(); Text("已停止录音，正在整理末尾文字…") }
                    Button("取消本次录音", role: .cancel) { cancelRecording() }
                }
                if let message = speech.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Text("点击开始时才申请麦克风与语音权限。只在支持此语言本机识别的设备上工作；不可用时请手动输入。单次最多 55 秒，不保存原始音频。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("语音转文字") }
        }
    }

    private func makeDrafts() {
        guard !busy else { return }
        if originalInput.isEmpty { originalInput = inputText }
        drafts = QuickCaptureParser.parse(inputText).map { parsed in
            var draft = parsed
            draft.sourceText = originalInput
            return draft
        }
        errorMessage = drafts.isEmpty ? "没有可创建的文字，请先输入内容。" : nil
    }

    private func beginPhotoImport(_ item: PhotosPickerItem) {
        guard isVisible, !speech.isBusy else { return }
        cancelImport()
        let id = UUID(); importID = id
        isRecognizing = true; errorMessage = nil
        importTask = Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw QuickCaptureError.unreadableImage }
                try Task.checkCancellation()
                let text = try await LocalImageOCR.recognize(data)
                guard importID == id, !Task.isCancelled else { return }
                appendRecognized(text)
                isRecognizing = false; selectedPhoto = nil; importTask = nil
            } catch {
                guard importID == id, !Task.isCancelled else { return }
                isRecognizing = false; selectedPhoto = nil; importTask = nil
                errorMessage = "\(error.localizedDescription) 若图片仅存于 iCloud，请先在照片中下载到本机，或换一张本地图片。"
            }
        }
    }

    private func beginFileImport(_ url: URL) {
        guard isVisible, !speech.isBusy else { return }
        cancelImport()
        let id = UUID(); importID = id
        isRecognizing = true; errorMessage = nil
        importTask = Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 30 * 1024 * 1024 else { throw QuickCaptureError.imageTooLarge }
                    return try Data(contentsOf: url)
                }.value
                try Task.checkCancellation()
                let text = try await LocalImageOCR.recognize(data)
                guard importID == id, !Task.isCancelled else { return }
                appendRecognized(text)
                isRecognizing = false; importTask = nil
            } catch {
                guard importID == id, !Task.isCancelled else { return }
                isRecognizing = false; importTask = nil
                errorMessage = "\(error.localizedDescription) 请确认图片已下载到此设备。"
            }
        }
    }

    private func appendRecognized(_ text: String) {
        let unedited = originalInput.isEmpty ? inputText : originalInput
        inputText = joined(inputText, text)
        originalInput = joined(unedited, text)
    }

    private func joined(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + "\n" + second
    }

    private func cancelImport() {
        importID = UUID()
        importTask?.cancel(); importTask = nil
        isRecognizing = false
        selectedPhoto = nil
    }

    private func cancelRecording() {
        speechStartTask?.cancel(); speechStartTask = nil
        speech.cancel(clearText: true)
        inputText = recordingBase
        originalInput = recordingOriginalBase
    }

    private func cancelAll() {
        cancelImport()
        speechStartTask?.cancel(); speechStartTask = nil
        speech.cancel()
    }
}

@MainActor
private struct QuickCaptureDraftEditor: View {
    @Binding var draft: QuickCaptureDraft
    private var dateBinding: Binding<Date> {
        Binding(get: { draft.dueDate ?? Calendar.current.startOfDay(for: Date()) }, set: { draft.dueDate = $0 })
    }
    private var includeDate: Binding<Bool> {
        Binding(get: { draft.dueDate != nil }, set: { enabled in
            draft.dueDate = enabled ? Calendar.current.startOfDay(for: Date()) : nil
            if !enabled { draft.hasTime = false }
        })
    }
    private var reviewed: Binding<Bool> {
        Binding(get: { !draft.dateNeedsReview }, set: { draft.dateNeedsReview = !$0 })
    }

    var body: some View {
        Section {
            Toggle("创建这一条", isOn: $draft.isSelected)
            Picker("类型", selection: $draft.kind) {
                ForEach(QuickCaptureKind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
            }
            TextField("标题（必填）", text: $draft.title, axis: .vertical)
            TextField("正文", text: $draft.body, axis: .vertical).lineLimit(3...12)
            Toggle("包含日期", isOn: includeDate)
            if draft.dueDate != nil {
                DatePicker("日期", selection: dateBinding, displayedComponents: [.date])
                Toggle("包含具体时间", isOn: $draft.hasTime)
                if draft.hasTime { DatePicker("时间", selection: dateBinding, displayedComponents: [.hourAndMinute]) }
                Text("这是条目中的日期时间，不会创建提醒通知。时区：\(TimeZone.current.identifier)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note = draft.dateReviewNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
                Toggle("日期已核对（或确认不设日期）", isOn: reviewed)
            }
        } header: {
            Text(draft.kind == .task ? "待办草稿" : "备忘草稿")
        }
    }
}
#endif
