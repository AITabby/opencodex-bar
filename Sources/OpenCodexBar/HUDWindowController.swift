import AppKit
import WebKit

class HUDWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

class HUDWindowController: NSWindowController, WKNavigationDelegate {
  var webView: WKWebView!
  private var hudSessionId = 0

  convenience init() {
    let width: CGFloat = 360
    let height: CGFloat = 180

    let screen = NSScreen.main ?? NSScreen.screens.first
    let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let x = screenFrame.origin.x + (screenFrame.width - width) / 2
    let y = screenFrame.origin.y + screenFrame.height - height

    let contentRect = NSRect(x: x, y: y, width: width, height: height)

    let window = HUDWindow(
      contentRect: contentRect,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = false
    window.level = .statusBar
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

    self.init(window: window)
    setupWebView(width: width, height: height)
  }

  private func setupWebView(width: CGFloat, height: CGFloat) {
    let config = WKWebViewConfiguration()
    config.preferences.setValue(true, forKey: "developerExtrasEnabled")

    webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
    webView.navigationDelegate = self
    webView.setValue(false, forKey: "drawsBackground")
    if #available(macOS 12.0, *) {
      webView.underPageBackgroundColor = .clear
    }
    webView.wantsLayer = true
    webView.layer?.backgroundColor = NSColor.clear.cgColor
    webView.layer?.borderWidth = 0.0
    webView.layer?.borderColor = NSColor.clear.cgColor
    webView.layer?.shadowColor = NSColor.clear.cgColor

    func disableBackgroundDrawing(for view: NSView) {
      if let scrollView = view as? NSScrollView {
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
      }
      for subview in view.subviews {
        disableBackgroundDrawing(for: subview)
      }
    }
    disableBackgroundDrawing(for: webView)

    window?.contentView = webView
    loadVisualizer()
  }

  func loadVisualizer() {
    let t = Int(Date().timeIntervalSince1970)
    guard let url = URL(string: "http://localhost:8765/visualizer?mode=hud&t=\(t)") else { return }
    
    let dataStore = WKWebsiteDataStore.default()
    dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date(timeIntervalSince1970: 0)) { [weak self] in
      guard let self = self else { return }
      self.webView.load(URLRequest(url: url))
    }
  }

  func showHUD() {
    guard let window = self.window else { return }
    hudSessionId += 1

    let screen = NSScreen.main ?? NSScreen.screens.first
    let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let height = window.frame.height
    
    let finalFrame = NSRect(
      x: screenFrame.origin.x + (screenFrame.width - window.frame.width) / 2,
      y: screenFrame.origin.y + screenFrame.height - height,
      width: window.frame.width,
      height: height
    )
    
    if !window.isVisible || window.alphaValue == 0.0 {
      var startFrame = finalFrame
      startFrame.origin.y = screenFrame.origin.y + screenFrame.height
      window.setFrame(startFrame, display: true)
      window.alphaValue = 0.0
    }
    
    window.invalidateShadow()
    window.orderFrontRegardless()

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.35
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      window.animator().alphaValue = 1.0
      window.animator().setFrame(finalFrame, display: true)
    }) {
      window.invalidateShadow()
    }
  }

  func hideHUD(completion: (() -> Void)? = nil) {
    guard let window = self.window, window.isVisible else {
      completion?()
      return
    }
    hudSessionId += 1
    let currentSession = hudSessionId

    let screen = NSScreen.main ?? NSScreen.screens.first
    let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    
    let currentFrame = window.frame
    var targetFrame = currentFrame
    targetFrame.origin.y = screenFrame.origin.y + screenFrame.height

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.3
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      window.animator().alphaValue = 0.0
      window.animator().setFrame(targetFrame, display: true)
    }) { [weak self] in
      guard let self = self, self.hudSessionId == currentSession else { return }
      window.orderOut(nil)
      window.setFrame(currentFrame, display: false)
      completion?()
    }
  }

  func updateState(state: String, amplitude: Float, text: String = "") {
    let cleanText = text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
    let js = "if (window.updateVoiceState) { window.updateVoiceState('\(state)', \(amplitude), \"\(cleanText)\"); }"
    let strongSelf = self
    DispatchQueue.main.async {
      strongSelf.webView.evaluateJavaScript(js, completionHandler: nil as ((Any?, Error?) -> Void)?)
    }
  }
}
