import Foundation

struct JobOptions: Encodable {
    var start: Double?
    var duration: Double?
    var layers: [String]
    var names: [String: String]
    var court: [[Double]]?
}

struct JobStatus: Decodable {
    var id: String
    var status: String
    var step: String?
    var progress: Double
    var error: String?
}

enum APIError: LocalizedError {
    case badServer
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badServer: return "Địa chỉ máy chủ chưa đúng. Kiểm tra trong Cài đặt."
        case let .http(code, msg): return "Máy chủ báo lỗi \(code): \(msg)"
        }
    }
}

/// Talks to the Python analysis server (backend/server.py).
struct APIClient {
    var base: URL

    init(baseString: String) throws {
        guard let url = URL(string: baseString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else { throw APIError.badServer }
        base = url
    }

    func createJob(video: URL, options: JobOptions) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }

        // Stream the multipart body to disk so large videos never sit in memory.
        let out = try FileHandle(forWritingTo: body)
        let optionsJSON = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"options\"\r\n\r\n\(optionsJSON)\r\n".utf8))
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"\(video.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: video)
        while true {
            let chunk = try input.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            out.write(chunk)
        }
        try input.close()
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        var req = URLRequest(url: base.appendingPathComponent("jobs"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: body)
        try check(resp, data)
        struct Created: Decodable { var id: String }
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    func status(_ id: String) async throws -> JobStatus {
        let (data, resp) = try await URLSession.shared.data(from: base.appendingPathComponent("jobs/\(id)"))
        try check(resp, data)
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }

    func stats(_ id: String) async throws -> MatchStats {
        let (data, resp) = try await URLSession.shared.data(from: base.appendingPathComponent("jobs/\(id)/stats"))
        try check(resp, data)
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(MatchStats.self, from: data)
    }

    func downloadVideo(_ id: String, to dst: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: base.appendingPathComponent("jobs/\(id)/video"))
        try check(resp, Data())
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}
