import AppKit
import Speech
import AVFoundation
import Carbon
import ApplicationServices
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {
  static weak var shared: AppDelegate?
  var statusBar: StatusBarController!
  private var voiceManager: VoiceManager!
  private let replyFile = "/tmp/voice_reply.txt"
  private let logFile = "/tmp/ocb_debug.log"
  var sessionId: String?
  private var lastQueryTime: Date?
  var hudWindowController: HUDWindowController?
  var notchDropZoneController: NotchDropZoneController?
  var isWaitingForDropCommand = false
  private var didPlayDropPrompt = false
  private var currentDroppedFilePath: String?
  private var didPauseMediaViaMediaRemote = false
  private var speakingTimer: Timer?
  private var pendingHideWorkItem: DispatchWorkItem?
  var currentAskProcess: Process?
  var currentPlayProcess: Process?
  private var ttsQueue: [String] = []
  private var ttsQueueIndex: Int = 0
  private var preFetchedAudioData: Data? = nil
  private var preFetchedIndex: Int = -1

  private var playQueue: [(data: Data, text: String)] = []
  var isPlayingQueue = false
  private var playChunkIndex = 0
  private var didPlayResponseChime = false
  private var streamResponseText = ""
  private var streamCurrentSentence = ""
  private var hasHitCodexResponsePrefix = false
  private var didSynthesizeAnySpeech = false
  private var queryExecutedAnyTools = false
  private let streamingQueue = DispatchQueue(label: "com.opencodex.streaming")
  private var currentQuerySequence = 0
  private var nextSentenceIndex = 0
  private var nextPlayIndex = 0
  private var pendingAudioMap: [Int: (data: Data, text: String)] = [:]
  private var expectedSentenceCount: Int? = nil
  private var streamProcessedCharCount = 0
  private var streamInCodeBlock = false
  private var proxyProcess: Process?

  func log(_ m: String) {
    if let h = FileHandle(forWritingAtPath: logFile) {
      h.seekToEndOfFile()
      h.write((m + "\n").data(using: .utf8)!)
      h.closeFile()
    }
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    AppDelegate.shared = self
    
    // Request accessibility permission on startup
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    
    // Auto launch opencodex proxy in background
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["npm", "start"]
    p.currentDirectoryURL = URL(fileURLWithPath: "/Users/aitabby/projects/opencodex")
    
    // Inject node path environment variables if needed
    var env = ProcessInfo.processInfo.environment
    let customPath = "/opt/homebrew/bin:/usr/local/bin"
    if let currentPath = env["PATH"] {
      env["PATH"] = "\(customPath):\(currentPath)"
    } else {
      env["PATH"] = customPath
    }
    p.environment = env
    
    do {
      try p.run()
      proxyProcess = p
      log("[App] Spawned Node.js OpenCodex Proxy Server process in background.")
    } catch {
      log("[App Err] Failed to spawn Node.js Proxy Server: \(error.localizedDescription)")
    }
    
    voiceManager = VoiceManager()
    hudWindowController = HUDWindowController()
    WebSocketManager.shared.connect()
    
    // Do not restore the active session ID on startup. Start with a clean/new dialogue session.
    self.sessionId = nil
    log("[App] Started clean session for new dialogue.")
    
    // 设置 session 切换回调（启动时就生效）
    WebSocketManager.shared.onActivateSession = { [weak self] sid in
      self?.log("[VM] Activate session: \(sid)")
      DispatchQueue.main.async {
        self?.sessionId = sid
        self?.hudWindowController?.updateState(state: "idle", amplitude: 0, text: "已切换到会话: \(sid.prefix(8))...")
      }
    }
    
    // Register streaming text listeners for TTS
    WebSocketManager.shared.onModelChunk = { [weak self] text in
      guard let self = self else { return }
      self.log("[WS Chunk] \(text)")
      self.processStreamingChunk(text, querySeq: self.currentQuerySequence)
    }
    
    WebSocketManager.shared.onModelDone = { [weak self] text in
      guard let self = self else { return }
      self.log("[WS Done] \(text)")
      self.streamingQueue.async {
        // Flush remaining text
        let finalSentence = self.clean(self.streamCurrentSentence)
        if !finalSentence.isEmpty {
          let cleanedTail = self.cleanIntroductoryTail(finalSentence)
          if !cleanedTail.isEmpty {
            let idx = self.nextSentenceIndex
            self.nextSentenceIndex += 1
            self.synthesizeSentence(cleanedTail, index: idx, querySeq: self.currentQuerySequence)
          }
        }
        self.expectedSentenceCount = self.nextSentenceIndex
        
        if self.nextSentenceIndex == 0 {
          let cleaned = self.clean(text)
          if !cleaned.isEmpty {
            if self.isEnglishOnlyGreeting(cleaned) {
              self.log("[WS Done] Bypassed final English greeting summary: '\(cleaned)'")
              DispatchQueue.main.async {
                self.stopSpeakingAnimation()
              }
              return
            }
            self.log("[TTS] Speaking final summary via tts().")
            DispatchQueue.main.async {
              self.tts(cleaned)
            }
          }
          return
        }
        
        self.processPlayQueue()
      }
    }
    
    notchDropZoneController = NotchDropZoneController(
      onDragEntered: { [weak self] in
        self?.handleDragEntered()
      },
      onDragExited: { [weak self] in
        self?.handleDragExited()
      },
      onPerformDrop: { [weak self] urls in
        self?.handlePerformDrop(urls)
      }
    )
    
    try? "".write(toFile: replyFile, atomically: true, encoding: .utf8)
    try? "".write(toFile: logFile, atomically: true, encoding: .utf8)
    log("[App] Launch")
    
    ensurePythonScripts()
    setupMainMenu()
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self = self else { return }
      let apiClient = APIClient()
      self.statusBar = StatusBarController(apiClient: apiClient)
      
      // By default, do not start listening on launch. Wait for manual activation.
      AppDelegate.shared?.log("[App] Ready. Waiting for activation.")
    }
    
    do {
      try registerHotkey()
      log("[Hotkey] Registered global hotkey Option+Space successfully.")
    } catch {
      log("[Hotkey] Failed to register global hotkey Option+Space: \(error)")
    }
  }

  func applicationWillTerminate(_ aNotification: Notification) {
    log("[App] Terminating. Resuming all system media to prevent frozen states.")
    
    // Synchronously thaw native media apps instantly via SIGCONT (takes <1ms)
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
    
    // Dynamically thaw any active PIDs we suspended during the active session (takes <1ms)
    for pid in self.suspendedPIDs {
        let contTask = Process()
        contTask.executableURL = URL(fileURLWithPath: "/bin/kill")
        contTask.arguments = ["-CONT", "\(pid)"]
        try? contTask.run()
    }

    if let p = proxyProcess, p.isRunning {
      p.terminate()
      log("[App] Terminated local OpenCodex proxy server.")
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
        AppDelegate.shared?.log("[Hotkey] Global hotkey pressed!")
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
    currentQuerySequence += 1
    if let existingAsk = currentAskProcess {
      if let outPipe = existingAsk.standardOutput as? Pipe {
        outPipe.fileHandleForReading.readabilityHandler = nil
      }
      if let errPipe = existingAsk.standardError as? Pipe {
        errPipe.fileHandleForReading.readabilityHandler = nil
      }
      if existingAsk.isRunning {
        existingAsk.terminate()
      }
      log("[Voice] Terminated active Codex query")
      currentAskProcess = nil
    }
    if let existingPlay = currentPlayProcess {
      if existingPlay.isRunning {
        existingPlay.terminate()
        log("[Voice] Terminated active afplay playback")
      }
      currentPlayProcess = nil
    }
    voiceManager?.cancelListening()
    speakingTimer?.invalidate()
    speakingTimer = nil
    
    pendingHideWorkItem?.cancel()
    pendingHideWorkItem = nil
    
    // Invalidate media monitoring timer
    mediaMonitoringTimer?.invalidate()
    mediaMonitoringTimer = nil
    
    // Clear queues
    ttsQueue.removeAll()
    ttsQueueIndex = 0
    preFetchedAudioData = nil
    preFetchedIndex = -1
    
    // Clear playback queues
    playQueue.removeAll()
    isPlayingQueue = false
    nextSentenceIndex = 0
    nextPlayIndex = 0
    pendingAudioMap.removeAll()
    expectedSentenceCount = nil
  }

  @objc func toggleVoiceInput() {
    let isActive = voiceManager.isListening || currentAskProcess != nil || currentPlayProcess != nil || isPlayingQueue
    
    if isActive {
      log("[Toggle] Active -> Stop (Standby)")
      cancelActiveVoiceOperations()
      if voiceManager.isListening {
        voiceManager.cancelListening()
      }
      statusBar.setStatus(.idle)
      hudWindowController?.hideHUD(force: true) { [weak self] in
        self?.resumeSystemMedia()
      }
    } else {
      log("[Toggle] Standby/Idle -> Start Listening")
      cancelActiveVoiceOperations()
      
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
          s.hudWindowController?.hideHUD(force: true) { [weak s] in
            s?.resumeSystemMedia()
          }
          return
        }
        s.processVoice(t)
      }
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

    currentQuerySequence += 1
    self.lastQueryTime = Date()

    log("[Go] \(text.prefix(30))")
    
    // Explicitly turn off the microphone and close the audio engine tap immediately when transitioning to thinking/sending.
    voiceManager.cancelListening()
    
    statusBar.setStatus(.sending)
    hudWindowController?.updateState(state: "thinking", amplitude: 0.0, text: "Thinking...")
    try? text.write(toFile: "/tmp/voice_cmd.txt", atomically: true, encoding: .utf8)

    // Reset streaming state before asking
    self.streamResponseText = ""
    self.streamCurrentSentence = ""
    self.hasHitCodexResponsePrefix = false
    self.didPlayResponseChime = false
    self.didSynthesizeAnySpeech = false
    self.nextSentenceIndex = 0
    self.nextPlayIndex = 0
    self.pendingAudioMap.removeAll()
    self.expectedSentenceCount = nil
    self.streamProcessedCharCount = 0
    self.queryExecutedAnyTools = false
    self.streamInCodeBlock = false

    let activeSeq = self.currentQuerySequence
    ask(text) { [weak self] reply in
      guard let s = self, s.currentQuerySequence == activeSeq else { return }
      guard !reply.isEmpty else {
        s.log("[Empty] Keep thinking state waiting for stream.")
        return
      }
      
      if reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok" {
        s.log("[Ask] Prompt successfully injected. Waiting for model stream chunks, skipping TTS for 'ok'.")
        return
      }

      let finalReply = s.extractFinalCodexResponse(reply) ?? ""
      let c = s.clean(finalReply)
      s.log("[LLM Done] Output text written to file. Speaking final summary.")
      try? c.write(toFile: s.replyFile, atomically: true, encoding: .utf8)

      // Scan full reply for tool executions to be robust
      let lines = reply.components(separatedBy: .newlines)
      for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("mcp:") || trimmed.hasPrefix("exec") {
          s.queryExecutedAnyTools = true
          break
        }
      }

      s.streamingQueue.async {
        guard s.currentQuerySequence == activeSeq else { return }
        
        // Always flush remaining sentence and set expected count
        let finalSentence = s.clean(s.streamCurrentSentence)
        if !finalSentence.isEmpty {
          let cleanedTail = s.cleanIntroductoryTail(finalSentence)
          if !cleanedTail.isEmpty {
            let idx = s.nextSentenceIndex
            s.nextSentenceIndex += 1
            s.synthesizeSentence(cleanedTail, index: idx, querySeq: activeSeq)
          }
        }
        s.expectedSentenceCount = s.nextSentenceIndex
        
        // If no sentences were synthesized at all, try extractFinalCodexResponse
        if s.nextSentenceIndex == 0 {
          s.log("[TTS] No streaming sentences. Trying final reply extraction.")
          if let finalReply = s.extractFinalCodexResponse(reply) {
            let cleaned = s.clean(finalReply)
            if !cleaned.isEmpty {
              s.log("[TTS] Final reply available, speaking via tts().")
              DispatchQueue.main.async {
                guard s.currentQuerySequence == activeSeq else { return }
                s.tts(cleaned)
              }
              return
            }
          }
          s.log("[TTS] No speech content available.")
          return
        }
        
        s.processPlayQueue()
      }
    }
  }

    private var prewarmedAskProcess: Process?
  private var prewarmedPty: (master: FileHandle, slave: FileHandle)?

  @objc func prewarmCodexProcess() {
    DispatchQueue.global().async { [weak self] in
      guard let self = self else { return }
      if self.prewarmedAskProcess != nil { return }
      self.log("[Ask] Prewarming Codex process...")
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
      var env = ProcessInfo.processInfo.environment
      let localBin = "\(NSHomeDirectory())/.gemini/antigravity/bin"
      let customPath = "\(localBin):/opt/homebrew/bin:/usr/local/bin"
      if let currentPath = env["PATH"] { env["PATH"] = "\(customPath):\(currentPath)" } else { env["PATH"] = customPath }
      task.environment = env
      task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
      let settings = VoiceSettings.load()
      var args = ["--dangerously-bypass-approvals-and-sandbox", "exec"]
      if let model = settings.voice_llm_model, !model.isEmpty { args.append(contentsOf: ["--model", model]) }
      if let sid = self.sessionId { args.append(contentsOf: ["resume", sid]) }
      args.append(contentsOf: ["--skip-git-repo-check", "-"])
      task.arguments = args
      guard let pty = self.openPty() else { return }
      task.standardInput = pty.slave
      task.standardOutput = pty.slave
      task.standardError = pty.slave
      do {
        try task.run()
        self.prewarmedAskProcess = task
        self.prewarmedPty = pty
        self.log("[Ask] Prewarm successful.")
      } catch {
        self.log("[Ask Err] Prewarm failed.")
      }
    }
  }
private func openPty() -> (master: FileHandle, slave: FileHandle)? {
    var masterFd: Int32 = 0
    masterFd = posix_openpt(O_RDWR | O_NOCTTY)
    guard masterFd >= 0 else { return nil }
    guard grantpt(masterFd) == 0 else {
      close(masterFd)
      return nil
    }
    guard unlockpt(masterFd) == 0 else {
      close(masterFd)
      return nil
    }
    guard let ptsName = ptsname(masterFd) else {
      close(masterFd)
      return nil
    }
    let slaveFd = open(ptsName, O_RDWR | O_NOCTTY)
    guard slaveFd >= 0 else {
      close(masterFd)
      return nil
    }
    var t = termios()
    if tcgetattr(slaveFd, &t) == 0 {
      t.c_lflag &= ~tcflag_t(ECHO)
      tcsetattr(slaveFd, TCSANOW, &t)
    }
    let masterHandle = FileHandle(fileDescriptor: masterFd, closeOnDealloc: true)
    let slaveHandle = FileHandle(fileDescriptor: slaveFd, closeOnDealloc: true)
    return (masterHandle, slaveHandle)
  }

  private func ask(_ prompt: String, cb: @escaping (String) -> Void) {
    log("[Ask] Sending to Codex via proxy: \(prompt.prefix(60))")
    
    let activeSeq = self.currentQuerySequence
    var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/api/voice/ask")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let bodyObj: [String: Any] = [
      "prompt": prompt,
      "session_id": self.sessionId ?? "default"
    ]
    
    guard let jsonData = try? JSONSerialization.data(withJSONObject: bodyObj) else {
      cb("[错误]")
      return
    }
    request.httpBody = jsonData
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self, self.currentQuerySequence == activeSeq else { return }
      
      if let error = error {
        self.log("[Ask Err] \(error.localizedDescription)")
        DispatchQueue.main.async { cb("[错误]") }
        return
      }
      
      if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        self.log("[Ask Err] HTTP \(http.statusCode): \(body)")
        DispatchQueue.main.async { cb("[错误]") }
        return
      }
      
      self.log("[Ask Success] Prompt successfully injected via CDP.")
      // Since it's injected via CDP to Electron UI, the Electron app executes it and shows the UI.
      // We don't have direct back-and-forth terminal stdout in this mode, so we return empty string.
      // But processVoice will handle the execution. We can return "ok" or similar.
      DispatchQueue.main.async { cb("ok") }
    }
    task.resume()
  }

  private func isCodexHeader(_ line: String) -> Bool {
    let lower = line.lowercased()
    return lower == "codex" || lower.hasPrefix("codex:") || lower.hasPrefix("codex ")
  }

  private func isOtherBlockHeader(_ line: String) -> Bool {
    let lower = line.lowercased()
    if lower.hasPrefix("mcp:") || lower.hasPrefix("exec") || lower.hasPrefix("user") {
      return true
    }
    if lower.hasPrefix("--------") ||
       lower.hasPrefix("openai codex") ||
       lower.hasPrefix("workdir:") ||
       lower.hasPrefix("model:") ||
       lower.hasPrefix("provider:") ||
       lower.hasPrefix("approval:") ||
       lower.hasPrefix("sandbox:") ||
       lower.hasPrefix("reasoning effort:") ||
       lower.hasPrefix("reasoning summaries:") ||
       lower.hasPrefix("session id:") {
      return true
    }
    return false
  }

  private func processStreamingChunk(_ chunk: String, querySeq: Int) {
    streamingQueue.async { [weak self] in
      guard let self = self else { return }
      if self.currentQuerySequence != querySeq {
        return
      }
      self.log("[Stream Chunk] '\(chunk)'")
      self.streamResponseText += chunk
      
      let cleanText = self.streamResponseText.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
      self.parseAndQueueSentences(cleanText, querySeq: querySeq)
    }
  }

  private func getLine(at index: Int, in chars: [Character]) -> (line: String, endIndex: Int) {
    var line = ""
    var idx = index
    let totalCount = chars.count
    while idx < totalCount {
      let c = chars[idx]
      if c == "\n" || c == "\r" {
        break
      }
      line.append(c)
      idx += 1
    }
    return (line, idx)
  }

  private func isUnspeakableLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") ||
       trimmed.hasPrefix("|") ||
       trimmed.hasPrefix("$ ") ||
       trimmed.hasPrefix("% ") ||
       trimmed.hasPrefix("---") {
      return true
    }
    return false
  }

  private func parseAndQueueSentences(_ text: String, querySeq: Int) {
    let chars = Array(text)
    let totalCount = chars.count
    
    while streamProcessedCharCount < totalCount {
      // Check if we are at the start of a line
      let isStartOfLine = (streamProcessedCharCount == 0) || 
                          (chars[streamProcessedCharCount - 1] == "\n" || chars[streamProcessedCharCount - 1] == "\r")
      
      if isStartOfLine {
        let (currentLine, endIndex) = self.getLine(at: streamProcessedCharCount, in: chars)
        let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check code block toggle
        if trimmed.hasPrefix("```") {
          self.streamInCodeBlock = !self.streamInCodeBlock
          self.log("[Stream TTS] Code block toggle: streamInCodeBlock = \(self.streamInCodeBlock) (line: '\(trimmed)')")
          
          // Flush the current buffer before skipping/toggling
          let sentence = self.clean(streamCurrentSentence)
          if !sentence.isEmpty {
            let cleanedSentence = self.cleanIntroductoryTail(sentence)
            if !cleanedSentence.isEmpty {
              let index = nextSentenceIndex
              nextSentenceIndex += 1
              synthesizeSentence(cleanedSentence, index: index, querySeq: querySeq)
            }
            streamCurrentSentence = ""
          }
          
          // Skip the entire line (including the code block marker)
          streamProcessedCharCount = endIndex
          continue
        }
        
        // If we are currently inside a code block, or if this line is unspeakable
        if self.streamInCodeBlock || self.isUnspeakableLine(trimmed) {
          self.log("[Stream TTS] Skipping line (inCodeBlock: \(self.streamInCodeBlock), unspeakable: \(self.isUnspeakableLine(trimmed))): '\(trimmed)'")
          
          // Flush the current buffer before skipping
          let sentence = self.clean(streamCurrentSentence)
          if !sentence.isEmpty {
            let cleanedSentence = self.cleanIntroductoryTail(sentence)
            if !cleanedSentence.isEmpty {
              let index = nextSentenceIndex
              nextSentenceIndex += 1
              synthesizeSentence(cleanedSentence, index: index, querySeq: querySeq)
            }
            streamCurrentSentence = ""
          }
          
          // Skip the entire line
          streamProcessedCharCount = endIndex
          continue
        }
      }
      
      let char = chars[streamProcessedCharCount]
      
      if char == "\n" || char == "\r" {
        // Skip double processing of CRLF
        if char == "\r" && streamProcessedCharCount + 1 < totalCount && chars[streamProcessedCharCount + 1] == "\n" {
          streamProcessedCharCount += 1 // Advance past \r, the \n will handle it
        }
        
        let sentence = self.clean(streamCurrentSentence)
        if !sentence.isEmpty {
          if isIntroductorySentence(sentence) {
            // Keep introductory sentence in buffer to see if it is followed by structured content
          } else if isEnglishOnlyGreeting(sentence) {
            self.log("[Stream TTS] Filtering out English greeting: '\(sentence)'")
            streamCurrentSentence = ""
          } else {
            let index = nextSentenceIndex
            nextSentenceIndex += 1
            synthesizeSentence(sentence, index: index, querySeq: querySeq)
            streamCurrentSentence = ""
          }
        }
      } else if char == "。" || char == "！" || char == "？" || char == "!" || char == "?" || char == "；" || char == ";" {
        streamCurrentSentence.append(char)
        let sentence = self.clean(streamCurrentSentence)
        if !sentence.isEmpty {
          if isIntroductorySentence(sentence) {
            // Keep in buffer
          } else if isEnglishOnlyGreeting(sentence) {
            self.log("[Stream TTS] Filtering out English greeting: '\(sentence)'")
            streamCurrentSentence = ""
          } else {
            let index = nextSentenceIndex
            nextSentenceIndex += 1
            synthesizeSentence(sentence, index: index, querySeq: querySeq)
            streamCurrentSentence = ""
          }
        }
      } else {
        streamCurrentSentence.append(char)
      }
      
      streamProcessedCharCount += 1
    }
  }

  private func synthesizeSentence(_ text: String, index: Int, querySeq: Int) {
    if isEnglishOnlyGreeting(text) {
      self.log("[Stream TTS] Bypassing English thought/greeting \(index): '\(text)'")
      self.queueAudio(Data(), text: text, index: index)
      return
    }
    self.log("[Stream TTS] Synthesizing sentence \(index): '\(text)'")
    synthesizeFullReply(text) { [weak self] audioData in
      guard let s = self else { self?.log("[TTS] self is nil for sentence \(index)"); return }
      guard s.currentQuerySequence == querySeq else {
        s.log("[TTS] seq mismatch for sentence \(index): cur=\(s.currentQuerySequence) query=\(querySeq)")
        return
      }
      s.log("[TTS] Got audio for sentence \(index) (\(audioData.count) bytes), queuing")
      s.queueAudio(audioData, text: text, index: index)
    }
  }

  private func queueAudio(_ data: Data, text: String, index: Int) {
    streamingQueue.async { [weak self] in
      guard let self = self else { return }
      self.log("[QAudio] index=\(index) data=\(data.count)b pending=\(self.pendingAudioMap.count) expected=\(self.expectedSentenceCount.map { String($0) } ?? "nil") playIdx=\(self.nextPlayIndex)")
      self.pendingAudioMap[index] = (data: data, text: text)
      self.processPlayQueue()
    }
  }

  private func processPlayQueue() {
    if isPlayingQueue {
      log("[PlayQ] blocked: isPlayingQueue=true")
      return
    }
    
    if let expected = expectedSentenceCount, nextPlayIndex >= expected {
      log("[PlayQ] done: nextPlayIndex=\(nextPlayIndex) >= expected=\(expected)")
      try? "idle".write(toFile: "/tmp/ocb_status.txt", atomically: true, encoding: .utf8)
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.statusBar.setStatus(.idle)
        self.stopSpeakingAnimation()
      }
      return
    }
    
    guard let nextItem = pendingAudioMap[nextPlayIndex] else {
      log("[PlayQ] waiting: nextPlayIndex=\(nextPlayIndex) expected=\(expectedSentenceCount.map { String($0) } ?? "nil") pending_keys=\(pendingAudioMap.keys.sorted())")
      return
    }
    
    pendingAudioMap.removeValue(forKey: nextPlayIndex)
    nextPlayIndex += 1
    
    playQueue.append(nextItem)
    playNextQueueItem()
  }

  private func playNextQueueItem() {
    let activeSeq = self.currentQuerySequence
    guard !playQueue.isEmpty else {
      isPlayingQueue = false
      try? "idle".write(toFile: "/tmp/ocb_status.txt", atomically: true, encoding: .utf8)
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.currentQuerySequence == activeSeq else { return }
        self.statusBar.setStatus(.idle)
        self.stopSpeakingAnimation()
      }
      return
    }
    
    isPlayingQueue = true
    let item = playQueue.removeFirst()
    let data = item.data
    let text = item.text
    if data.isEmpty {
      log("[PlayQ] Skipping empty audio item (TTS failed)")
      streamingQueue.async { [weak self] in
        self?.isPlayingQueue = false
        self?.processPlayQueue()
      }
      return
    }
    let isWav = data.count >= 4 && data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 // "RIFF"
    let ext = isWav ? "wav" : "mp3"
    let chunkFile = "/tmp/ocb_tts_chunk_\(playChunkIndex).\(ext)"
    playChunkIndex += 1
    
    do {
      try data.write(to: URL(fileURLWithPath: chunkFile))
      
      // Update speaking status for VAD sync
      try? "speaking".write(toFile: "/tmp/ocb_status.txt", atomically: true, encoding: .utf8)
      
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.currentQuerySequence == activeSeq else { return }
        // Play response chime only once per query
        if !self.didPlayResponseChime {
          self.didPlayResponseChime = true
          if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true) {
            sound.play()
          }
        }
        self.startSpeakingAnimation(text: text)
      }
      
      DispatchQueue.global().async { [weak self] in
        guard let s = self else { return }
        
        let p = Process()
        s.currentPlayProcess = p
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [chunkFile]
        p.terminationHandler = { [weak self] _ in
          try? FileManager.default.removeItem(atPath: chunkFile)
          self?.streamingQueue.async {
            guard let s = self, s.currentQuerySequence == activeSeq else { return }
            s.currentPlayProcess = nil
            s.isPlayingQueue = false
            s.processPlayQueue()
          }
        }
        do {
          try p.run()
        } catch {
          s.log("[Play Queue Err] \(error.localizedDescription)")
          s.streamingQueue.async { [weak self] in
            guard let s = self, s.currentQuerySequence == activeSeq else { return }
            s.currentPlayProcess = nil
            s.isPlayingQueue = false
            s.processPlayQueue()
          }
        }
      }
    } catch {
      log("[Play Queue Write Err] \(error.localizedDescription)")
      streamingQueue.async { [weak self] in
        guard let self = self, self.currentQuerySequence == activeSeq else { return }
        self.currentPlayProcess = nil
        self.isPlayingQueue = false
        self.processPlayQueue()
      }
    }
  }



  private func isEnglishOnlyGreeting(_ text: String) -> Bool {
    let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if lower.contains("how can i help") || lower.contains("how can i assist") || lower.contains("hey!") || lower.hasPrefix("hello") || lower.contains("welcome") || lower == "hey" {
      return true
    }
    // If it has no Chinese and is relatively short or contains common greeting words, filter it.
    let hasChinese = text.range(of: "\\p{Han}", options: .regularExpression) != nil
    if !hasChinese {
      if lower.contains("codex") || lower.contains("helper") || lower.contains("assistant") || lower.contains("hello") || text.count < 150 {
        return true
      }
    }
    return false
  }

  private func isIntroductorySentence(_ text: String) -> Bool {
    let cleaned = clean(text)
    let lower = cleaned.lowercased()
    
    if lower.hasSuffix("：") || lower.hasSuffix(":") ||
       lower.hasSuffix("如下") || lower.hasSuffix("如下所示") ||
       lower.hasSuffix("请看") || lower.hasSuffix("比如") ||
       lower.hasSuffix("例如") || lower.hasSuffix("如下：") ||
       lower.hasSuffix("如下:") {
      return true
    }
    return false
  }

  private func stripIntroductoryTail(_ text: String) -> String {
    var result = clean(text)
    let suffixList = [
      "如下所示：", "如下所示:", "如下所示。", "如下所示",
      "如下：", "如下:", "如下。", "如下",
      "步骤如下：", "步骤如下:", "步骤如下",
      "操作步骤如下：", "操作步骤如下:", "操作步骤如下",
      "以下是操作步骤：", "以下是操作步骤",
      "具体步骤如下：", "具体步骤如下:", "具体步骤如下",
      "请看：", "请看:", "请看。", "请看",
      "比如：", "比如:", "比如。", "比如",
      "例如：", "例如:", "例如。", "例如",
      "具体内容：", "具体内容:", "具体内容",
      "操作步骤：", "操作步骤:", "操作步骤",
      "内容如下：", "内容如下:", "内容如下",
      "：", ":"
    ]
    
    var changed = true
    while changed {
      changed = false
      for suffix in suffixList {
        if result.lowercased().hasSuffix(suffix) {
          let len = suffix.count
          result = String(result.dropLast(len)).trimmingCharacters(in: .whitespacesAndNewlines)
          if result.hasSuffix("，") || result.hasSuffix(",") {
            result = String(result.dropLast(1)).trimmingCharacters(in: .whitespacesAndNewlines)
          }
          changed = true
          break
        }
      }
    }
    return result
  }

  private func cleanIntroductoryTail(_ text: String) -> String {
    return stripIntroductoryTail(text)
  }

  private func tts(_ t: String) {
    if let existingPlay = currentPlayProcess {
      if existingPlay.isRunning {
        existingPlay.terminate()
      }
      currentPlayProcess = nil
    }
    speakingTimer?.invalidate()
    speakingTimer = nil
    
    // Don't cancel voice operations (which would invalidate currentQuerySequence)
    // — just stop any active afplay
    
    let cleaned = clean(t)
    var shortText = cleaned
    shortText = shortText.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if isEnglishOnlyGreeting(shortText) {
      log("[TTS] Bypassed synthesis for English greeting: '\(shortText)'")
      stopSpeakingAnimation()
      return
    }
    
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
    
    log("[TTS] Synthesizing: '\(shortText.prefix(30))...'")
    
    let activeSeq = self.currentQuerySequence
    synthesizeFullReply(shortText) { [weak self] audioData in
      guard let s = self, s.currentQuerySequence == activeSeq else { return }
      s.playFullAudio(audioData, text: shortText)
    }
  }

  private func synthesizeFullReply(_ text: String, completion: @escaping (Data) -> Void) {
    guard let jsonData = try? JSONSerialization.data(withJSONObject: ["text": text]) else {
      completion(Data())
      return
    }
    
    var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/api/voice/tts")!)
    request.httpMethod = "POST"
    request.httpBody = jsonData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      if let error = error {
        self?.log("[TTS Err] Synthesis failed: \(error.localizedDescription)")
        completion(Data())
        return
      }
      if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        self?.log("[TTS Err] HTTP \(http.statusCode): \(body.prefix(120))")
        completion(Data())
        return
      }
      guard let data = data, !data.isEmpty else {
        self?.log("[TTS Err] Empty audio data returned")
        completion(Data())
        return
      }
      completion(data)
    }
    task.resume()
  }

  private func playFullAudio(_ data: Data, text: String) {
    let activeSeq = self.currentQuerySequence
    let isWav = data.count >= 4 && data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 // "RIFF"
    let audioUrl = isWav ? "/tmp/ocb_tts.wav" : "/tmp/ocb_tts.mp3"
    do {
      try data.write(to: URL(fileURLWithPath: audioUrl))
      
      // Update speaking status for VAD sync
      try? "speaking".write(toFile: "/tmp/ocb_status.txt", atomically: true, encoding: .utf8)
      
      DispatchQueue.main.async { [weak self] in
        guard let s = self, s.currentQuerySequence == activeSeq else { return }
        s.statusBar.setStatus(.idle)
        s.startSpeakingAnimation(text: text)
      }
      
      DispatchQueue.global().async { [weak self] in
        guard let s = self else { return }
        if let existing = s.currentPlayProcess, existing.isRunning {
          existing.terminate()
        }
        
        let playTask = Process()
        s.currentPlayProcess = playTask
        playTask.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        playTask.arguments = [audioUrl]
        try? playTask.run()
        playTask.waitUntilExit()
        
        s.log("[TTS] Finished playing full audio")
        try? "idle".write(toFile: "/tmp/ocb_status.txt", atomically: true, encoding: .utf8)
        
        DispatchQueue.main.async {
          guard s.currentQuerySequence == activeSeq else { return }
          s.currentPlayProcess = nil
          s.stopSpeakingAnimation()
        }
      }
    } catch {
      self.log("[TTS Err] Failed to write/play audio: \(error.localizedDescription)")
      DispatchQueue.main.async { [weak self] in
        guard let s = self, s.currentQuerySequence == activeSeq else { return }
        s.stopSpeakingAnimation()
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

  private func cleanListMarkers(_ line: String) -> String {
    var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Strip leading blockquotes
    while trimmed.hasPrefix(">") {
      trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    
    // Strip leading markdown headers (e.g., #, ##, ###)
    while trimmed.hasPrefix("#") {
      trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix("• ") {
      trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    } else if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("+") || trimmed.hasPrefix("•") {
      trimmed = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
    }
    
    if let regex = try? NSRegularExpression(pattern: "^[0-9]+[\\.\\s、]+"),
       let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) {
      trimmed = String(trimmed.suffix(from: trimmed.index(trimmed.startIndex, offsetBy: match.range.length))).trimmingCharacters(in: .whitespaces)
    }
    
    return trimmed
  }

  private func clean(_ t: String) -> String {
    var r = t
    r = r.replacingOccurrences(of: "[\\p{So}\\p{Sk}]", with: "", options: .regularExpression)
    r = r.replacingOccurrences(of: "**", with: "")
    r = r.replacingOccurrences(of: "*", with: "")
    r = r.replacingOccurrences(of: "`", with: "")
    
    let lines = r.components(separatedBy: .newlines)
    var cleanedLines = [String]()
    for line in lines {
      let cleaned = cleanListMarkers(line)
      if !cleaned.isEmpty {
        cleanedLines.append(cleaned)
      }
    }
    r = cleanedLines.joined(separator: "\n")
    return r.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func stripTerminalHeader(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    var dividerCount = 0
    var headerEndIndex = -1
    
    for i in 0..<lines.count {
      let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("--------") {
        dividerCount += 1
        if dividerCount == 2 {
          headerEndIndex = i
          break
        }
      }
    }
    
    if headerEndIndex != -1 && headerEndIndex + 1 < lines.count {
      var contentStartIndex = headerEndIndex + 1
      while contentStartIndex < lines.count {
        let line = lines[contentStartIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        if line.lowercased() == "user" {
          contentStartIndex += 1
          while contentStartIndex < lines.count {
            let nextLine = lines[contentStartIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if nextLine.isEmpty {
              contentStartIndex += 1
              break
            }
            contentStartIndex += 1
          }
          break
        }
        contentStartIndex += 1
      }
      if contentStartIndex < lines.count {
        return lines[contentStartIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    
    return text
  }

  private func extractFinalCodexResponse(_ t: String) -> String? {
    let cleanText = t.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
    
    // If it's a direct clean API text from the Electron/CDP proxy, it won't contain the "--------" divider.
    if !cleanText.contains("--------") {
      return cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    let stripped = stripTerminalHeader(cleanText)
    let lines = stripped.components(separatedBy: .newlines)
    
    for i in (0..<lines.count).reversed() {
      let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = line.lowercased()
      if lower == "codex" || lower.hasPrefix("codex:") || lower.hasPrefix("codex ") {
        let responseLines = lines[(i + 1)...]
        var response = responseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if response.isEmpty {
          let markerLength = lower.hasPrefix("codex:") ? 6 : 6
          response = String(line.dropFirst(markerLength)).trimmingCharacters(in: .whitespacesAndNewlines)
          if response.hasPrefix(":") {
            response = response.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
          }
        }
        return response
      }
    }
    
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
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
    
    // Explicitly reset queue markers for the next session loop
    self.expectedSentenceCount = nil
    self.pendingAudioMap.removeAll()
    self.playQueue.removeAll()
    self.nextPlayIndex = 0
    self.isPlayingQueue = false
    
    DispatchQueue.main.async { [weak self] in
      guard let s = self else { return }
      if s.statusBar.currentStatus == .listening && s.voiceManager.isListening {
        s.log("[Live Mode] Already listening, skipping redundant transition.")
        return
      }
      
      s.log("[Live Mode] Text ended. Transitioning to continuous listening standby...")
      s.statusBar.setStatus(.listening)
      s.hudWindowController?.updateState(state: "listening", amplitude: 0.0, text: "我在听，你说吧...")
      
      s.voiceManager.amplitudeUpdateHandler = { [weak self] amp in
        self?.hudWindowController?.updateState(state: "listening", amplitude: amp, text: "我在听，你说吧...")
      }

      // Add a safety delay of 800ms before starting recording/listening to ensure afplay output and echo are completely quiet.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
        guard let s = self else { return }
        // Verify we are still in listening state before starting
        guard s.statusBar.currentStatus == .listening else { return }
        
        s.voiceManager.startListening { [weak self] text in
          guard let s = self else { return }
          
          let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "，", with: "") ?? ""
          
          guard !cleaned.isEmpty && cleaned.count > 1 else {
            s.log("[Live Mode] Ignored empty/noise text segment, looping listen...")
            s.stopSpeakingAnimation()
            return
          }
          
          s.log("[Live Mode] Captured next voice command: '\(cleaned)'")
          s.statusBar.setStatus(.sending)
          s.hudWindowController?.updateState(state: "thinking", amplitude: 0.0, text: "Thinking...")
          s.processVoice(cleaned)
        }
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
        "model": "speech-2.8-turbo",
        "text": text,
        "stream": False,
        "voice_setting": {
            "voice_id": voice_id,
            "speed": 1.0,
            "vol": 1.0,
            "pitch": 0,
            "emotion": "happy"
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
                
            audio_data = res_json.get("data")
            if not audio_data:
                print("ERROR: No audio data returned from MiniMax")
                sys.exit(1)
            audio_hex = audio_data.get("audio") if isinstance(audio_data, dict) else audio_data
            if not audio_hex:
                print("ERROR: No audio hex string found")
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
  private var suspendedPIDs: Set<Int> = []
  private var mediaMonitoringTimer: Timer?

  // Dynamic loading of MediaRemote private framework (controls system-wide media cleanly without UI locks)
  private func sendMediaRemoteCommand(_ command: Int32) {
    let path = "/System/Library/PrivateFrameworks/MediaRemote.framework"
    guard let bundle = CFBundleCreate(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL) else {
        log("[MediaRemote] Failed to create bundle")
        return
    }
    if !CFBundleLoadExecutable(bundle) {
        log("[MediaRemote] Failed to load executable")
        return
    }
    
    typealias SendCommandType = @convention(c) (Int32, AnyObject?) -> Bool
    if let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
        let sendCommand = unsafeBitCast(pointer, to: SendCommandType.self)
        let success = sendCommand(command, nil)
        log("[MediaRemote] Sent command \(command): success = \(success)")
    } else {
        log("[MediaRemote] Symbol not found")
    }
  }

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
      var isRecordingAssertion = false
      
      for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.starts(with: "pid ") || trimmed.contains("preventuseridlesleep") {
          let lower = trimmed.lowercased()
          isRecordingAssertion = lower.contains("record") || 
                                 lower.contains("aggregate") || 
                                 lower.contains("audio-in") ||
                                 lower.contains("blackhole") ||
                                 lower.contains("microphone") ||
                                 lower.contains("input")
        }
        
        if trimmed.contains("Created for PID:") {
          if !isRecordingAssertion {
            let parts = trimmed.components(separatedBy: "Created for PID:")
            if parts.count > 1 {
              let pidStr = parts[1].trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
              if let pid = Int(pidStr) {
                pids.insert(pid)
              }
            }
          }
        }
      }
    }
    
    // Filter to only include explicit native media players to avoid false sleep assertion triggers from browsers/other apps
    var filteredPids = Set<Int>()
    for pid in pids {
      if let path = getProcessPath(for: pid) {
        let lowerPath = path.lowercased()
        let isMediaPlayer = lowerPath.contains("iina") ||
                            lowerPath.contains("vlc") ||
                            lowerPath.contains("quicktime") ||
                            lowerPath.contains("neteasemusic") ||
                            lowerPath.contains("qqmusic") ||
                            lowerPath.contains("tencentvideo") ||
                            lowerPath.contains("youku") ||
                            lowerPath.contains("iqiyi") ||
                            lowerPath.contains("tiktok") ||
                            lowerPath.contains("抖音") ||
                            lowerPath.contains("腾讯视频") ||
                            lowerPath.contains("爱奇艺") ||
                            lowerPath.contains("优酷")
                            
        if isMediaPlayer {
          filteredPids.insert(pid)
        } else {
          log("[Media Filter] Ignored non-media PID: \(pid) (path: \(path))")
        }
      }
    }
    return filteredPids
  }

  private func getProcessPath(for pid: Int) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-p", "\(pid)", "-o", "comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8) {
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    return nil
  }

  private func pauseSystemMedia() {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      
      let playingPids = self.getAudioPlayingPIDs()
      let ourPid = Int(getpid())
      let afplayPid = self.currentPlayProcess?.processIdentifier
      let hasActivePlayback = playingPids.contains { pid in
          return pid != ourPid && (afplayPid == nil || pid != Int(afplayPid!))
      }
      
      if hasActivePlayback {
          self.didPauseMediaViaMediaRemote = true
          self.log("[Media] Active audio playback detected. Will issue MediaRemote Pause.")
          self.sendMediaRemoteCommand(1) // Pause
      } else {
          self.didPauseMediaViaMediaRemote = false
      }
      
      // Execute AppleScript to pause active browser video/audio elements (Safari, Chrome)
      let pauseScript = """
      set pausedApps to ""
      
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
          }
      }
    }
  }

  private func resumeSystemMedia() {
    // Invalidate and clear the monitoring timer on main thread
    DispatchQueue.main.async { [weak self] in
      self?.mediaMonitoringTimer?.invalidate()
      self?.mediaMonitoringTimer = nil
    }

    let appsToResume = self.pausedMediaApps
    self.pausedMediaApps = ""
    
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      
      if self.didPauseMediaViaMediaRemote {
          self.log("[Media] Resuming active playback via MediaRemote Play.")
          self.sendMediaRemoteCommand(0) // Play
          self.didPauseMediaViaMediaRemote = false
      }
      
      if appsToResume.isEmpty { return }
      
      let resumeScript = """
      set pausedApps to "\(appsToResume)"
      
      if pausedApps contains "Music" then
          try
              run script "tell application \\"Music\\" to play"
          end try
      end if
      
      if pausedApps contains "Spotify" then
          try
              run script "tell application \\"Spotify\\" to play"
          end try
      end if
      
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

  func handleDragEntered() {
    log("[Notch] Drag entered")
    hudWindowController?.showHUD()
    hudWindowController?.updateState(state: "draghover", amplitude: 0.0, text: "")
  }

  func handleDragExited() {
    log("[Notch] Drag exited")
    if voiceManager.isListening || currentAskProcess != nil || currentPlayProcess != nil { return }
    hudWindowController?.hideHUD(force: true)
  }

  func handlePerformDrop(_ urls: [URL]) {
    log("[Notch] Perform drop with urls: \(urls)")
    guard let url = urls.first else { return }
    
    if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true) {
      sound.play()
    }
    
    let ext = url.pathExtension.lowercased()
    let filePath = "/tmp/dropped_file.\(ext)"
    let destURL = URL(fileURLWithPath: filePath)
    try? FileManager.default.removeItem(at: destURL)
    try? FileManager.default.copyItem(at: url, to: destURL)
    
    self.currentDroppedFilePath = filePath
    self.isWaitingForDropCommand = true
    self.didPlayDropPrompt = false
    
    hudWindowController?.updateState(state: "dropabsorb", amplitude: 0.0, text: "")
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.startListeningForDropCommand()
    }
  }

  private func startListeningForDropCommand() {
    cancelActiveVoiceOperations()
    
    statusBar.setStatus(.listening)
    hudWindowController?.showHUD()
    hudWindowController?.updateState(state: "listening", amplitude: 0.0, text: "正在倾听指令...")
    pauseSystemMedia()

    voiceManager.amplitudeUpdateHandler = { [weak self] amp in
      self?.hudWindowController?.updateState(state: "listening", amplitude: amp, text: "正在倾听指令...")
    }

    if !didPlayDropPrompt {
      voiceManager.onNoSpeechTimeout = { [weak self] in
        self?.handleDropCommandTimeout()
      }
    } else {
      voiceManager.onNoSpeechTimeout = { [weak self] in
        self?.cancelWaitingForDropCommand()
      }
    }

    voiceManager.startListening { [weak self] text in
      guard let s = self else { return }
      s.voiceManager.onNoSpeechTimeout = nil
      
      guard s.isWaitingForDropCommand else { return }
      
      s.log("[Drop STT] '\(text ?? "nil")'")
      guard let t = text, !t.isEmpty else {
        s.cancelWaitingForDropCommand()
        return
      }
      
      s.processDropCommand(t)
    }
  }

  private func handleDropCommandTimeout() {
    didPlayDropPrompt = true
    self.tts("我已经收到您的文件了，请问您需要我做什么？")
  }

  private func processDropCommand(_ command: String) {
    guard let filePath = currentDroppedFilePath else { return }
    isWaitingForDropCommand = false
    
    let url = URL(fileURLWithPath: filePath)
    let fileName = url.lastPathComponent
    
    statusBar.setStatus(.sending)
    hudWindowController?.updateState(state: "thinking", amplitude: 0.0, text: "Thinking...")
    pauseSystemMedia()
    
    let prompt = "我往你的刘海拖入了一个文件，该文件已保存在本地路径：\(filePath) (原文件名: \(fileName))。关于这个文件，我的指令是：\"\(command)\"。请读取文件内容并执行该指令，然后直接用语音简要回答我。"
    processVoice(prompt)
  }

  private func cancelWaitingForDropCommand() {
    isWaitingForDropCommand = false
    statusBar.setStatus(.idle)
    hudWindowController?.hideHUD(force: true) { [weak self] in
      self?.resumeSystemMedia()
    }
  }
}
