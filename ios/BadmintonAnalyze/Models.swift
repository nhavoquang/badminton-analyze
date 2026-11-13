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

    var defaultTint: PlayerTint {
        switch self {
        case .near0: return .blue
        case .near1: return .orange
        case .far0: return .green
        case .far1: return .pink
        }
    }

    /// The colour the user picked for this position (remembered between matches).
    var tint: PlayerTint { PlayerTint.saved[self] ?? defaultTint }
    var color: Color { tint.color }
    func color(in map: [String: String]?) -> Color {
        (map?[rawValue]).flatMap(PlayerTint.init(rawValue:))?.color ?? color
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

/// A small, calm palette taken from the iOS system colours (dark-mode values, they read best on video).
enum PlayerTint: String, Codable, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, white
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return "Xanh dương"
        case .indigo: return "Chàm"
        case .purple: return "Tím"
        case .pink: return "Hồng"
        case .red: return "Đỏ"
        case .orange: return "Cam"
        case .yellow: return "Vàng"
        case .green: return "Xanh lá"
        case .mint: return "Bạc hà"
        case .white: return "Trắng"
        }
    }

    var hex: String {
        switch self {
        case .blue: return "#0A84FF"
        case .indigo: return "#5E5CE6"
        case .purple: return "#BF5AF2"
        case .pink: return "#FF375F"
        case .red: return "#FF453A"
        case .orange: return "#FF9F0A"
        case .yellow: return "#FFD60A"
        case .green: return "#30D158"
        case .mint: return "#63E6E2"
        case .white: return "#F2F2F7"
        }
    }

    var color: Color {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// A filled dot that keeps its colour inside menus (menus otherwise draw icons in one tint).
    var swatch: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { _ in
            UIColor(color).setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 16, height: 16)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    static let storageKey = "playerTints"
    static var saved: [PlayerSlot: PlayerTint] {
        guard let s = UserDefaults.standard.string(forKey: storageKey),
              let raw = try? JSONDecoder().decode([String: String].self, from: Data(s.utf8)) else { return [:] }
        var out: [PlayerSlot: PlayerTint] = [:]
        for (k, v) in raw { if let slot = PlayerSlot(rawValue: k), let t = PlayerTint(rawValue: v) { out[slot] = t } }
        return out
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
    var hits: Int?
    var fastestShotKmh: Double?
}

struct HitEvent: Codable, Hashable {
    var t: Double
    var player: String
    var kmh: Double?
}

struct MatchStats: Codable, Hashable {
    var players: [PlayerStats]
    var hits: [HitEvent]?

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
                    hits: rows.reduce(0) { $0 + ($1.hits ?? 0) },
                    fastestShotKmh: rows.compactMap(\.fastestShotKmh).max(),
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
    var hits: Int
    var fastestShotKmh: Double?
    var zones: Zones
    var colors: [String: String]? = nil
    var color: Color { slot?.color(in: colors) ?? .gray }
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
    /// 4 court marks as fractions of the frame (see CourtModel.marks); nil = automatic detection.
    var court: [[Double]]? = nil
    var seed: MatchSeed? = nil
    /// Slot -> PlayerTint raw value, as picked for this match.
    var colors: [String: String]? = nil
    var jobID: String?
    var status: MatchStatus = .uploading
    var progress: Double = 0
    var step: String?
    var error: String?
    var stats: MatchStats?

    var folder: URL { MatchStore.documents.appendingPathComponent(id.uuidString, isDirectory: true) }
    var sourceURL: URL { folder.appendingPathComponent("source.mov") }
    var resultURL: URL { folder.appendingPathComponent("result.mp4") }
    /// Same video without the stat cards at the bottom (the player can collapse them).
    var plainURL: URL { folder.appendingPathComponent("result_plain.mp4") }
    var hasPlain: Bool { FileManager.default.fileExists(atPath: plainURL.path) }
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

    var playerSummary: [PlayerSummary] {
        (stats?.summary ?? []).map { var p = $0; p.colors = colors; return p }
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
