import AppKit
import Speech
import AVFoundation
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
  static weak var shared: AppDelegate?
  var statusBar: StatusBarController!
  private var voiceManager: VoiceManager!
  private let replyFile = "/tmp/voice_reply.txt"
  private let logFile = "/tmp/ocb_debug.log"
  private var sessionId: String?
  var hudWindowController: HUDWindowController?
  private var speakingTimer: Timer?
  var currentAskProcess: Process?
  var currentPlayProcess: Process?
  private var ttsQueue: [String] = []
  private var ttsQueueIndex: Int = 0
  private var preFetchedAudioData: Data? = nil
  private var preFetchedIndex: Int = -1

  func log(_ m: String) {
    if let h = FileHandle(forWritingAtPath: logFile) {
      h.seekToEndOfFile()
      h.write((m + "\n").data(using: .utf8)!)
      h.closeFile()
    }
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    AppDelegate.shared = self
    voiceManager = VoiceManager()
    hudWindowController = HUDWindowController()
    
    try? "".write(toFile: replyFile, atomically: true, encoding: .utf8)
    try? "".write(toFile: logFile, atomically: true, encoding: .utf8)
    log("[App] Launch")
    
    ensurePythonScripts()
    setupMainMenu()
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self = self else { return }
      let apiClient = APIClient()
      self.statusBar = StatusBarController(apiClient: apiClient)
    }
    
    try? registerHotkey()
  }

  func applicationWillTerminate(_ aNotification: Notification) {
    log("[App] Terminating. Resuming all system media to prevent frozen states.")
    
    // Synchronously thaw all processes immediately
    let nativeApps = [
        "抖音.app", "TikTok.app", 
        "NeteaseMusic.app", "QQMusic.app", 
        "TencentVideo.app", "腾讯视频.app", 
        "Youku.app", "优酷.app", 
        "iQIYI.app", "爱奇艺.app"
    ]
    for app in nativeApps {
        let contTask = Process()
        contTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        contTask.arguments = ["-CONT", "-f", app]
        try? contTask.run()
    }
    
    // Execute AppleScript to resume other paused media
    let resumeScript = """
    try
        tell application "System Events" to set isMusicRunning to (exists process "Music")
        if isMusicRunning then
            run script "tell application \\"Music\\" to play"
        end if
    end try
    
    try
        tell application "System Events" to set isSpotifyRunning to (exists process "Spotify")
        if isSpotifyRunning then
            run script "tell application \\"Spotify\\" to play"
        end if
    end try
    
    try
        tell application "System Events" to set isSafariRunning to (exists process "Safari")
        if isSafariRunning then
            run script "tell application \\"Safari\\"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            tell t to do JavaScript \\"
                                document.querySelectorAll('video, audio').forEach(el => {
                                    if (el.dataset.wasPlaying === 'true') {
                                        el.play();
                                        delete el.dataset.wasPlaying;
                                    }
                                });
                              \\"
                        catch
                        end try
                    end repeat
                end repeat
            end tell"
        end if
    end try
    
    try
        tell application "System Events" to set isChromeRunning to (exists process "Google Chrome")
        if isChromeRunning then
            run script "tell application \\"Google Chrome\\"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            tell t to execute javascript \\"
                                document.querySelectorAll('video, audio').forEach(el => {
                                    if (el.dataset.wasPlaying === 'true') {
                                        el.play();
                                        delete el.dataset.wasPlaying;
                                    }
                                });
                            \\"
                        catch
                        end try
                    end repeat
                end repeat
            end tell"
        end if
    end try
    """
    
    if let script = NSAppleScript(source: resumeScript) {
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
    }
  }

  private func setupMainMenu() {
    let mainMenu = NSMenu()
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    
    editMenuItem.submenu = editMenu
    NSApplication.shared.mainMenu = mainMenu
  }

  private func registerHotkey() throws {
    var r: EventHotKeyRef?
    try ck(RegisterEventHotKey(49, 0x0800, EventHotKeyID(signature: 0x4F434258, id: 1), GetApplicationEventTarget(), 0, &r))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, _ in
        DispatchQueue.main.async { AppDelegate.shared?.toggleVoiceInput() }
        return noErr
      },
      1,
      [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))],
      nil,
      nil
    )
  }

  private func ck(_ e: OSStatus) throws {
    if e != noErr {
      throw NSError(domain: "hk", code: Int(e))
    }
  }

  func cancelActiveVoiceOperations() {
    if let existingAsk = currentAskProcess, existingAsk.isRunning {
      existingAsk.terminate()
      log("[Voice] Terminated active Codex query")
      currentAskProcess = nil
    }
    if let existingPlay = currentPlayProcess, existingPlay.isRunning {
      existingPlay.terminate()
      log("[Voice] Terminated active afplay playback")
      currentPlayProcess = nil
    }
    speakingTimer?.invalidate()
    speakingTimer = nil
    
    // Clear queues
    ttsQueue.removeAll()
    ttsQueueIndex = 0
    preFetchedAudioData = nil
    preFetchedIndex = -1
  }

  @objc func toggleVoiceInput() {
    // Protect active query/operation phase from accidental false wake-word or hotkey interrupts
    if currentAskProcess != nil {
      log("[Toggle] Ignored hotkey because an active query or desktop operation is currently running")
      return
    }

    cancelActiveVoiceOperations()

    if voiceManager.isListening {
      voiceManager.stopListening()
      statusBar.setStatus(.idle)
      hudWindowController?.hideHUD()
      resumeSystemMedia()
      return
    }

    statusBar.setStatus(.listening)
    hudWindowController?.showHUD()
    hudWindowController?.updateState(state: "listening", amplitude: 0.0, text: "正在倾听...")
    pauseSystemMedia()

    voiceManager.amplitudeUpdateHandler = { [weak self] amp in
      self?.hudWindowController?.updateState(state: "listening", amplitude: amp, text: "正在倾听...")
    }

    voiceManager.startListening { [weak self] text in
      guard let s = self else { return }
      s.log("[STT] '\(text ?? "nil")'")
      guard let t = text else {
        s.statusBar.setStatus(.idle)
        s.hudWindowController?.hideHUD()
        s.resumeSystemMedia()
        return
      }
      s.processVoice(t)
    }
  }

  @objc func startNewConversation() {
    cancelActiveVoiceOperations()
    self.sessionId = nil
    log("[Session] Reset: Session ID cleared successfully")
    
    // Notify the user visually on the HUD card!
    hudWindowController?.updateState(state: "idle", amplitude: 0.0, text: "💬 已成功开启新会话")
    
    // Play a pleasant Glass chime to notify user
    if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true) {
      sound.play()
    }
  }

  func processVoice(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let puncs = ["。", "！", "？", ".", "!", "?", "，", ","]
    var cleanCmd = trimmed
    for p in puncs {
      cleanCmd = cleanCmd.replacingOccurrences(of: p, with: "")
    }
    let lowerCmd = cleanCmd.lowercased().trimmingCharacters(in: .whitespaces)
    
    if lowerCmd == "开启新对话" || lowerCmd == "清空会话" || lowerCmd == "开启新会话" || lowerCmd == "新建会话" || lowerCmd == "清除记忆" || lowerCmd == "重新开始" || lowerCmd == "开启一个新的会话" {
      startNewConversation()
      return
    }

    log("[Go] \(text.prefix(30))")
    statusBar.setStatus(.sending)
    hudWindowController?.updateState(state: "thinking", amplitude: 0.0, text: "思考中...")
    try? text.write(toFile: "/tmp/voice_cmd.txt", atomically: true, encoding: .utf8)

    let routedPrompt = """
[User Request]
\(text)

[System Guidelines]
1. Conversational Queries: If the request is a simple greeting, casual conversation, or informational question, answer directly in natural text.
2. Coding/Terminal Queries: If the request is a pure coding, file-compilation, or command-line developer task, you may use the standard developer shell/terminal/file tools.
3. System/App/GUI Operations: For ANY other operational task (e.g. opening/managing desktop applications, visiting websites, clicking, typing, scrolling, searching the web, interactive screen tasks), you MUST execute it immediately using the macOS "computer_use" GUI automation tools. You are strictly forbidden from using any high-level "browser" or "chrome" webbridge plugins. You MUST operate the actual screen via computer_use tools (e.g. opening Google Chrome using the mouse/keyboard, typing the URL on the screen, clicking actual coordinates, etc.). Do not write bash/apple-scripts or explain your plan. Act directly on the screen.
4. Response Format for Voice TTS: Always start your response with a single, highly coherent, conversational spoken summary paragraph (strictly between 50 and 120 characters) optimized for direct TTS.
- The first paragraph MUST be a high-level natural summary of your findings or results.
- CRITICAL: You are strictly forbidden from listing raw items, trends, names, files, or specific lists in this first paragraph. For example, do NOT say "页面刷新成功，热门趋势有：第一是A，第二是B..." or read them out. Instead, say: "我已经为您刷新了页面并查看了热门趋势。今天的热点主要集中在科技与民生话题上，具体列表我已经为您整理在屏幕上了。"
- You MUST leave a blank line (\n\n) right after this summary paragraph, and then place any raw tables, logs, list items, code blocks, or technical breakdowns below that blank line.
"""

    ask(routedPrompt) { [weak self] reply in
      guard let s = self else { return }
      guard !reply.isEmpty else {
        s.log("[Empty]")
        DispatchQueue.main.async {
          s.statusBar.setStatus(.idle)
          s.hudWindowController?.hideHUD()
          s.resumeSystemMedia()
        }
        return
      }
      
      let c = s.clean(reply)
      s.log("[TTS] \(c.prefix(40))")
      try? c.write(toFile: s.replyFile, atomically: true, encoding: .utf8)

      // Play a pleasant macOS system Glass chime to notify user that processing is complete and the AI is about to speak
      if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true) {
        sound.play()
      }

      s.tts(c)
      DispatchQueue.main.async {
        s.statusBar.setStatus(.idle)
      }
    }
  }

  private func ask(_ prompt: String, cb: @escaping (String) -> Void) {
    log("[Ask] \(prompt.prefix(60))")
    DispatchQueue.global().async { [weak self] in
      guard let self = self else { return }
      if let existing = self.currentAskProcess, existing.isRunning {
        existing.terminate()
        self.log("[Ask] Cancelled active query")
      }
      
      let task = Process()
      self.currentAskProcess = task
      task.executableURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")

      var env = ProcessInfo.processInfo.environment
      let customPath = "/opt/homebrew/bin:/usr/local/bin"
      if let currentPath = env["PATH"] {
        env["PATH"] = "\(customPath):\(currentPath)"
      } else {
        env["PATH"] = customPath
      }
      task.environment = env
      task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

      var args = ["--dangerously-bypass-approvals-and-sandbox", "exec"]
      let settings = VoiceSettings.load()
      if let model = settings.voice_llm_model, !model.isEmpty {
        args += ["--model", model]
      }
      if let sid = self.sessionId {
        args += ["resume", sid]
      }
      args += ["--skip-git-repo-check", "-"]
      task.arguments = args

      let outPipe = Pipe()
      let errPipe = Pipe()
      let inPipe = Pipe()
      task.standardOutput = outPipe
      task.standardError = errPipe
      task.standardInput = inPipe

      let sem = DispatchSemaphore(value: 0)
      task.terminationHandler = { _ in sem.signal() }

      var errData = Data()
      do {
        try task.run()
        inPipe.fileHandleForWriting.write((prompt + "\n").data(using: .utf8)!)
        try inPipe.fileHandleForWriting.close()

        DispatchQueue(label: "err").async {
          errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        sem.wait()
        self.currentAskProcess = nil

        var output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if self.sessionId == nil {
          let errStr = String(data: errData, encoding: .utf8) ?? ""
          if let r = errStr.range(of: "session id: ([\\w-]+)", options: .regularExpression) {
            self.sessionId = String(errStr[r])
              .replacingOccurrences(of: "session id: ", with: "")
              .trimmingCharacters(in: .whitespaces)
            self.log("[SID] \(self.sessionId!)")
          }
        }

        output = output.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        self.log("[Resp] \(output.prefix(80))")
        DispatchQueue.main.async { cb(output) }
      } catch {
        self.currentAskProcess = nil
        self.log("[Ask Err] \(error.localizedDescription)")
        DispatchQueue.main.async { cb("[错误]") }
      }
    }
  }

  private func isStructuredLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") || trimmed.hasPrefix("|") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix("$ ") || trimmed.hasPrefix("% ") {
      return true
    }
    if trimmed.hasPrefix("• ") || trimmed.hasPrefix("◦ ") || trimmed.hasPrefix("▪ ") {
      return true
    }
    if let regex = try? NSRegularExpression(pattern: "^[0-9]+[.\\)]\\s", options: []) {
      let range = NSRange(location: 0, length: trimmed.utf16.count)
      if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
        return true
      }
    }
    return false
  }

  private func cleanIntroductoryTail(_ text: String) -> String {
    var sentences = [String]()
    var current = ""
    
    for char in text {
      current.append(char)
      if char == "。" || char == "！" || char == "？" || char == "!" || char == "?" || char == "\n" {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          sentences.append(trimmed)
        }
        current = ""
      }
    }
    
    let trimmedLast = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedLast.isEmpty {
      sentences.append(trimmedLast)
    }
    
    if sentences.isEmpty {
      return ""
    }
    
    if let last = sentences.last {
      let lower = last.lowercased()
      let isIntro = lower.hasSuffix("：") || lower.hasSuffix(":") || 
                    lower.contains("如下") || lower.contains("以下") ||
                    lower.contains("如下所示") || lower.contains("请看")
      
      if isIntro {
        sentences.removeLast()
      }
    }
    
    return sentences.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func extractSpokenSummary(_ t: String) -> String {
    let lines = t.components(separatedBy: "\n")
    var collected = [String]()
    
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        continue
      }
      
      if isStructuredLine(trimmed) {
        break
      }
      
      collected.append(trimmed)
    }
    
    let joined = collected.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let result = cleanIntroductoryTail(joined)
    
    if !result.isEmpty {
      return result
    }
    
    return "我已经为您整理好了，请在屏幕上查看具体内容。"
  }

  private func tts(_ t: String) {
    cancelActiveVoiceOperations()
    
    let spokenText = extractSpokenSummary(t)
    let cleaned = clean(spokenText)
    var shortText = cleaned
    shortText = shortText.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if shortText.count > 800 {
      let limit = 780
      let substring = String(shortText.prefix(limit))
      let boundaries: [Character] = ["。", "！", "？", ".", "!", "?", "，", ","]
      if let lastBound = substring.lastIndex(where: { boundaries.contains($0) }) {
        let nextIndex = substring.index(after: lastBound)
        shortText = String(substring[..<nextIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        shortText = substring + "..."
      }
    }
    
    log("[TTS] Synthesizing spoken summary: '\(shortText.prefix(30))...'")
    
    synthesizeFullReply(shortText) { [weak self] audioData in
      guard let s = self else { return }
      s.playFullAudio(audioData, text: shortText)
    }
  }

  private func synthesizeFullReply(_ text: String, completion: @escaping (Data) -> Void) {
    guard let jsonData = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return }
    
    var request = URLRequest(url: URL(string: "http://localhost:8765/api/voice/tts")!)
    request.httpMethod = "POST"
    request.httpBody = jsonData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      if let error = error {
        self?.log("[TTS Err] Synthesis failed: \(error.localizedDescription)")
        return
      }
      guard let data = data, !data.isEmpty else {
        self?.log("[TTS Err] Empty audio data returned")
        return
      }
      completion(data)
    }
    task.resume()
  }

  private func playFullAudio(_ data: Data, text: String) {
    let mp3Url = "/tmp/ocb_tts.mp3"
    do {
      try data.write(to: URL(fileURLWithPath: mp3Url))
      
      // Update speaking status for VAD sync
      try? "sending".write(toFile: "/tmp/ocb_status.txt", atomically: true, encoding: .utf8)
      
      DispatchQueue.main.async { [weak self] in
        self?.startSpeakingAnimation(text: text)
      }
      
      DispatchQueue.global().async { [weak self] in
        guard let s = self else { return }
        if let existing = s.currentPlayProcess, existing.isRunning {
          existing.terminate()
        }
        
        let playTask = Process()
        s.currentPlayProcess = playTask
        playTask.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        playTask.arguments = [mp3Url]
        try? playTask.run()
        playTask.waitUntilExit()
        s.currentPlayProcess = nil
        
        s.log("[TTS] Finished playing full audio")
        try? "idle".write(toFile: "/tmp/ocb_status.txt", atomically: true, encoding: .utf8)
        
        DispatchQueue.main.async {
          s.stopSpeakingAnimation()
        }
      }
    } catch {
      self.log("[TTS Err] Failed to write/play audio: \(error.localizedDescription)")
      DispatchQueue.main.async { [weak self] in
        self?.stopSpeakingAnimation()
      }
    }
  }

  private func resolveEdgeTTSVoice(_ voice: String, text: String) -> String {
    if voice.contains("-") && voice.count > 5 {
      return voice
    }
    let hasChinese = text.range(of: "\\p{Han}", options: .regularExpression) != nil
    return hasChinese ? "zh-CN-XiaoxiaoNeural" : "en-US-AvaNeural"
  }

  private func resolveOpenAIVoice(_ voice: String) -> String {
    let validVoices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
    if validVoices.contains(voice.lowercased()) {
      return voice.lowercased()
    }
    return "alloy"
  }

  private func clean(_ t: String) -> String {
    var r = t
    r = r.replacingOccurrences(of: "[\\p{So}\\p{Sk}]", with: "", options: .regularExpression)
    r = r.replacingOccurrences(of: "**", with: "")
    r = r.replacingOccurrences(of: "*", with: "")
    return r.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func startSpeakingAnimation(text: String) {
    speakingTimer?.invalidate()
    var t: Float = 0.0
    speakingTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
      t += 0.3
      let base = sin(t) * 0.5 + 0.5
      let noise = Float.random(in: 0.2...0.8)
      let amp = base * noise * 0.8
      
      self?.hudWindowController?.updateState(state: "speaking", amplitude: amp, text: text)
    }
  }

  func stopSpeakingAnimation() {
    speakingTimer?.invalidate()
    speakingTimer = nil
    hudWindowController?.updateState(state: "idle", amplitude: 0.0, text: "已完成回复")
    resumeSystemMedia()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      if self?.voiceManager.isListening == false && self?.speakingTimer == nil {
        self?.hudWindowController?.hideHUD()
      }
    }
  }

  private func ensurePythonScripts() {
    let minimax = """
import sys
import os
import json
import urllib.request
import binascii

def main():
    if len(sys.argv) < 3:
        print("ERROR: Missing text or output path")
        sys.exit(1)
        
    text = sys.argv[1]
    output_path = sys.argv[2]
    voice_id = sys.argv[3] if len(sys.argv) > 3 else "presenter_male"
    
    api_key = os.environ.get("MINIMAX_API_KEY")
    api_host = os.environ.get("MINIMAX_API_HOST", "https://api.minimaxi.com")
    
    if not api_key:
        print("ERROR: Missing MINIMAX_API_KEY environment variable")
        sys.exit(1)
        
    url = f"{api_host}/v1/t2a_v2"
    
    payload = {
        "model": "speech-01-turbo",
        "text": text,
        "stream": False,
        "voice_setting": {
            "voice_id": voice_id,
            "speed": 1.0,
            "vol": 1.0,
            "pitch": 0
        },
        "audio_setting": {
            "sample_rate": 32000,
            "bitrate": 128000,
            "format": "mp3"
        },
        "output_format": "hex"
    }
    
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }
    
    try:
        req = urllib.request.Request(
            url, 
            data=json.dumps(payload).encode("utf-8"), 
            headers=headers, 
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=15) as response:
            res_data = response.read().decode("utf-8")
            res_json = json.loads(res_data)
            
            if "base_resp" in res_json and res_json["base_resp"].get("status_code") != 0:
                msg = res_json["base_resp"].get("status_msg", "Unknown error")
                print(f"ERROR: MiniMax API Error: {msg}")
                sys.exit(1)
                
            audio_hex = res_json.get("data")
            if not audio_hex:
                print("ERROR: No audio data returned from MiniMax")
                sys.exit(1)
                
            audio_bytes = binascii.unhexlify(audio_hex)
            
            with open(output_path, "wb") as f:
                f.write(audio_bytes)
                
            print("SUCCESS")
    except Exception as e:
        print(f"ERROR: {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    main()
"""

    let openai = """
import sys
import os
import json
import urllib.request

def main():
    if len(sys.argv) < 3:
        print("ERROR: Missing text or output path")
        sys.exit(1)
        
    text = sys.argv[1]
    output_path = sys.argv[2]
    
    api_key = sys.argv[3] if len(sys.argv) > 3 else ""
    base_url = sys.argv[4] if len(sys.argv) > 4 else "https://api.openai.com/v1"
    model = sys.argv[5] if len(sys.argv) > 5 else "tts-1"
    voice = sys.argv[6] if len(sys.argv) > 6 else "alloy"
    
    if not api_key:
        print("ERROR: Missing API Key for custom TTS")
        sys.exit(1)
        
    url = f"{base_url.rstrip('/')}/audio/speech"
    
    payload = {
        "model": model,
        "input": text,
        "voice": voice
    }
    
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }
    
    try:
        req = urllib.request.Request(
            url, 
            data=json.dumps(payload).encode("utf-8"), 
            headers=headers, 
            method="POST"
        )
        
        with urllib.request.urlopen(req, timeout=15) as response:
            audio_bytes = response.read()
            with open(output_path, "wb") as f:
                f.write(audio_bytes)
            print("SUCCESS")
    except Exception as e:
        print(f"ERROR: {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    main()
"""

    try? minimax.write(toFile: "/tmp/ocb_minimax_tts.py", atomically: true, encoding: .utf8)
    try? openai.write(toFile: "/tmp/ocb_openai_tts.py", atomically: true, encoding: .utf8)
    log("[App] Written helper python scripts to /tmp")
  }

  private var pausedMediaApps: String = ""
  private var mediaFailsafeWorkItem: DispatchWorkItem?
  private var mediaMonitoringTimer: Timer?

  private func getAudioPlayingPIDs() -> Set<Int> {
    var pids = Set<Int>()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-g", "assertions"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8) {
      let lines = output.components(separatedBy: .newlines)
      for line in lines {
        if line.contains("Created for PID:") {
          let parts = line.components(separatedBy: "Created for PID:")
          if parts.count > 1 {
            let pidStr = parts[1].trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            if let pid = Int(pidStr) {
              pids.insert(pid)
            }
          }
        }
      }
    }
    return pids
  }

  private func getPIDsForProcessName(name: String) -> [Int] {
    var pids: [Int] = []
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", name]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8) {
      let lines = output.components(separatedBy: .newlines)
      for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = Int(trimmed) {
          pids.append(pid)
        }
      }
    }
    return pids
  }

  private func monitorAndSuspendPlayingMedia() {
    let playingPids = self.getAudioPlayingPIDs()
    if playingPids.isEmpty { return }
    
    let nativeApps = [
        "抖音.app": "抖音", "TikTok.app": "TikTok", 
        "NeteaseMusic.app": "NeteaseMusic", "QQMusic.app": "QQMusic", 
        "TencentVideo.app": "TencentVideo", "腾讯视频.app": "腾讯视频", 
        "Youku.app": "Youku", "优酷.app": "优酷", 
        "iQIYI.app": "iQIYI", "爱奇艺.app": "爱奇艺"
    ]
    
    for (appFile, appName) in nativeApps {
        let pids = self.getPIDsForProcessName(name: appName)
        for pid in pids {
            if playingPids.contains(pid) {
                self.log("[Media Monitor] Suspending playing app \(appName) (PID: \(pid))")
                let stopTask = Process()
                stopTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                stopTask.arguments = ["-STOP", "-f", appFile]
                try? stopTask.run()
                
                if !self.pausedMediaApps.contains(appFile) {
                    self.pausedMediaApps += "\(appFile),"
                }
            }
        }
    }
  }

  private func pauseSystemMedia() {
    // Cancel any existing failsafe timer first
    self.mediaFailsafeWorkItem?.cancel()
    
    // Schedule a new failsafe timer to automatically thaw all apps after 35 seconds
    let workItem = DispatchWorkItem { [weak self] in
      self?.log("[Media Failsafe] Triggered 35-second safety resume.")
      self?.resumeSystemMedia()
    }
    self.mediaFailsafeWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 35.0, execute: workItem)

    // Start repeating 0.5s media monitoring timer on the main thread to dynamically capture & suspend audio-producing processes
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.mediaMonitoringTimer?.invalidate()
      self.mediaMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        self?.monitorAndSuspendPlayingMedia()
      }
      // Run immediately once to pause currently playing apps at recording start
      self.monitorAndSuspendPlayingMedia()
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      
      let pauseScript = """
      var pausedApps = ""
      
      try
          tell application "System Events" to set isMusicRunning to (exists process "Music")
          if isMusicRunning then
              set isPlaying to false
              try
                  set isPlaying to (run script "tell application \\"Music\\" to return (player state is playing)")
              end try
              if isPlaying then
                  run script "tell application \\"Music\\" to pause"
                  set pausedApps to pausedApps & "Music,"
              end if
          end if
      end try
      
      try
          tell application "System Events" to set isSpotifyRunning to (exists process "Spotify")
          if isSpotifyRunning then
              set isPlaying to false
              try
                  set isPlaying to (run script "tell application \\"Spotify\\" to return (player state is playing)")
              end try
              if isPlaying then
                  run script "tell application \\"Spotify\\" to pause"
                  set pausedApps to pausedApps & "Spotify,"
              end if
          end if
      end try
      
      try
          tell application "System Events" to set isSafariRunning to (exists process "Safari")
          if isSafariRunning then
              run script "tell application \\"Safari\\"
                  repeat with w in windows
                      repeat with t in tabs of w
                          try
                              tell t to do JavaScript \\"
                                  let pausedAny = false;
                                  document.querySelectorAll('video, audio').forEach(el => {
                                      if (!el.paused) {
                                          el.pause();
                                          el.dataset.wasPlaying = 'true';
                                          pausedAny = true;
                                      }
                                  });
                                  pausedAny;
                              \\"
                          catch
                          end try
                      end repeat
                  end repeat
              end tell"
              set pausedApps to pausedApps & "Safari,"
          end if
      end try
      
      try
          tell application "System Events" to set isChromeRunning to (exists process "Google Chrome")
          if isChromeRunning then
              run script "tell application \\"Google Chrome\\"
                  repeat with w in windows
                      repeat with t in tabs of w
                          try
                              tell t to execute javascript \\"
                                  let pausedAny = false;
                                  document.querySelectorAll('video, audio').forEach(el => {
                                      if (!el.paused) {
                                          el.pause();
                                          el.dataset.wasPlaying = 'true';
                                          pausedAny = true;
                                      }
                                  });
                                  pausedAny;
                              \\"
                          catch
                          end try
                      end repeat
                  end repeat
              end tell"
              set pausedApps to pausedApps & "Chrome,"
          end if
      end try
      
      return pausedApps
      """
      
      if let script = NSAppleScript(source: pauseScript) {
          var error: NSDictionary?
          let result = script.executeAndReturnError(&error)
          if error == nil, let val = result.stringValue {
              let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
              if !trimmed.isEmpty {
                  self.pausedMediaApps = trimmed
                  self.log("[Media] Paused active playback in: \(trimmed)")
              }
          } else if let err = error {
              self.log("[Media Err] Pause script failed: \(err)")
          }
      }
    }
  }

  private func resumeSystemMedia() {
    // Cancel the failsafe timer on clean resume
    self.mediaFailsafeWorkItem?.cancel()
    self.mediaFailsafeWorkItem = nil

    // Invalidate and clear the monitoring timer on main thread
    DispatchQueue.main.async { [weak self] in
      self?.mediaMonitoringTimer?.invalidate()
      self?.mediaMonitoringTimer = nil
    }

    let appsToResume = self.pausedMediaApps
    self.pausedMediaApps = ""
    
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      
      // Resume native media apps instantly via SIGCONT
      let nativeApps = [
          "抖音.app", "TikTok.app", 
          "NeteaseMusic.app", "QQMusic.app", 
          "TencentVideo.app", "腾讯视频.app", 
          "Youku.app", "优酷.app", 
          "iQIYI.app", "爱奇艺.app"
      ]
      for app in nativeApps {
          let contTask = Process()
          contTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
          contTask.arguments = ["-CONT", "-f", app]
          try? contTask.run()
      }
      
      if appsToResume.isEmpty { return }
      
      let resumeScript = """
      set pausedApps to "\(appsToResume)"
      
      try
          tell application "System Events" to set isMusicRunning to (exists process "Music")
          if pausedApps contains "Music" and isMusicRunning then
              run script "tell application \\"Music\\" to play"
          end if
      end try
      
      try
          tell application "System Events" to set isSpotifyRunning to (exists process "Spotify")
          if pausedApps contains "Spotify" and isSpotifyRunning then
              run script "tell application \\"Spotify\\" to play"
          end if
      end try
      
      try
          tell application "System Events" to set isSafariRunning to (exists process "Safari")
          if pausedApps contains "Safari" and isSafariRunning then
              run script "tell application \\"Safari\\"
                  repeat with w in windows
                      repeat with t in tabs of w
                          try
                              tell t to do JavaScript \\"
                                  document.querySelectorAll('video, audio').forEach(el => {
                                      if (el.dataset.wasPlaying === 'true') {
                                          el.play();
                                          delete el.dataset.wasPlaying;
                                      }
                                  });
                                \\"
                          catch
                          end try
                      end repeat
                  end repeat
              end tell"
          end if
      end try
      
      try
          tell application "System Events" to set isChromeRunning to (exists process "Google Chrome")
          if pausedApps contains "Chrome" and isChromeRunning then
              run script "tell application \\"Google Chrome\\"
                  repeat with w in windows
                      repeat with t in tabs of w
                          try
                              tell t to execute javascript \\"
                                  document.querySelectorAll('video, audio').forEach(el => {
                                      if (el.dataset.wasPlaying === 'true') {
                                          el.play();
                                          delete el.dataset.wasPlaying;
                                      }
                                  });
                              \\"
                          catch
                          end try
                      end repeat
                  end repeat
              end tell"
          end if
      end try
      """
      
      if let script = NSAppleScript(source: resumeScript) {
          var error: NSDictionary?
          _ = script.executeAndReturnError(&error)
          if error == nil {
              self.log("[Media] Resumed playback successfully")
          } else if let err = error {
              self.log("[Media Err] Resume script failed: \(err)")
          }
      }
    }
  }
}
