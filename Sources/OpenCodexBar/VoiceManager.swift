import AVFoundation
import Speech

struct VoiceSettings: Decodable {
  var stt_engine: String?
  var stt_api_key: String?
  var stt_base_url: String?
  var stt_model: String?
  var tts_engine: String?
  var tts_api_key: String?
  var tts_base_url: String?
  var tts_model: String?
  var tts_voice: String?
  var vad_threshold: Float?
  var vad_duration: Double?
  var voice_llm_model: String?
  
  static func load() -> VoiceSettings {
    let home = NSHomeDirectory()
    let p = "\(home)/.opencodex/voice_settings.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
          let settings = try? JSONDecoder().decode(VoiceSettings.self, from: data) else {
      return VoiceSettings()
    }
    return settings
  }
}

class VoiceManager: NSObject, AVAudioRecorderDelegate {
  private var recorder: AVAudioRecorder?
  private var completionHandler: ((String?) -> Void)?
  private let fileURL = URL(fileURLWithPath: "/tmp/stt_input.m4a")

  // Voice Activity Detection (VAD) properties
  private var silenceTimer: Timer?
  private var meteringTimer: Timer?
  private var lowVolumeDuration: TimeInterval = 0.0
  private var silenceThreshold: Float = -42.0 // Configured dynamically
  private var requiredSilenceDuration: TimeInterval = 1.5 // Configured dynamically
  private var hasSpeechStarted = false
  
  var amplitudeUpdateHandler: ((Float) -> Void)?

  var isListening: Bool {
    return recorder?.isRecording ?? false
  }

  override init() {
    super.init()
  }

  private func getOpenApiKey() -> String {
    let p = "/Users/aitabby/.opencodex/providers.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return "sk-LyjwiyqgDyyhQ5xhy8a9bALhtI7irtDHusLvy6o58qRFCdDQCajHNxIs4tmYK6ug"
    }
    for item in json {
      if let name = item["name"] as? String, name == "opencode", let key = item["api_key"] as? String {
        return key
      }
    }
    return "sk-LyjwiyqgDyyhQ5xhy8a9bALhtI7irtDHusLvy6o58qRFCdDQCajHNxIs4tmYK6ug"
  }

  func startListening(completion: @escaping (String?) -> Void) {
    AppDelegate.shared?.log("[VM] startListening called")
    completionHandler = completion
    
    // Load dynamic voice settings
    let voiceSettings = VoiceSettings.load()
    self.silenceThreshold = voiceSettings.vad_threshold ?? -42.0
    self.requiredSilenceDuration = voiceSettings.vad_duration ?? 1.5
    AppDelegate.shared?.log("[VM] Loaded settings: STT = \(voiceSettings.stt_engine ?? "local-whisper"), TTS = \(voiceSettings.tts_engine ?? "edge-tts")")
    
    // Configure audio recording settings (AAC compressed M4A)
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    do {
      try? FileManager.default.removeItem(at: fileURL)
      
      recorder = try AVAudioRecorder(url: fileURL, settings: settings)
      recorder?.delegate = self
      recorder?.isMeteringEnabled = true // Enable decibel metering for VAD
      
      let prepared = recorder?.prepareToRecord() ?? false
      let started = recorder?.record() ?? false
      AppDelegate.shared?.log("[VM] Recorder prep: \(prepared), record start: \(started)")
      
      if !started {
        AppDelegate.shared?.log("[VM Err] Recorder failed to start recording!")
        completion(nil)
        return
      }
      
      // Start real-time Voice Activity Detection (VAD) silence monitoring
      lowVolumeDuration = 0.0
      hasSpeechStarted = false
      silenceTimer?.invalidate()
      
      var ticksCount = 0
      var logCounter = 0
      silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        guard let self = self, let rec = self.recorder, rec.isRecording else { return }
        ticksCount += 1
        
        rec.updateMeters()
        var power = rec.averagePower(forChannel: 0)
        
        // Anti-Acoustic Feedback Loop: If the AI is currently playing TTS speech, treat it as silence
        if let appDelegate = AppDelegate.shared, appDelegate.currentPlayProcess != nil {
          power = -100.0
        }
        
        logCounter += 1
        if logCounter % 10 == 0 {
          AppDelegate.shared?.log("[VM Timer] Tick: power = \(power) dB, hasSpeechStarted = \(self.hasSpeechStarted), lowVolumeDuration = \(self.lowVolumeDuration)")
        }
        
        // Ignore decibel checks during the first 0.4 seconds (warmup blanking window to avoid hardware clicks/pops)
        if ticksCount < 4 {
          self.hasSpeechStarted = false
          self.lowVolumeDuration = 0.0
          return
        }
        
        if power >= self.silenceThreshold {
          if !self.hasSpeechStarted {
            AppDelegate.shared?.log("[VAD] Speech started! Power: \(power) dB (Threshold: \(self.silenceThreshold) dB)")
          }
          self.hasSpeechStarted = true
          self.lowVolumeDuration = 0.0 // Reset duration since speech is active
        } else {
          if self.hasSpeechStarted {
            self.lowVolumeDuration += 0.1
          }
        }
        
        // Auto-stop recording if user stops speaking for silence duration
        if self.lowVolumeDuration >= self.requiredSilenceDuration {
          AppDelegate.shared?.log("[VAD] Silence detected for \(self.requiredSilenceDuration)s, auto-stopping...")
          self.stopListening()
        }
      }
      
      // Start high-frequency (33ms) visualizer metering timer
      self.meteringTimer?.invalidate()
      self.meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
        guard let self = self, let rec = self.recorder, rec.isRecording else { return }
        rec.updateMeters()
        var power = rec.averagePower(forChannel: 0)
        
        // Anti-Acoustic Feedback Loop: If the AI is currently playing TTS speech, treat it as silence
        if let appDelegate = AppDelegate.shared, appDelegate.currentPlayProcess != nil {
          power = -100.0
        }
        let minDb: Float = -60.0
        let maxDb: Float = -10.0
        let clamped = max(minDb, min(maxDb, power))
        let amplitude = (clamped - minDb) / (maxDb - minDb)
        self.amplitudeUpdateHandler?(amplitude)
      }
      
      // Safety net: Auto-stop after 25 seconds of continuous recording to protect resources
      DispatchQueue.global().asyncAfter(deadline: .now() + 25) { [weak self] in
        guard let self = self, self.isListening else { return }
        AppDelegate.shared?.log("[VAD] Max recording limit (25s) reached, auto-stopping...")
        self.stopListening()
      }
      
    } catch {
      AppDelegate.shared?.log("[VM Err] Failed to initialize recorder: \(error.localizedDescription)")
      completion(nil)
    }
  }

  func stopListening() {
    AppDelegate.shared?.log("[VM] stopListening called, isListening = \(isListening)")
    guard isListening else { return }
    silenceTimer?.invalidate()
    silenceTimer = nil
    meteringTimer?.invalidate()
    meteringTimer = nil
    recorder?.stop()
  }

  // MARK: - AVAudioRecorderDelegate
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    AppDelegate.shared?.log("[VM] audioRecorderDidFinishRecording success = \(flag)")
    silenceTimer?.invalidate()
    silenceTimer = nil
    meteringTimer?.invalidate()
    meteringTimer = nil
    
    // Immediately show "Thinking..." status on the HUD as soon as recording finishes/transcription begins
    DispatchQueue.main.async {
      AppDelegate.shared?.hudWindowController?.updateState(state: "thinking", amplitude: 0.0, text: "思考中...")
      AppDelegate.shared?.statusBar.setStatus(.sending)
    }
    
    guard flag else {
      DispatchQueue.main.async { [weak self] in
        self?.completionHandler?(nil)
        self?.completionHandler = nil
      }
      return
    }

    // Delegate transcription completely to Node.js server voice API
    AppDelegate.shared?.log("[VM] Delegating speech file to local server STT endpoint...")
    guard let fileData = try? Data(contentsOf: fileURL) else {
      AppDelegate.shared?.log("[VM Err] Failed to read audio file at \(fileURL.path)")
      DispatchQueue.main.async { [weak self] in
        self?.completionHandler?(nil)
        self?.completionHandler = nil
      }
      return
    }

    var request = URLRequest(url: URL(string: "http://localhost:8765/api/voice/stt")!)
    request.httpMethod = "POST"
    request.httpBody = fileData
    request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")

    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      if let error = error {
        AppDelegate.shared?.log("[VM Server STT Err] Network error: \(error.localizedDescription)")
        DispatchQueue.main.async {
          self?.completionHandler?(nil)
          self?.completionHandler = nil
        }
        return
      }

      guard let data = data else {
        AppDelegate.shared?.log("[VM Server STT Err] Empty server response")
        DispatchQueue.main.async {
          self?.completionHandler?(nil)
          self?.completionHandler = nil
        }
        return
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let text = json["text"] as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        AppDelegate.shared?.log("[VM Server STT Result] Transcribed: '\(trimmed)'")
        DispatchQueue.main.async {
          self?.completionHandler?(trimmed.isEmpty ? nil : trimmed)
          self?.completionHandler = nil
        }
      } else {
        let rawStr = String(data: data, encoding: .utf8) ?? ""
        AppDelegate.shared?.log("[VM Server STT Err] Bad JSON response: \(rawStr)")
        DispatchQueue.main.async {
          self?.completionHandler?(nil)
          self?.completionHandler = nil
        }
      }
    }
    task.resume()
  }
}
