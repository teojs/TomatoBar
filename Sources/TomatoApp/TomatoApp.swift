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
    private var cachedMenuBarKey: String?
    private var symbolCache: [String: NSImage] = [:]

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
            .map { [weak self] _ in self?.manager.showTimeInMenuBar ?? true }
            .removeDuplicates()
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
            if popover.contentViewController == nil {
                popover.contentViewController = PopoverHostingController(
                    rootView: PopoverContentView(manager: manager)
                )
            }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            sender.highlight(true)
        }
    }

    func popoverWillClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    func popoverDidClose(_ notification: Notification) {
        // 收起后卸掉 SwiftUI 面板，倒计时刷新不再驱动 Liquid Glass
        popover.contentViewController = nil
    }

    private func updateStatusButtonImage() {
        guard let button = statusItem?.button else { return }
        let iconName = manager.menuBarIconName
        let timeText = manager.showTimeInMenuBar ? manager.formattedTime : nil
        let key = "\(iconName)|\(timeText ?? "-")"
        if key != cachedMenuBarKey {
            cachedMenuBarKey = key
            button.image = renderMenuBarImage(iconName: iconName, timeText: timeText)
        }
        if popover.isShown {
            button.highlight(true)
        }
    }

    private func renderMenuBarImage(iconName: String, timeText: String?) -> NSImage {
        let symbolImage = symbol(named: iconName)
        let iconWidth: CGFloat = 18
        let height: CGFloat = 22

        guard let timeText else {
            let size = NSSize(width: iconWidth, height: height)
            return makeTemplateImage(size: size) { rect in
                guard let symbolImage else { return }
                let symSize = symbolImage.size
                symbolImage.draw(in: NSRect(
                    x: (rect.width - symSize.width) / 2,
                    y: (rect.height - symSize.height) / 2,
                    width: symSize.width,
                    height: symSize.height
                ))
            }
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
        let size = NSSize(width: ceil(iconWidth + spacing + textTotalWidth + 2), height: height)

        return makeTemplateImage(size: size) { rect in
            if let symbolImage {
                let symSize = symbolImage.size
                symbolImage.draw(in: NSRect(
                    x: (iconWidth - symSize.width) / 2,
                    y: (rect.height - symSize.height) / 2,
                    width: symSize.width,
                    height: symSize.height
                ))
            }
            var currentX = iconWidth + spacing
            for char in timeText {
                let str = String(char) as NSString
                let slotWidth = (char == ":") ? colonWidth : digitWidth
                let charSize = str.size(withAttributes: attributes)
                str.draw(at: NSPoint(
                    x: currentX + (slotWidth - charSize.width) / 2,
                    y: (rect.height - charSize.height) / 2 - 0.5
                ), withAttributes: attributes)
                currentX += slotWidth
            }
        }
    }

    private func symbol(named name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        if let image {
            symbolCache[name] = image
        }
        return image
    }

    /// 画进位图后再交给状态栏。带绘制回调的 NSImage 会在菜单栏每次重绘时重跑，倒计时会因此一直占 CPU。
    private func makeTemplateImage(size: NSSize, draw: (NSRect) -> Void) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelsWide = max(1, Int((size.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((size.height * scale).rounded(.up)))
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return image
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            draw(NSRect(origin: .zero, size: size))
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
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
