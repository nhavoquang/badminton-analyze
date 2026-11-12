import Foundation
import SwiftUI

enum MatchKind: String, Codable, CaseIterable, Identifiable {
    case singles, doubles
    var id: String { rawValue }
    var title: String { self == .singles ? "Đánh đơn" : "Đánh đôi" }
    var slots: [PlayerSlot] { self == .singles ? [.near0, .far0] : PlayerSlot.allCases }
}

/// Player positions as the analyzer names them: side ("near" = closer to the camera) + slot index.
enum PlayerSlot: String, Codable, CaseIterable, Identifiable {
    case near0, near1, far0, far1
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .near0: return Color(.systemOrange)
        case .near1: return Color(.systemPink)
        case .far0: return Color(.systemPurple)
        case .far1: return Color(.systemTeal)
        }
    }

    var position: String {
        switch self {
        case .near0: return "Gần · trái"
        case .near1: return "Gần · phải"
        case .far0: return "Xa · trái"
        case .far1: return "Xa · phải"
        }
    }

    var placeholder: String {
        switch self {
        case .near0: return "Người chơi 1"
        case .near1: return "Người chơi 2"
        case .far0: return "Người chơi 3"
        case .far1: return "Người chơi 4"
        }
    }
}

enum OverlayLayer: String, Codable, CaseIterable, Identifiable {
    case feet, path, hits, speed, map
    var id: String { rawValue }

    var title: String {
        switch self {
        case .feet: return "Vòng tròn dưới chân"
        case .path: return "Đường bay của cầu"
        case .hits: return "Điểm chạm cầu"
        case .speed: return "Tốc độ di chuyển"
        case .map: return "Sơ đồ sân"
        }
    }

    var short: String {
        switch self {
        case .feet: return "Vòng chân"
        case .path: return "Đường cầu"
        case .hits: return "Điểm chạm"
        case .speed: return "Tốc độ"
        case .map: return "Sơ đồ sân"
        }
    }
}

enum MatchStatus: String, Codable {
    case uploading, queued, processing, downloading, done, failed
}

struct Zones: Codable, Hashable {
    var net: Double
    var mid: Double
    var back: Double
}

/// One player's numbers for one camera shot, as returned by GET /jobs/{id}/stats.
struct PlayerStats: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var side: String
    var shot: Int
    var startS: Double
    var endS: Double
    var maxSpeedKmh: Double
    var avgSpeedKmh: Double
    var distanceM: Double
    var zones: Zones
}

struct MatchStats: Codable, Hashable {
    var players: [PlayerStats]

    /// Combine the per-shot rows into one summary per player.
    var summary: [PlayerSummary] {
        Dictionary(grouping: players, by: \.id)
            .map { id, rows in
                let total = rows.reduce(0) { $0 + ($1.endS - $1.startS) }
                func weighted(_ f: (Zones) -> Double) -> Double {
                    guard total > 0 else { return 0 }
                    return rows.reduce(0) { $0 + f($1.zones) * ($1.endS - $1.startS) } / total
                }
                return PlayerSummary(
                    id: id,
                    name: rows.first?.name ?? id,
                    slot: PlayerSlot(rawValue: id),
                    maxSpeedKmh: rows.map(\.maxSpeedKmh).max() ?? 0,
                    distanceM: rows.reduce(0) { $0 + $1.distanceM },
                    zones: Zones(net: weighted(\.net), mid: weighted(\.mid), back: weighted(\.back))
                )
            }
            .sorted { $0.id < $1.id }
    }
}

struct PlayerSummary: Identifiable, Hashable {
    var id: String
    var name: String
    var slot: PlayerSlot?
    var maxSpeedKmh: Double
    var distanceM: Double
    var zones: Zones
    var color: Color { slot?.color ?? .gray }
}

struct Match: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var kind: MatchKind
    var names: [String: String]
    var layers: [OverlayLayer]
    var clipStart: Double?
    var clipDuration: Double?
    var jobID: String?
    var status: MatchStatus = .uploading
    var progress: Double = 0
    var step: String?
    var error: String?
    var stats: MatchStats?

    var folder: URL { MatchStore.documents.appendingPathComponent(id.uuidString, isDirectory: true) }
    var sourceURL: URL { folder.appendingPathComponent("source.mov") }
    var resultURL: URL { folder.appendingPathComponent("result.mp4") }
    var hasResult: Bool { FileManager.default.fileExists(atPath: resultURL.path) }

    var subtitle: String {
        let d = createdAt.formatted(.dateTime.day().month(.abbreviated))
        switch status {
        case .done: return "\(d) · \(kind.title)"
        case .failed: return "Lỗi: \(error ?? "không rõ")"
        case .uploading: return "Đang tải lên…"
        default: return "Đang phân tích · \(Int(progress * 100))%"
        }
    }

    var isWorking: Bool { ![.done, .failed].contains(status) }
}

enum AnalysisStep: String, CaseIterable, Identifiable {
    case court, players, shuttle, hits, render
    var id: String { rawValue }
    var title: String {
        switch self {
        case .court: return "Nhận diện sân"
        case .players: return "Theo dõi người chơi"
        case .shuttle: return "Theo dõi quả cầu"
        case .hits: return "Tìm điểm chạm"
        case .render: return "Dựng video"
        }
    }
}
