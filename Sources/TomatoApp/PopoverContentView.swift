import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var manager: PomodoroManager

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            mainTimerView

            Divider()
                .opacity(0.4)

            footerBar
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(width: 260, height: 350)
        .animation(.smooth(duration: 0.25), value: manager.phase)
    }

    // MARK: - Top Header (Native Liquid Glass Tabs)
    private var headerBar: some View {
        Picker("阶段", selection: phaseBinding) {
            ForEach(PomodoroPhase.allCases, id: \.self) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.tabs)
        .controlSize(.large)
        .labelsHidden()
    }

    private var phaseBinding: Binding<PomodoroPhase> {
        Binding(
            get: { manager.phase },
            set: { newPhase in
                if manager.phase != newPhase {
                    manager.switchPhase(to: newPhase)
                }
            }
        )
    }

    // MARK: - Main Timer Area
    private var mainTimerView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 2)

            DurationDialView(manager: manager, dotColor: dotColor(for:))
                .frame(width: 176, height: 176)

            // Controls: Reset | Play/Pause | Skip (Native Liquid Glass Buttons)
            GlassEffectContainer(spacing: 18) {
                HStack(spacing: 18) {
                    Button {
                        manager.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("重置当前计时")

                    Button {
                        manager.toggleStartPause()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: manager.isRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text(manager.isRunning ? "暂停" : (manager.remainingSeconds < manager.totalSeconds ? "继续" : "开始"))
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(manager.phase.themeColor)
                    .controlSize(.large)

                    Button {
                        manager.skipToNextPhase()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("跳过当前阶段")
                }
            }

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bar
    private var footerBar: some View {
        HStack {
            HStack(spacing: 5) {
                Text("今日专注: 🍅 × \(manager.todayCompletedCount)")
                    .font(.system(size: 12, weight: .medium))
                if manager.todayFocusedMinutes > 0 {
                    Text("(\(manager.todayFocusedMinutes)m)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Toggle("状态栏显示倒计时", isOn: $manager.showTimeInMenuBar)
                Toggle("阶段结束提示音", isOn: $manager.soundEnabled)
                Toggle("自动开始下一阶段", isOn: $manager.autoStartNextPhase)

                Divider()

                Button("重置当前计时") {
                    manager.reset()
                }

                Divider()

                Button("退出 Tomato") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("设置与更多")
        }
    }

    private func dotColor(for index: Int) -> Color {
        if index < manager.completedInCycle {
            return manager.phase.themeColor
        } else if index == manager.completedInCycle && manager.phase == .focus && manager.isRunning {
            return manager.phase.themeColor.opacity(0.45)
        } else {
            return Color.primary.opacity(0.15)
        }
    }
}

/// 可拖动的时长圆环。一圈 60 分钟，从 12 点顺时针拖到对应刻度。
private struct DurationDialView: View {
    @ObservedObject var manager: PomodoroManager
    let dotColor: (Int) -> Color
    @State private var isDragging = false

    private var dialFraction: Double {
        Double(manager.remainingSeconds) / Double(PomodoroManager.dialMaxSeconds)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2 - 10
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 8)
                    .frame(width: radius * 2, height: radius * 2)

                Circle()
                    .trim(from: 0, to: dialFraction)
                    .stroke(
                        manager.phase.themeColor,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: radius * 2, height: radius * 2)

                Circle()
                    .fill(manager.phase.themeColor)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                    .shadow(color: manager.phase.themeColor.opacity(0.35), radius: 3, y: 1)
                    .offset(knobOffset(radius: radius))

                VStack(spacing: 8) {
                    CountdownDisplayView(formattedTime: manager.formattedTime)
                    HStack(spacing: 6) {
                        ForEach(0..<manager.targetCycleCount, id: \.self) { index in
                            Circle()
                                .fill(dotColor(index))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            manager.beginDurationAdjustment()
                        }
                        manager.adjustRemaining(to: seconds(at: value.location, in: geo.size))
                    }
                    .onEnded { _ in
                        isDragging = false
                        manager.endDurationAdjustment()
                    }
            )
        }
    }

    private func knobOffset(radius: CGFloat) -> CGSize {
        let theta = -Double.pi / 2 + dialFraction * 2 * Double.pi
        return CGSize(
            width: cos(theta) * radius,
            height: sin(theta) * radius
        )
    }

    /// 12 点为 0，顺时针增大。靠近 12 点的空档记为 60 分钟。
    private func seconds(at location: CGPoint, in size: CGSize) -> Int {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let minutes = Int((angle / (2 * .pi) * 60).rounded())
        let clamped = minutes == 0 ? 60 : min(max(minutes, 1), 60)
        return clamped * 60
    }
}

/// 固定每个数字字符单元宽度的倒计时组件，彻底消除倒计时跳秒时的水平微抖动
private struct CountdownDisplayView: View {
    let formattedTime: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(formattedTime.enumerated()), id: \.offset) { _, char in
                Text(String(char))
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(width: char == ":" ? 12 : 25, alignment: .center)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
