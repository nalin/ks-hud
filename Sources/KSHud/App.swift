import AppKit
import SwiftUI

/// Borderless, always-on-top panel that floats over every Space, including full-screen apps.
final class OverlayPanel: NSPanel {
    init(rootView: some View) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        let host = FirstClickHostingView(rootView: rootView)
        contentView = host

        // Restore only the saved position; the size always comes from the current layout.
        let size = host.fittingSize
        setFrameAutosaveName("KSHudOverlay")
        let topLeft: NSPoint
        if setFrameUsingName("KSHudOverlay") {
            topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        } else {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            topLeft = NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - 20)
        }
        setContentSize(size)
        setFrameTopLeftPoint(topLeft)
    }
}

/// The panel never becomes key, so let the first click go straight to the HUD's buttons.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = HudModel()
    private let backdrop = Backdrop()
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var historyWindow: NSWindow?

    private let showItem = NSMenuItem(title: "Show Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
    private let clickThroughItem = NSMenuItem(title: "Click-Through", action: #selector(toggleClickThrough), keyEquivalent: "")
    private let metricItem = NSMenuItem(title: "Metric Units", action: #selector(toggleMetric), keyEquivalent: "")
    private let contrastItem = NSMenuItem(title: "Adaptive Contrast", action: #selector(toggleContrast), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = OverlayPanel(rootView: OverlayView(model: model, backdrop: backdrop))
        panel.orderFrontRegardless()
        backdrop.attach(panel)

        let menu = NSMenu()
        menu.delegate = self
        for item in [showItem, clickThroughItem, metricItem, contrastItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let history = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "y")
        history.target = self
        menu.addItem(history)
        let folder = NSMenuItem(title: "Open Sessions Folder", action: #selector(openSessions), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(NSMenuItem(title: "Quit KS HUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = .statusIcon
        statusItem.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.checkpoint()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showItem.state = panel.isVisible ? .on : .off
        clickThroughItem.state = panel.ignoresMouseEvents ? .on : .off
        metricItem.state = model.useMetric ? .on : .off
        contrastItem.state = backdrop.enabled ? .on : .off
    }

    @objc private func toggleOverlay() {
        panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    @objc private func toggleClickThrough() {
        panel.ignoresMouseEvents.toggle()
    }

    @objc private func toggleMetric() {
        model.useMetric.toggle()
    }

    @objc private func toggleContrast() {
        backdrop.enabled.toggle()
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Workout History"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(store: model.store, model: model))
            window.center()
            window.setFrameAutosaveName("KSHudHistory")
            historyWindow = window
        }
        // The app has no Dock icon, so bring it forward explicitly.
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSessions() {
        NSWorkspace.shared.open(model.store.directory)
    }
}
