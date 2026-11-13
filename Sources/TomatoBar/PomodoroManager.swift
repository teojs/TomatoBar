import Foundation
import SwiftUI
import AppKit
import UserNotifications

enum PomodoroPhase: String, CaseIterable {
    case focus
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .focus:
            return "专注中"
        case .shortBreak:
            return "短休息"
        case .longBreak:
            return "长休息"
        }
    }

    var subtitle: String {
        switch self {
        case .focus:
            return "保持专注，心无旁骛"
        case .shortBreak:
            return "放松双眼，喝口水吧"
        case .longBreak:
            return "深度休息，恢复精力"
        }
    }

    var defaultDuration: Int {
        switch self {
        case .focus:
            return 25 * 60
        case .shortBreak:
            return 5 * 60
        case .longBreak:
            return 15 * 60
        }
    }

    var themeColor: Color {
        switch self {
        case .focus:
            return Color(red: 0.95, green: 0.33, blue: 0.28) // 番茄红
        case .shortBreak:
            return Color(red: 0.20, green: 0.78, blue: 0.45) // 清新绿
        case .longBreak:
            return Color(red: 0.25, green: 0.56, blue: 0.96) // 宁静蓝
        }
    }

    var iconName: String {
        switch self {
        case .focus:
            return "flame.fill"
        case .shortBreak:
            return "cup.and.saucer.fill"
        case .longBreak:
            return "leaf.fill"
        }
    }
}

@MainActor
final class PomodoroManager: NSObject, ObservableObject {
    // MARK: - Published States
    @Published private(set) var phase: PomodoroPhase = .focus
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var remainingSeconds: Int = PomodoroPhase.focus.defaultDuration
    @Published private(set) var totalSeconds: Int = PomodoroPhase.focus.defaultDuration

    /// 当前这一轮（4个番茄为一轮）已完成的番茄数 (0...3)
    @Published private(set) var completedInCycle: Int = 0
    let targetCycleCount: Int = 4

    /// 圆环一圈对应的最长时长
    static let dialMaxSeconds = 60 * 60

    // MARK: - Preferences (Persisted)
    @AppStorage("showTimeInMenuBar") var showTimeInMenuBar: Bool = true
    @AppStorage("soundEnabled") var soundEnabled: Bool = true
    @AppStorage("autoStartNextPhase") var autoStartNextPhase: Bool = false
    @AppStorage("focusMinutes") var focusMinutes: Int = 25
    @AppStorage("shortBreakMinutes") var shortBreakMinutes: Int = 5
    @AppStorage("longBreakMinutes") var longBreakMinutes: Int = 15

    // MARK: - Daily Stats (Persisted)
    @AppStorage("todayDateString") private var todayDateString: String = ""
    @AppStorage("todayCompletedCount") private(set) var todayCompletedCount: Int = 0
    @AppStorage("todayFocusedMinutes") private(set) var todayFocusedMinutes: Int = 0

    // MARK: - Internal Timer State
    private var timer: Timer?
    private var endDate: Date?
    private var isAdjustingDuration = false

    nonisolated private static let startNextActionID = "tomato.startNext"

    override init() {
        super.init()
        let initial = duration(for: .focus)
        remainingSeconds = initial
        totalSeconds = initial
        checkAndResetDailyStatsIfNeeded()
        configureNotifications()
    }

    func minutes(for phase: PomodoroPhase) -> Int {
        switch phase {
        case .focus:
            return focusMinutes
        case .shortBreak:
            return shortBreakMinutes
        case .longBreak:
            return longBreakMinutes
        }
    }

    func duration(for phase: PomodoroPhase) -> Int {
        minutes(for: phase) * 60
    }

    /// 专注：5…60，步长 5。休息：1…10 步长 1，之后到 30 步长 5。
    static func durationOptions(for phase: PomodoroPhase) -> [Int] {
        switch phase {
        case .focus:
            return Array(stride(from: 5, through: 60, by: 5))
        case .shortBreak, .longBreak:
            return Array(1...10) + Array(stride(from: 15, through: 30, by: 5))
        }
    }

    func setDefaultMinutes(_ minutes: Int, for phase: PomodoroPhase) {
        let options = Self.durationOptions(for: phase)
        let clamped = options.min(by: { abs($0 - minutes) < abs($1 - minutes) }) ?? minutes
        switch phase {
        case .focus:
            focusMinutes = clamped
        case .shortBreak:
            shortBreakMinutes = clamped
        case .longBreak:
            longBreakMinutes = clamped
        }
        registerNotificationCategories()
        if self.phase == phase, !isRunning {
            let seconds = clamped * 60
            totalSeconds = seconds
            remainingSeconds = seconds
        }
    }

    // MARK: - Computed Properties
    var formattedTime: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var menuBarIconName: String {
        switch phase {
        case .focus:
            return isRunning ? "flame.fill" : "flame"
        case .shortBreak:
            return isRunning ? "cup.and.saucer.fill" : "cup.and.saucer"
        case .longBreak:
            return isRunning ? "leaf.fill" : "leaf"
        }
    }

    // MARK: - Actions
    func toggleStartPause() {
        if isRunning {
            pause()
        } else {
            start()
        }
    }

    func start() {
        checkAndResetDailyStatsIfNeeded()
        guard !isRunning else { return }
        isRunning = true
        endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))

        scheduleTick()
    }

    /// 对齐到下一秒的边界只唤醒一次，避免 0.25 秒轮询。
    private func scheduleTick() {
        timer?.invalidate()
        guard isRunning, let endDate else {
            timer = nil
            return
        }
        let remaining = endDate.timeIntervalSinceNow
        if remaining <= 0 {
            timer = nil
            tick()
            return
        }
        let fraction = remaining - floor(remaining)
        let delay = fraction < 0.05 ? fraction + 1 : fraction
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        next.tolerance = 0.05
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    func pause() {
        guard isRunning else { return }
        if let endDate {
            remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        }
        isRunning = false
        endDate = nil
        timer?.invalidate()
        timer = nil
    }

    /// 只把当前阶段的倒计时拨回默认时长，不改今日专注数。
    /// 已经凑满一轮时，把本轮进度清掉，避免之后的专注又被当成第 4 个番茄。
    func reset() {
        pause()
        if completedInCycle >= targetCycleCount {
            completedInCycle = 0
        }
        remainingSeconds = duration(for: phase)
        totalSeconds = duration(for: phase)
    }

    /// 菜单里的重置：倒计时、本轮进度点和今日专注数一起归零。
    func resetCounting() {
        reset()
        objectWillChange.send()
        completedInCycle = 0
        todayCompletedCount = 0
        todayFocusedMinutes = 0
    }

    func skipToNextPhase() {
        pause()
        advancePhase(recordFocusCompletion: false)
    }

    func switchPhase(to newPhase: PomodoroPhase) {
        pause()
        if phase == .longBreak, newPhase != .longBreak {
            completedInCycle = 0
        }
        phase = newPhase
        totalSeconds = duration(for: newPhase)
        remainingSeconds = duration(for: newPhase)
    }

    func beginDurationAdjustment() {
        isAdjustingDuration = true
    }

    /// 拖动圆环时设置剩余时长。进行中会改写结束时间，倒计时从新时长继续。
    func adjustRemaining(to seconds: Int) {
        let snapped = min(max((seconds / 60) * 60, 60), Self.dialMaxSeconds)
        if snapped != remainingSeconds {
            remainingSeconds = snapped
            if snapped > totalSeconds {
                totalSeconds = snapped
            }
        }
        if isRunning {
            endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        }
    }

    func endDurationAdjustment() {
        isAdjustingDuration = false
        if isRunning {
            endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
            scheduleTick()
        }
    }

    // MARK: - Private Logic
    private func tick() {
        guard isRunning, !isAdjustingDuration, let endDate else { return }
        let remaining = Int(ceil(endDate.timeIntervalSinceNow))
        if remaining <= 0 {
            remainingSeconds = 0
            handlePhaseCompleted()
            return
        }
        if remaining != remainingSeconds {
            remainingSeconds = remaining
        }
        scheduleTick()
    }

    private func handlePhaseCompleted() {
        pause()
        playAlertSoundIfNeeded()
        sendNotification(for: phase)
        advancePhase(recordFocusCompletion: true)

        if autoStartNextPhase {
            start()
        }
    }

    private func advancePhase(recordFocusCompletion: Bool) {
        checkAndResetDailyStatsIfNeeded()

        switch phase {
        case .focus:
            if completedInCycle >= targetCycleCount {
                completedInCycle = 0
            }
            if recordFocusCompletion {
                todayCompletedCount += 1
                todayFocusedMinutes += (totalSeconds / 60)
            }
            completedInCycle += 1

            if completedInCycle >= targetCycleCount {
                phase = .longBreak
            } else {
                phase = .shortBreak
            }

        case .shortBreak:
            phase = .focus

        case .longBreak:
            completedInCycle = 0
            phase = .focus
        }

        totalSeconds = duration(for: phase)
        remainingSeconds = duration(for: phase)
    }

    private func checkAndResetDailyStatsIfNeeded() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let current = formatter.string(from: Date())
        if todayDateString != current {
            todayDateString = current
            todayCompletedCount = 0
            todayFocusedMinutes = 0
        }
    }

    private func playAlertSoundIfNeeded() {
        guard soundEnabled else { return }
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Notifications
    private func configureNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerNotificationCategories()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func registerNotificationCategories() {
        let categories = Set(PomodoroPhase.allCases.map { phase in
            let action = UNNotificationAction(
                identifier: Self.startNextActionID,
                title: startButtonTitle(for: phase),
                options: []
            )
            return UNNotificationCategory(
                identifier: categoryID(for: phase),
                actions: [action],
                intentIdentifiers: [],
                options: []
            )
        })
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    private func sendNotification(for completedPhase: PomodoroPhase) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let next = upcomingPhase(after: completedPhase)
        let content = UNMutableNotificationContent()
        switch completedPhase {
        case .focus:
            content.title = "专注完成！"
            content.body = next == .longBreak
                ? "太棒了！你已完成一轮专注，开始 \(minutes(for: .longBreak)) 分钟长休息吧。"
                : "辛苦了，站起来活动一下，开始 \(minutes(for: .shortBreak)) 分钟短休息吧。"
            if let attachment = symbolAttachment(systemName: "flame.fill", tint: NSColor(srgbRed: 0.95, green: 0.33, blue: 0.28, alpha: 1)) {
                content.attachments = [attachment]
            }
        case .shortBreak, .longBreak:
            content.title = "休息结束"
            content.body = "准备好开始下一个 \(minutes(for: .focus)) 分钟专注了吗？"
            if let attachment = symbolAttachment(systemName: "cup.and.saucer.fill", tint: NSColor(srgbRed: 0.98, green: 0.72, blue: 0.18, alpha: 1)) {
                content.attachments = [attachment]
            }
        }
        if !autoStartNextPhase {
            content.categoryIdentifier = categoryID(for: next)
        }
        if soundEnabled {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 通知发出时阶段还没切换，按当前轮次推算下一阶段。
    private func upcomingPhase(after completedPhase: PomodoroPhase) -> PomodoroPhase {
        switch completedPhase {
        case .focus:
            return completedInCycle + 1 >= targetCycleCount ? .longBreak : .shortBreak
        case .shortBreak, .longBreak:
            return .focus
        }
    }

    private func startButtonTitle(for phase: PomodoroPhase) -> String {
        let minutes = minutes(for: phase)
        switch phase {
        case .focus:
            return "开始\(minutes)分钟专注"
        case .shortBreak, .longBreak:
            return "开始\(minutes)分钟休息"
        }
    }

    private func categoryID(for phase: PomodoroPhase) -> String {
        "tomato.start.\(phase.rawValue)"
    }

    /// 通知标题不支持直接嵌入 SF Symbol，渲染成缩略图附在通知上。
    private func symbolAttachment(systemName: String, tint: NSColor) -> UNNotificationAttachment? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 56, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return nil
        }

        let canvas = NSSize(width: 72, height: 72)
        let image = NSImage(size: canvas, flipped: false) { rect in
            let symbolSize = symbol.size
            let drawRect = NSRect(
                x: (rect.width - symbolSize.width) / 2,
                y: (rect.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )
            symbol.draw(in: drawRect)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomato-notification-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return try UNNotificationAttachment(identifier: systemName, url: url)
        } catch {
            return nil
        }
    }
}

extension PomodoroManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.startNextActionID {
            Task { @MainActor in
                self.start()
            }
        }
        completionHandler()
    }
}
