import SwiftUI
import AppKit
import Combine

@main
struct TomatoApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let manager = PomodoroManager()
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupPopover()
        setupStatusItem()
        observeManagerChanges()
        setupOutsideClickMonitor()
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 260, height: 350)
        popover.contentViewController = PopoverHostingController(
            rootView: PopoverContentView(manager: manager)
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusButtonImage()
        }
    }

    private func observeManagerChanges() {
        Publishers.CombineLatest3(
            manager.$remainingSeconds,
            manager.$phase,
            manager.$isRunning
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.updateStatusButtonImage()
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButtonImage()
            }
            .store(in: &cancellables)
    }

    private func setupOutsideClickMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent

        // 右键点击或按住 Option 点击：快速开始/暂停
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            manager.toggleStartPause()
            return
        }

        // 左键点击：切换原生 NSPopover
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            sender.highlight(true)
        }
    }

    func popoverWillClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    private func updateStatusButtonImage() {
        guard let button = statusItem?.button else { return }
        button.image = renderMenuBarImage(
            iconName: manager.menuBarIconName,
            timeText: manager.showTimeInMenuBar ? manager.formattedTime : nil
        )
        if popover.isShown {
            button.highlight(true)
        }
    }

    private func renderMenuBarImage(iconName: String, timeText: String?) -> NSImage {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let symbolImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)

        let iconWidth: CGFloat = 18
        let height: CGFloat = 22

        guard let timeText else {
            let size = NSSize(width: iconWidth, height: height)
            let image = NSImage(size: size, flipped: false) { rect in
                if let symbolImage {
                    let symSize = symbolImage.size
                    let symRect = NSRect(
                        x: (rect.width - symSize.width) / 2,
                        y: (rect.height - symSize.height) / 2,
                        width: symSize.width,
                        height: symSize.height
                    )
                    symbolImage.draw(in: symRect)
                }
                return true
            }
            image.isTemplate = true
            return image
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]

        let spacing: CGFloat = 4
        let digitWidth: CGFloat = 8.2
        let colonWidth: CGFloat = 4.6
        let textTotalWidth: CGFloat = digitWidth * 4 + colonWidth
        let totalWidth: CGFloat = ceil(iconWidth + spacing + textTotalWidth + 2)

        let size = NSSize(width: totalWidth, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            if let symbolImage {
                let symSize = symbolImage.size
                let symRect = NSRect(
                    x: (iconWidth - symSize.width) / 2,
                    y: (rect.height - symSize.height) / 2,
                    width: symSize.width,
                    height: symSize.height
                )
                symbolImage.draw(in: symRect)
            }

            var currentX = iconWidth + spacing
            for char in timeText {
                let str = String(char) as NSString
                let slotWidth = (char == ":") ? colonWidth : digitWidth
                let charSize = str.size(withAttributes: attributes)
                let drawPoint = NSPoint(
                    x: currentX + (slotWidth - charSize.width) / 2,
                    y: (rect.height - charSize.height) / 2 - 0.5
                )
                str.draw(at: drawPoint, withAttributes: attributes)
                currentX += slotWidth
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// 使用 macOS 26 原生 Liquid Glass 弹窗材质 (.menu + clear tint)
final class PopoverHostingController<Content: View>: NSHostingController<Content> {
    override func viewWillAppear() {
        super.viewWillAppear()
        var root: NSView? = view
        while let parent = root?.superview {
            root = parent
        }
        if let effectView = root?.findSubview(ofType: NSVisualEffectView.self) {
            effectView.material = .menu
            effectView.enumerateSubviews(ofType: NSGlassEffectView.self) { glassView in
                glassView.tintColor = .clear
            }
        }
    }
}

private extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let matched = self as? T { return matched }
        for sub in subviews {
            if let found = sub.findSubview(ofType: type) { return found }
        }
        return nil
    }

    func enumerateSubviews<T: NSView>(ofType type: T.Type, body: (T) -> Void) {
        if let matched = self as? T { body(matched) }
        for sub in subviews {
            sub.enumerateSubviews(ofType: type, body: body)
        }
    }
}
