import Foundation

class APIClient: NSObject {
  private let baseURL = "http://127.0.0.1:8765"
  private var statusCallback: ((AppStatus) -> Void)?

  func fetchStatus() {
    let url = URL(string: "\(baseURL)/health")!
    URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
      DispatchQueue.main.async {
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
          NotificationCenter.default.post(name: .init("OpenCodexStatusChanged"), object: AppStatus.idle)
        } else {
          NotificationCenter.default.post(name: .init("OpenCodexStatusChanged"), object: AppStatus.offline)
        }
      }
    }.resume()
  }

  func sendVoice(_ text: String, completion: @escaping (Bool) -> Void) {
    var req = URLRequest(url: URL(string: "\(baseURL)/api/voice")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])

    URLSession.shared.dataTask(with: req) { _, response, _ in
      DispatchQueue.main.async {
        completion((response as? HTTPURLResponse)?.statusCode == 200)
      }
    }.resume()
  }

  func restartCodex() {
    var req = URLRequest(url: URL(string: "\(baseURL)/api/restart-codex")!)
    req.httpMethod = "POST"
    URLSession.shared.dataTask(with: req).resume()
  }
}
