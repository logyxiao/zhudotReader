import Foundation

@main struct LANReadingSyncSmoke {
    @MainActor static func main() async throws {
        let server = LANReadingSync()
        var offset = 0
        var available = true
        let snapshot: () -> [String: Any]? = {
            available ? ["title": "测试书", "text": "第一章\n中文😀正文", "version": "v1", "count": 12, "offset": offset, "chapters": []] : nil
        }
        server.start(snapshot: snapshot, progress: { offset = $0 })
        for _ in 0..<100 where server.addresses.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let address = server.addresses.first, let url = URL(string: address), let token = url.fragment else {
            fatalError(server.status)
        }
        let base = "http://127.0.0.1:\(url.port!)"
        func request(_ path: String, token: String? = nil, body: String? = nil) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: base + path)!)
            request.timeoutInterval = 3
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let body { request.httpMethod = "POST"; request.httpBody = Data(body.utf8) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode)
        }
        let page = try await request("/")
        precondition(page.1 == 200 && String(decoding: page.0, as: UTF8.self).contains("竹点阅读"))
        let denied = try await request("/api/book")
        precondition(denied.1 == 403)
        let book = try await request("/api/book", token: token)
        precondition(book.1 == 200 && String(decoding: book.0, as: UTF8.self).contains("中文"))
        let post = try await request("/api/progress", token: token, body: #"{"version":"v1","offset":5}"#)
        precondition(post.1 == 200 && offset == 5)
        let stale = try await request("/api/progress", token: token, body: #"{"version":"old","offset":2}"#)
        precondition(stale.1 == 409 && offset == 5)
        let bounds = try await request("/api/progress", token: token, body: #"{"version":"v1","offset":-1}"#)
        precondition(bounds.1 == 409 && offset == 5)
        offset = 8
        let progress = try await request("/api/progress", token: token)
        let payload = try JSONSerialization.jsonObject(with: progress.0) as! [String: Any]
        precondition(payload["offset"] as? Int == 8 && payload["text"] == nil)
        available = false
        let gone = try await request("/api/book", token: token)
        precondition(gone.1 == 410)
        server.stop()
        precondition(!server.isRunning && server.addresses.isEmpty)
        do { _ = try await request("/api/book", token: token); fatalError("Stopped server accepted request") }
        catch { print("PASS: page, authentication, Unicode, bidirectional progress, stale version, bounds, unavailable book, shutdown") }
    }
}
