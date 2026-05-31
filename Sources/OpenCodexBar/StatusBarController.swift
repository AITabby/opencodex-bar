import AppKit

enum AppStatus {
  case idle     // ● green
  case loading  // ◐ spinning
  case listening // 🎙️ animating
  case sending  // ⟳ pulsing
  case error    // ⚠️ red
  case offline  // ○ gray
}

class StatusBarController {
  private let statusItem: NSStatusItem
  private let popover: NSPopover
  private let apiClient: APIClient
  private var currentStatus: AppStatus = .offline
  private var animationTimer: Timer?
  private var frameIndex = 0

  init(apiClient: APIClient) {
    self.apiClient = apiClient
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    popover = NSPopover()

    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "OpenCodex")
      button.action = #selector(togglePopover)
      button.target = self
    }

    updateIcon()
    buildMenu()
  }

  func setStatus(_ status: AppStatus) {
    currentStatus = status
    updateIcon()

    if status == .loading || status == .listening || status == .sending {
      startAnimation()
    } else {
      stopAnimation()
    }
  }

  private func updateIcon() {
    guard let button = statusItem.button else { return }
    let symbol: String
    let color: NSColor

    switch currentStatus {
    case .idle:
      symbol = "circle.fill"; color = .systemGreen
    case .loading, .sending:
      symbol = "arrow.triangle.2.circlepath"; color = .systemBlue
    case .listening:
      symbol = "mic.fill"; color = .systemRed
    case .error:
      symbol = "exclamationmark.triangle.fill"; color = .systemYellow
    case .offline:
      symbol = "circle.dashed"; color = .systemGray
    }

    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
      img.withSymbolConfiguration(config)
      button.image = img
      button.contentTintColor = color
    }
  }

  private func startAnimation() {
    animationTimer?.invalidate()
    animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.frameIndex += 1
      // Pulse the alpha for visual feedback
      let alpha: CGFloat = (self?.frameIndex ?? 0) % 2 == 0 ? 0.4 : 1.0
      self?.statusItem.button?.alphaValue = alpha
    }
  }

  private func stopAnimation() {
    animationTimer?.invalidate()
    animationTimer = nil
    statusItem.button?.alphaValue = 1.0
    frameIndex = 0
  }

  private func buildMenu() {
    let menu = NSMenu()

    let statusItem_ = NSMenuItem(title: "OpenCodex", action: nil, keyEquivalent: "")
    statusItem_.isEnabled = false
    menu.addItem(statusItem_)

    menu.addItem(NSMenuItem.separator())

    menu.addItem(NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d"))
    menu.addItem(NSMenuItem(title: "Toggle Voice (⌥Space)", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Restart Codex", action: #selector(restartCodex), keyEquivalent: "r"))
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

    statusItem.menu = menu
  }

  @objc private func openDashboard() {
    NSWorkspace.shared.open(URL(string: "http://localhost:8765/dashboard")!)
  }

  @objc private func restartCodex() {
    apiClient.restartCodex()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  @objc private func togglePopover() {
    // Menu mode: click shows menu automatically
  }
}
