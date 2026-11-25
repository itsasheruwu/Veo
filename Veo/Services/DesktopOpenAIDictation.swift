import Foundation

@MainActor
enum DesktopOpenAIDictation {
    static let credentialID = "dictation-openai"

    static func transcribe(
        _ audio: URL, key: String, stream: Bool, onPartial: (String) -> Void
    ) async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n".utf8)
        if stream {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"stream\"\r\n\r\ntrue\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: audio))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        if !stream {
            let (data, response) = try await session.data(for: request)
            try check(response)
            guard let text = try JSONDecoder().decode(Transcript.self, from: data).text else { throw Failure.incomplete }
            return text
        }
        let (bytes, response) = try await session.bytes(for: request)
        try check(response)
        var partial = ""
        for try await line in bytes.lines where line.hasPrefix("data:") {
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { break }
            let event = try JSONDecoder().decode(Transcript.self, from: Data(data.utf8))
            switch event.type {
            case "transcript.text.delta":
                partial += event.delta ?? ""
                onPartial(partial)
            case "transcript.text.done":
                guard let text = event.text else { throw Failure.incomplete }
                return text
            case "error": throw Failure.incomplete
            default: break
            }
        }
        throw Failure.incomplete
    }

    private static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.incomplete }
        guard (200..<300).contains(status) else { throw Failure.http(status) }
    }

    private struct Transcript: Decodable {
        var type: String?
        var text: String?
        var delta: String?
    }

    private enum Failure: LocalizedError {
        case incomplete, http(Int)

        var errorDescription: String? {
            switch self {
            case .incomplete: "OpenAI did not return a complete transcript."
            case .http(401), .http(403): "OpenAI rejected the API key. Check the key in Voice settings."
            case .http(429): "OpenAI transcription reached a rate or usage limit. Check your OpenAI API account."
            case .http(let status): "OpenAI transcription failed (HTTP \(status))."
            }
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
