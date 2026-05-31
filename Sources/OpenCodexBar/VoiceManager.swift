import Speech
import AVFoundation

class VoiceManager: NSObject, SFSpeechRecognizerDelegate {
  private let speechRecognizer: SFSpeechRecognizer?
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?

  var isListening: Bool { audioEngine.isRunning }

  override init() {
    speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    super.init()
    speechRecognizer?.delegate = self

    // Request permission on init
    SFSpeechRecognizer.requestAuthorization { _ in }
  }

  func startListening(completion: @escaping (String?) -> Void) {
    guard let recognizer = speechRecognizer, recognizer.isAvailable else {
      completion(nil)
      return
    }

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let recognitionRequest = recognitionRequest else { return }

    recognitionRequest.shouldReportPartialResults = false

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
      recognitionRequest.append(buffer)
    }

    audioEngine.prepare()
    try? audioEngine.start()

    recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
      guard let self = self else { return }
      if let result = result {
        completion(result.bestTranscription.formattedString)
      } else if let error = error {
        if (error as NSError).code != 203 { // 203 = no speech detected
          completion(nil)
        }
      }
      self.stopListening()
    }
  }

  func stopListening() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    recognitionTask?.cancel()
    recognitionTask = nil
  }
}
