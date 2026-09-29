import AppKit
import ScreenCaptureKit

/// Samples the screen behind the HUD about once a second and picks the HUD tone that contrasts with it:
/// dark over bright content, light over dark content. Needs Screen Recording permission; without it the HUD stays dark
/// and nothing touches ScreenCaptureKit, so macOS isn't asked again and again.
final class Backdrop: ObservableObject {
    @Published private(set) var hudIsLight = false
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "adaptiveContrast")
            enabled ? start() : stop()
        }
    }

    private weak var window: NSWindow?
    private var timer: Timer?
    private var content: SCShareableContent?
    private var sampling = false
    private var retryAfter = Date.distantPast

    init() {
        enabled = UserDefaults.standard.object(forKey: "adaptiveContrast") as? Bool ?? true
    }

    func attach(_ window: NSWindow) {
        self.window = window
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            self?.sample()
        }
        if enabled { start() }
    }

    private func start() {
        guard window != nil, timer == nil else { return }
        // Prompts at most once per launch; sample() stays idle until access is granted.
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        sample()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        hudIsLight = false
    }

    private func sample() {
        guard enabled, !sampling, Date() >= retryAfter, CGPreflightScreenCaptureAccess(), let window, window.isVisible, let screen = window.screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return }
        // ScreenCaptureKit wants display-local points with a top-left origin.
        let f = window.frame
        let rect = CGRect(x: f.minX - screen.frame.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height)
        let pid = ProcessInfo.processInfo.processIdentifier
        sampling = true

        Task { @MainActor in
            defer { self.sampling = false }
            do {
                if self.content?.displays.contains(where: { $0.displayID == displayID }) != true {
                    self.content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                guard let content = self.content,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                // Leave the HUD itself out of the capture, or it would react to its own colour.
                let mine = content.windows.filter { $0.owningApplication?.processID == pid }
                guard !mine.isEmpty else { self.content = nil; return }

                let config = SCStreamConfiguration()
                config.sourceRect = rect
                config.width = 16
                config.height = 16
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: mine), configuration: config)
                self.update(luminance: Self.averageLuminance(image))
            } catch {
                // Back off instead of failing every second.
                self.content = nil
                self.retryAfter = Date().addingTimeInterval(10)
            }
        }
    }

    private func update(luminance: Double) {
        // Hysteresis so mid-grey backdrops don't make the HUD flicker between tones.
        if hudIsLight, luminance > 0.5 {
            hudIsLight = false
        } else if !hudIsLight, luminance < 0.35 {
            hudIsLight = true
        }
    }

    /// Mean perceived brightness (0–1) of the sRGB pixels.
    private static func averageLuminance(_ image: CGImage) -> Double {
        let w = 16, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return total / Double(w * h) / 255
    }
}
