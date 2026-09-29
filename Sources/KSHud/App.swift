import AppKit
import SwiftUI

/// Borderless, always-on-top panel that floats over every Space, including full-screen apps.
final class OverlayPanel: NSPanel {
    /// `content` receives a callback to report the view's natural size; the panel resizes to it, keeping its top edge fixed.
    init(content: (_ onResize: @escaping (CGSize) -> Void) -> some View) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        let hud = content { [weak self] size in
            DispatchQueue.main.async { self?.fit(to: size) }
        }
        // GeometryReader places its content at the top-left and lets it overflow downward. The HUD is briefly
        // taller than the window while growing (and shorter while shrinking); a plain frame would centre it,
        // so the card would jump up and appear to grow from the bottom.
        let host = FirstClickHostingView(rootView: GeometryReader { _ in hud })
        // The panel sizes itself (see fit(to:)); AppKit's own content-driven resizing anchors the bottom edge instead.
        host.sizingOptions = []
        contentView = host

        // Only the top-left corner is remembered: the height changes with the content and grows downward from it.
        // The size is filled in by fit(to:) once SwiftUI reports it.
        setFrameTopLeftPoint(Self.savedTopLeft() ?? Self.defaultTopLeft())
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            guard let self, self.frame.height > 0 else { return }
            UserDefaults.standard.set([self.frame.minX, self.frame.maxY], forKey: Self.topLeftKey)
        }
    }

    private static let topLeftKey = "overlayTopLeft"

    private static func savedTopLeft() -> NSPoint? {
        let defaults = UserDefaults.standard
        var point: NSPoint?
        if let xy = defaults.array(forKey: topLeftKey) as? [Double], xy.count == 2 {
            point = NSPoint(x: xy[0], y: xy[1])
        } else if let legacy = defaults.string(forKey: "NSWindow Frame KSHudOverlay")?
            .split(separator: " ").compactMap({ Double($0) }), legacy.count >= 4 {
            point = NSPoint(x: legacy[0], y: legacy[1] + legacy[3])  // earlier versions saved "x y width height …"
        }
        // Ignore a position on a display that is no longer connected.
        guard let point, NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: point.x + 20, y: point.y - 20)) })
        else { return nil }
        return point
    }

    private static func defaultTopLeft() -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: screen.maxX - 260 - 20, y: screen.maxY - 20)
    }

    private var pendingShrink: DispatchWorkItem?

    /// Growing happens at once so SwiftUI can animate the content into the new space; shrinking waits for
    /// that animation to finish so the content isn't clipped mid-animation. The window is transparent, so
    /// the extra space in between is invisible.
    private func fit(to size: CGSize) {
        let size = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard size.width > 0, size.height > 0 else { return }
        pendingShrink?.cancel()
        guard size != frame.size else { return }
        if frame.height > 0, size.height < frame.height {
            let shrink = DispatchWorkItem { [weak self] in self?.resize(to: size) }
            pendingShrink = shrink
            DispatchQueue.main.asyncAfter(deadline: .now() + HudAnimation.duration + 0.05, execute: shrink)
        } else {
            resize(to: size)
        }
    }

    private func resize(to size: CGSize) {
        var f = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        // Growing downward must not push the bottom off screen.
        if let visible = (screen ?? NSScreen.main)?.visibleFrame, f.minY < visible.minY {
            f.origin.y = visible.minY
        }
        setFrame(f, display: true)
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
        panel = OverlayPanel { [model, backdrop] onResize in
            OverlayView(model: model, backdrop: backdrop, onResize: onResize)
        }
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
