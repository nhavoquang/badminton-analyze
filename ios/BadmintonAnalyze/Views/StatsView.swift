import SwiftUI

struct StatsView: View {
    var match: Match
    @State private var selected: String?

    private var summary: [PlayerSummary] { match.playerSummary }
    private var current: PlayerSummary? { summary.first { $0.id == selected } ?? summary.first }

    var body: some View {
        List {
            if summary.count > 1 {
                Picker("Người chơi", selection: Binding(get: { current?.id ?? "" }, set: { selected = $0 })) {
                    ForEach(summary) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let p = current {
                Section {
                    HStack(spacing: 12) {
                        Tile(title: "Quãng đường", value: p.distanceM.oneDecimal, unit: "m")
                        Tile(title: "Tốc độ tối đa", value: p.maxSpeedKmh.oneDecimal, unit: "km/h")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section("Vị trí trên sân") {
                    LabeledContent("Gần lưới", value: p.zones.net.percent)
                    LabeledContent("Giữa sân", value: p.zones.mid.percent)
                    LabeledContent("Cuối sân", value: p.zones.back.percent)
                }

                Section {
                    LabeledContent("Số cú đánh", value: "\(p.hits)")
                    LabeledContent("Cú nhanh nhất", value: p.fastestShotKmh.map { "≈ \(Int($0)) km/h" } ?? "–")
                } header: {
                    Text("Cú đánh")
                } footer: {
                    Text("Tốc độ cú đánh là tốc độ trung bình của quả cầu giữa hai người, ước tính từ một camera.")
                }
            } else {
                ContentUnavailableView("Chưa có số liệu", systemImage: "chart.bar")
            }
        }
        .navigationTitle("Thống kê")
    }
}

private struct Tile: View {
    var title: String
    var value: String
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title.bold())
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PlayersView: View {
    @EnvironmentObject private var store: MatchStore

    private var rows: [(name: String, matches: Int, distance: Double, top: Double)] {
        var acc: [String: (Int, Double, Double)] = [:]
        for m in store.matches {
            for p in m.playerSummary {
                let v = acc[p.name] ?? (0, 0, 0)
                acc[p.name] = (v.0 + 1, v.1 + p.distanceM, max(v.2, p.maxSpeedKmh))
            }
        }
        return acc.map { (name: $0.key, matches: $0.value.0, distance: $0.value.1, top: $0.value.2) }
            .sorted { $0.distance > $1.distance }
    }

    var body: some View {
        List(rows, id: \.name) { r in
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name)
                Text("\(r.matches) trận · \(Int(r.distance)) m · tối đa \(r.top.oneDecimal) km/h")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("Chưa có người chơi", systemImage: "person.2",
                                       description: Text("Đặt tên người chơi khi tạo trận mới."))
            }
        }
        .navigationTitle("Người chơi")
    }
}

struct SettingsView: View {
    @AppStorage("serverURL") private var serverURL = "http://192.168.1.10:8000"

    var body: some View {
        Form {
            Section {
                TextField("http://…", text: $serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Máy chủ phân tích")
            } footer: {
                Text("Địa chỉ máy đang chạy backend/server.py, ví dụ máy tính trong cùng mạng Wi-Fi.")
            }
            Section("Ứng dụng") {
                LabeledContent("Phiên bản", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            }
        }
        .navigationTitle("Cài đặt")
    }
}
