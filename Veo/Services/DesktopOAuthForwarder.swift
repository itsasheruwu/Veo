// FILE: DesktopOAuthForwarder.swift
// Purpose: Loopback reverse proxy that refreshes Veo-owned OAuth tokens for Codex app-server.
// Layer: Desktop app service

import Foundation
import Network

final class DesktopOAuthForwarder: @unchecked Sendable {
    static let shared = DesktopOAuthForwarder()

    private struct Route: Sendable {
        var upstream: URL
        var providerID: String
        var preset: DesktopExternalProviderPreset
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let queue = DispatchQueue(label: "com.ash.veo.oauth-forwarder")

    func prepare(providers: [DesktopConnectedProvider]) throws -> [String: String] {
        var nextRoutes: [String: Route] = [:]
        for provider in providers where provider.authKind == .oauth && provider.models.contains(where: \.enabled) {
            guard let preset = provider.preset,
                  let upstream = URL(string: provider.baseURL) else { continue }
            nextRoutes[provider.id] = Route(upstream: upstream, providerID: provider.id, preset: preset)
        }
        lock.lock()
        routes = nextRoutes
        lock.unlock()
        if nextRoutes.isEmpty {
            stop()
            return [:]
        }
        try startIfNeeded()
        let boundPort = currentPort()
        var bases: [String: String] = [:]
        for id in nextRoutes.keys {
            bases[id] = "http://127.0.0.1:\(boundPort)/p/\(id)"
        }
        return bases
    }

    func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        port = 0
        routes = [:]
        lock.unlock()
    }

    private func currentPort() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    private func route(for id: String) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        return routes[id]
    }

    private func startIfNeeded() throws {
        lock.lock()
        if listener != nil, port != 0 {
            lock.unlock()
            return
        }
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        let started = DispatchSemaphore(value: 0)
        var capturedPort: UInt16 = 0
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                capturedPort = listener.port?.rawValue ?? 0
                started.signal()
            case .failed:
                started.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        _ = started.wait(timeout: .now() + 2)
        guard capturedPort != 0 else {
            listener.cancel()
            throw DesktopExternalModelCatalogError.catalogWrite("Veo could not start the local OAuth proxy.")
        }
        lock.lock()
        self.listener = listener
        self.port = capturedPort
        lock.unlock()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            guard let headerRange = next.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || next.count > 2 * 1024 * 1024 {
                    self.fail(connection, status: 400, message: "Bad request")
                } else {
                    self.receive(connection, buffer: next)
                }
                return
            }
            let headerData = next[..<headerRange.lowerBound]
            var body = next[headerRange.upperBound...]
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                self.fail(connection, status: 400, message: "Bad request")
                return
            }
            let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let requestLine = lines.first?.split(separator: " "), requestLine.count >= 2 else {
                self.fail(connection, status: 400, message: "Bad request")
                return
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let split = line.firstIndex(of: ":") else { continue }
                let name = line[..<split].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
                headers[name] = String(value)
            }
            if let length = headers["content-length"].flatMap(Int.init), body.count < length, !isComplete {
                self.receive(connection, buffer: next)
                return
            }
            if let length = headers["content-length"].flatMap(Int.init), body.count > length {
                body = body.prefix(length)
            }
            self.forward(
                method: String(requestLine[0]),
                pathAndQuery: String(requestLine[1]),
                headers: headers,
                body: Data(body),
                connection: connection
            )
        }
    }

    private func forward(
        method: String,
        pathAndQuery: String,
        headers: [String: String],
        body: Data,
        connection: NWConnection
    ) {
        let path = pathAndQuery.split(separator: "?", maxSplits: 1).first.map(String.init) ?? pathAndQuery
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0] == "p", let route = route(for: parts[1]) else {
            fail(connection, status: 404, message: "Unknown OAuth provider")
            return
        }
        let rest = parts.dropFirst(2).joined(separator: "/")
        let query = pathAndQuery.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        var upstream = route.upstream.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !rest.isEmpty { upstream += "/" + rest }
        if !query.isEmpty { upstream += "?" + query }
        guard let url = URL(string: upstream) else {
            fail(connection, status: 502, message: "Invalid upstream")
            return
        }
        Task {
            do {
                let token = try await DesktopProviderOAuth.validAccessToken(
                    providerID: route.providerID,
                    preset: route.preset
                )
                var request = URLRequest(url: url, timeoutInterval: 300)
                request.httpMethod = method
                let outbound = body.isEmpty
                    ? body
                    : DesktopExternalRequestAdapter.sanitize(
                        body: body,
                        path: path,
                        providerID: route.providerID
                    )
                request.httpBody = outbound.isEmpty ? nil : outbound
                for (name, value) in headers {
                    if ["host", "authorization", "content-length", "connection"].contains(name) { continue }
                    request.setValue(value, forHTTPHeaderField: name)
                }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                for (name, value) in DesktopProviderOAuth.extraAPIHeaders(for: route.preset) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                let delegate = StreamDelegate(connection: connection)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: request)
                delegate.session = session
                task.resume()
            } catch {
                self.fail(connection, status: 502, message: "OAuth proxy failed")
            }
        }
    }

    private func fail(_ connection: NWConnection, status: Int, message: String) {
        let body = Data(message.utf8)
        var payload = Data("HTTP/1.1 \(status) Error\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate {
    let connection: NWConnection
    var session: URLSession?
    private var sentHeaders = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        var header = "HTTP/1.1 \(status) OK\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n"
        if let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") {
            header += "Content-Type: \(contentType)\r\n"
        }
        header += "\r\n"
        sentHeaders = true
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let header = String(format: "%x\r\n", data.count)
        var payload = Data(header.utf8)
        payload.append(data)
        payload.append(Data("\r\n".utf8))
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !sentHeaders {
            let message = Data("OAuth proxy failed".utf8)
            var payload = Data("HTTP/1.1 502 Error\r\nContent-Type: text/plain\r\nContent-Length: \(message.count)\r\nConnection: close\r\n\r\n".utf8)
            payload.append(message)
            connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
                self?.session?.finishTasksAndInvalidate()
            })
            return
        }
        connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.session?.finishTasksAndInvalidate()
        })
    }
}
