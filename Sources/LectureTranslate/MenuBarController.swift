import AppKit
import Combine
import LectureCore
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MenuBarController: NSObject {
    let model: DemoModel
    let panel: FloatingPanel
    let statusItem: NSStatusItem
    private(set) var settingsWindow: NSWindow?
    private let preferences: UserDefaults
    private var observations: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var positioned = false
    private static let positionKey = "Voxtant.FloatingWidget.Frame"

    init(model: DemoModel, preferences: UserDefaults = .standard) {
        self.model = model
        self.preferences = preferences
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        panel.contentMinSize = NSSize(width: 300, height: 300)
        panel.contentMaxSize = NSSize(width: 1600, height: 1800)
        panel.title = "Voxtant"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.setAccessibilityLabel("Voxtant — плавающий переводчик")

        let content = NSHostingView(rootView: WidgetView(model: model, openSettings: { [weak self] in self?.showSettings() }))
        content.sizingOptions = []
        content.frame = panel.contentRect(forFrameRect: panel.frame)
        content.autoresizingMask = [.width, .height]
        panel.contentView = glassContainer(content)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voxtant")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Voxtant — показать или скрыть переводчик")
        }
        updateStatusItem()
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &subscriptions)
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
            object: panel, queue: .main) { [weak self] _ in Task { @MainActor in self?.savePosition() } })
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
            object: panel, queue: .main) { [weak self] _ in Task { @MainActor in self?.keepOnScreen(); self?.savePosition() } })
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.keepOnScreen() } })
    }

    deinit { observations.forEach(NotificationCenter.default.removeObserver) }

    func showWidget() {
        if !positioned {
            if let saved = preferences.string(forKey: Self.positionKey) {
                let restored = NSRectFromString(saved)
                if [restored.minX, restored.minY, restored.width, restored.height].allSatisfy({ $0.isFinite }), restored.width > 0, restored.height > 0 {
                    let size = NSSize(width: min(max(restored.width, panel.minSize.width), panel.maxSize.width),
                                      height: min(max(restored.height, panel.minSize.height), panel.maxSize.height))
                    panel.setFrame(NSRect(origin: restored.origin, size: size), display: false)
                } else { placeBelowStatusItem() }
            } else { placeBelowStatusItem() }
            positioned = true
        }
        keepOnScreen()
        panel.orderFrontRegardless()
    }

    @objc func hideWidget() { panel.orderOut(nil) }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Настройки Voxtant"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.setContentSize(NSSize(width: 480, height: 640))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func savedFrame() -> NSRect? {
        preferences.string(forKey: Self.positionKey).map(NSRectFromString)
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, event.type == .rightMouseUp else { toggleVisibility(); return }
        let menu = NSMenu()
        let visibility = NSMenuItem(title: panel.isVisible ? "Скрыть виджет" : "Показать виджет",
                                   action: #selector(toggleVisibility), keyEquivalent: "")
        visibility.target = self
        menu.addItem(visibility)
        let settings = NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Завершить Voxtant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: sender)
    }

    @objc private func toggleVisibility() {
        if panel.isVisible { hideWidget() } else { showWidget() }
    }

    private func updateStatusItem() {
        statusItem.button?.toolTip = model.isRecording ? "Voxtant — слушаю" : "Voxtant — показать переводчик"
        statusItem.button?.contentTintColor = model.isRecording ? .systemRed : nil
    }

    private func placeBelowStatusItem() {
        if let window = statusItem.button?.window {
            let anchor = window.frame
            panel.setFrameOrigin(NSPoint(x: anchor.maxX - panel.frame.width,
                                          y: anchor.minY - panel.frame.height - 12))
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24,
                                          y: screen.visibleFrame.maxY - panel.frame.height - 24))
        }
    }

    private func keepOnScreen() {
        let frame = PanelPlacement.clamped(panel.frame, to: NSScreen.screens.map(\.visibleFrame))
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func savePosition() {
        guard positioned else { return }
        preferences.set(NSStringFromRect(panel.frame), forKey: Self.positionKey)
    }

    private func glassContainer(_ content: NSView) -> NSView {
        let container: NSView
        if #available(macOS 26.0, *) {
            container = content
        } else {
            let material = NSVisualEffectView(frame: content.frame)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.addSubview(content)
            material.wantsLayer = true
            material.layer?.cornerRadius = 26
            material.layer?.masksToBounds = true
            container = material
        }
        return container
    }
}

struct PanelDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

struct PanelResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResizeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class ResizeView: NSView {
        private var initialFrame = NSRect.zero
        private var initialPoint = NSPoint.zero
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
            for offset in [CGFloat(5), 10] {
                let path = NSBezierPath(); path.move(to: NSPoint(x: bounds.maxX - offset, y: 3))
                path.line(to: NSPoint(x: bounds.maxX - 3, y: offset)); path.lineWidth = 1; path.stroke()
            }
        }
        override func mouseDown(with event: NSEvent) { initialFrame = window?.frame ?? .zero; initialPoint = NSEvent.mouseLocation }
        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let point = NSEvent.mouseLocation
            let size = NSSize(width: min(max(initialFrame.width + point.x - initialPoint.x, window.minSize.width), window.maxSize.width),
                              height: min(max(initialFrame.height - point.y + initialPoint.y, window.minSize.height), window.maxSize.height))
            window.setFrame(NSRect(x: initialFrame.minX, y: initialFrame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
        override func viewDidMoveToWindow() { toolTip = "Потяните, чтобы изменить размер"; setAccessibilityLabel("Изменить размер виджета") }
    }
}
