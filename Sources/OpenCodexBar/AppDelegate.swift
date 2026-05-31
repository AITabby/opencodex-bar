import AppKit
import Speech
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusBar: StatusBarController!
  private var voiceManager: VoiceManager!
  private var apiClient: APIClient!
  private var statusTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    apiClient = APIClient()
    voiceManager = VoiceManager()
    statusBar = StatusBarController(apiClient: apiClient)

    // Poll OpenCodex status every 5 seconds
    statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      self?.apiClient.fetchStatus()
    }
    apiClient.fetchStatus()

    // Global hotkey: Option+Space to start voice input
    registerHotkey()
  }

  private func registerHotkey() {
    // Monitor key events
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      // Option+Space = keyCode 49 with modifier .option
      if event.keyCode == 49 && event.modifierFlags.contains(.option) {
        self?.toggleVoiceInput()
      }
    }
  }

  @objc func toggleVoiceInput() {
    if voiceManager.isListening {
      voiceManager.stopListening()
    } else {
      statusBar.setStatus(.listening)
      voiceManager.startListening { [weak self] text in
        guard let self = self, let text = text else {
          self?.statusBar.setStatus(.idle)
          return
        }
        self.statusBar.setStatus(.sending)
        self.apiClient.sendVoice(text) { success in
          DispatchQueue.main.async {
            self.statusBar.setStatus(.idle)
          }
        }
      }
    }
  }
}
