import AppKit
import AVFoundation
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let reportPath = SelfTest.reportPath {
            Task { await SelfTest.run(reportPath: reportPath) }
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Reel")
        let menu = NSMenu()
        menu.addItem(withTitle: "Demander les autorisations", action: #selector(requestPermissions), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter Reel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action == #selector(requestPermissions) { $0.target = self } }
        item.menu = menu
        statusItem = item
        requestPermissions()
    }

    @objc private func requestPermissions() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }
}
