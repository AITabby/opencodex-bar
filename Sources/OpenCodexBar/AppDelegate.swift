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
      return
    }

    statusBar.setStatus(.listening)
    hudWindowController?.showHUD()
    hudWindowController?.updateState(state: "listening", amplitude: 0.0, text: "正在倾听...")

    voiceManager.amplitudeUpdateHandler = { [weak self] amp in
      self?.hudWindowController?.updateState(state: "listening", amplitude: amp, text: "正在倾听...")
    }

    voiceManager.startListening { [weak self] text in
      guard let s = self else { return }
      s.log("[STT] '\(text ?? "nil")'")
      guard let t = text else {
        s.statusBar.setStatus(.idle)
        s.hudWindowController?.hideHUD()
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
4. Response Format for Voice TTS: Always start your response with a single, highly coherent, substantive spoken summary paragraph (between 100 and 150 characters) optimized for being read out loud. For GUI or web tasks, do NOT just list mechanical actions (like "I opened Chrome" or "I scrolled"). Instead, summarize the actual substantive results, findings, or content of what you operated on (e.g., the key content of the clicked tweet or the search results). This first paragraph must be self-contained and ready for direct TTS. Leave a blank line, and then list any detailed step-by-step logs, full text, or technical breakdowns below it.
"""

    ask(routedPrompt) { [weak self] reply in
      guard let s = self else { return }
      guard !reply.isEmpty else {
        s.log("[Empty]")
        DispatchQueue.main.async {
          s.statusBar.setStatus(.idle)
          s.hudWindowController?.hideHUD()
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

  private func splitTextIntoSentences(_ t: String) -> [String] {
    var chunks: [String] = []
    
    // Split lines first
    let lines = t.components(separatedBy: "\n")
    for line in lines {
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedLine.isEmpty { continue }
      
      // Stop splitting if we hit code blocks or terminal command outputs
      if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("$ ") || trimmedLine.hasPrefix("npm ") || trimmedLine.hasPrefix("node ") {
        break
      }
      
      // Filter out markdown titles or numbers
      var cleanLine = trimmedLine.replacingOccurrences(of: "^[\\d\\.\\-\\s\\*\\#\\:\\：]+", with: "", options: .regularExpression)
      cleanLine = cleanLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if cleanLine.isEmpty { continue }
      
      // Use regular expression to split by sentence punctuation but keep the punctuation!
      let pattern = "[^。！？!?；;]+[。！？!?；;]?"
      if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
        let nsStr = cleanLine as NSString
        let matches = regex.matches(in: cleanLine, options: [], range: NSRange(location: 0, length: nsStr.length))
        for m in matches {
          let s = nsStr.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
          if !s.isEmpty {
            chunks.append(s)
          }
        }
      } else {
        chunks.append(cleanLine)
      }
    }
    
    // Fallback if split was completely empty
    if chunks.isEmpty {
      let fallback = t.replacingOccurrences(of: "^[\\d\\.\\-\\s\\*\\#]+", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
      if !fallback.isEmpty {
        chunks.append(fallback)
      }
    }
    
    return chunks
  }

  private func tts(_ t: String) {
    // Clear any active queue and play tasks
    cancelActiveVoiceOperations()
    
    // Split the text dynamically into clean sentences
    ttsQueue = splitTextIntoSentences(t)
    ttsQueueIndex = 0
    preFetchedAudioData = nil
    preFetchedIndex = -1
    
    log("[Queue] Created TTS queue with \(ttsQueue.count) sentences")
    
    guard !ttsQueue.isEmpty else {
      self.stopSpeakingAnimation()
      return
    }
    
    // Start playing the first chunk immediately!
    playQueueChunk(0)
  }

  private func playQueueChunk(_ index: Int) {
    guard index < ttsQueue.count else {
      self.log("[Queue] Finished playing all chunks")
      self.stopSpeakingAnimation()
      try? "idle".write(toFile: "/tmp/ocb_status.txt", atomically: true, encoding: .utf8)
      return
    }
    
    self.ttsQueueIndex = index
    let currentText = ttsQueue[index]
    self.log("[Queue] Playing chunk \(index)/\(ttsQueue.count): '\(currentText.prefix(30))...'")
    
    // Synchronously preload the next chunk in the background immediately
    preFetchChunk(index + 1)
    
    // Check if we already pre-fetched this chunk
    if preFetchedIndex == index, let audioData = preFetchedAudioData {
      self.log("[Queue] Pre-fetched audio cache HIT for chunk \(index)")
      self.playAudioData(audioData, forIndex: index)
      self.preFetchedAudioData = nil
      self.preFetchedIndex = -1
    } else {
      self.log("[Queue] Pre-fetch cache MISS for chunk \(index), synthesizing now...")
      synthesizeChunk(currentText) { [weak self] audioData in
        guard let s = self else { return }
        s.playAudioData(audioData, forIndex: index)
      }
    }
  }

  private func preFetchChunk(_ index: Int) {
    guard index < ttsQueue.count else { return }
    guard preFetchedIndex != index else { return } // already pre-fetched
    
    let nextText = ttsQueue[index]
    self.log("[Queue] Pre-fetching next chunk \(index): '\(nextText.prefix(20))...'")
    
    synthesizeChunk(nextText) { [weak self] audioData in
      guard let s = self else { return }
      s.preFetchedAudioData = audioData
      s.preFetchedIndex = index
      s.log("[Queue] Pre-fetched next chunk \(index) successfully!")
    }
  }

  private func synthesizeChunk(_ text: String, completion: @escaping (Data) -> Void) {
    guard let jsonData = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return }
    
    var request = URLRequest(url: URL(string: "http://localhost:8765/api/voice/tts")!)
    request.httpMethod = "POST"
    request.httpBody = jsonData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      if let error = error {
        self?.log("[Queue Err] Synthesis failed: \(error.localizedDescription)")
        return
      }
      guard let data = data, !data.isEmpty else {
        self?.log("[Queue Err] Empty audio data returned")
        return
      }
      completion(data)
    }
    task.resume()
  }

  private func playAudioData(_ data: Data, forIndex index: Int) {
    let mp3Url = "/tmp/ocb_tts.mp3"
    do {
      try data.write(to: URL(fileURLWithPath: mp3Url))
      
      // Update speaking status for VAD sync
      try? "sending".write(toFile: "/tmp/ocb_status.txt", atomically: true, encoding: .utf8)
      
      DispatchQueue.main.async { [weak self] in
        self?.startSpeakingAnimation(text: self?.ttsQueue[index] ?? "")
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
        
        // Go to next chunk in main queue!
        DispatchQueue.main.async {
          s.playQueueChunk(index + 1)
        }
      }
    } catch {
      self.log("[Queue Err] Failed to write/play audio: \(error.localizedDescription)")
      // Force transition to next chunk so the queue doesn't hang
      DispatchQueue.main.async { [weak self] in
        self?.playQueueChunk(index + 1)
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
      
      var combinedText = text
      if let s = self {
        let nextIndex = s.ttsQueueIndex + 1
        let nextText = nextIndex < s.ttsQueue.count ? s.ttsQueue[nextIndex] : ""
        combinedText = "\(text)|\(nextText)"
      }
      
      self?.hudWindowController?.updateState(state: "speaking", amplitude: amp, text: combinedText)
    }
  }

  func stopSpeakingAnimation() {
    speakingTimer?.invalidate()
    speakingTimer = nil
    hudWindowController?.updateState(state: "idle", amplitude: 0.0, text: "已完成回复")
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
}
