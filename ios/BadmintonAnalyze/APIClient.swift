import Foundation

struct JobOptions: Encodable {
    var start: Double?
    var duration: Double?
    var layers: [String]
    var names: [String: String]
    var court: [[Double]]?
    var seed: MatchSeed?
    /// Slot -> "#RRGGBB" for the overlay.
    var colors: [String: String]?
}

struct JobStatus: Decodable {
    var id: String
    var status: String
    var step: String?
    var progress: Double
    var error: String?
}

struct PreviewPlayer: Decodable, Hashable {
    var slot: String
    var box: [Double]  // x0, y0, x1, y1 as fractions of the frame
    var courtXY: [Double]?  // position on court in metres

    enum CodingKeys: String, CodingKey { case slot, box, courtXY = "court_xy" }
}

/// Who stood where on the frame the user checked; keeps each name on the right player during tracking.
struct MatchSeed: Codable, Hashable {
    var t: Double  // seconds into the analysed clip
    var players: [String: [Double]]
}

/// What the server sees on one frame: court lines (polylines in frame fractions) and player slots.
struct PreviewResult: Decodable {
    var mode: String?
    var court: [[[Double]]]?
    var players: [PreviewPlayer]
    var message: String?
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

    func preview(frame: Data, court: [[Double]]?) async throws -> PreviewResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        struct Options: Encodable { var court: [[Double]]? }
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"options\"\r\n\r\n".utf8))
        body.append(try JSONEncoder().encode(Options(court: court)))
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"frame\"; filename=\"frame.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(frame)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: base.appendingPathComponent("preview"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        try check(resp, data)
        return try JSONDecoder().decode(PreviewResult.self, from: data)
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

    func downloadVideo(_ id: String, to dst: URL, cards: Bool = true) async throws {
        var url = base.appendingPathComponent("jobs/\(id)/video")
        if !cards { url.append(queryItems: [URLQueryItem(name: "cards", value: "0")]) }
        let (tmp, resp) = try await URLSession.shared.download(from: url)
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
