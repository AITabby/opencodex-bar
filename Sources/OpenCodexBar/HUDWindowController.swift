import AppKit
import WebKit

class HUDWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

class HUDWindowController: NSWindowController, WKNavigationDelegate {
  var webView: WKWebView!

  convenience init() {
    let width: CGFloat = 420
    let height: CGFloat = 92

    let screen = NSScreen.main ?? NSScreen.screens.first
    let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let x = visibleFrame.origin.x + (visibleFrame.width - width) / 2
    let y = visibleFrame.origin.y + 24

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
    window.level = .floating
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
    webView.load(URLRequest(url: url))
  }

  func showHUD() {
    guard let window = self.window else { return }

    let finalFrame = window.frame
    var startFrame = finalFrame
    startFrame.origin.y -= 25

    window.setFrame(startFrame, display: true)
    window.alphaValue = 0.0
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

  func hideHUD() {
    guard let window = self.window, window.isVisible else { return }

    let currentFrame = window.frame
    var targetFrame = currentFrame
    targetFrame.origin.y -= 25

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.3
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      window.animator().alphaValue = 0.0
      window.animator().setFrame(targetFrame, display: true)
    }) {
      window.orderOut(nil)
      window.setFrame(currentFrame, display: false)
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
