import SwiftUI

struct MatchesView: View {
    @EnvironmentObject private var store: MatchStore
    @State private var query = ""

    private var filtered: [Match] {
        query.isEmpty ? store.matches : store.matches.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            let working = filtered.filter(\.isWorking)
            if !working.isEmpty {
                Section("Đang xử lý") {
                    ForEach(working) { m in
                        NavigationLink(value: m.id) { ProcessingRow(match: m) }
                    }
                }
            }
            let finished = filtered.filter { !$0.isWorking }
            if !finished.isEmpty {
                Section("Gần đây") {
                    ForEach(finished) { m in
                        NavigationLink(value: m.id) { MatchRow(match: m) }
                    }
                    .onDelete { idx in idx.map { finished[$0].id }.forEach(store.delete) }
                }
            }
        }
        .overlay {
            if store.matches.isEmpty {
                ContentUnavailableView(
                    "Chưa có trận nào",
                    systemImage: "sportscourt",
                    description: Text("Bấm nút + để chọn video trận đấu và bắt đầu phân tích.")
                )
            }
        }
        .navigationTitle("Trận đấu")
        .searchable(text: $query, prompt: "Tìm kiếm")
        .navigationDestination(for: UUID.self) { id in MatchDetailView(id: id) }
    }
}

private struct MatchRow: View {
    var match: Match
    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(url: match.hasResult ? match.resultURL : match.sourceURL)
                .frame(width: 64, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(match.title)
                Text(match.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProcessingRow: View {
    var match: Match
    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(url: match.sourceURL, time: match.clipStart ?? 0)
                .frame(width: 64, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(match.title)
                    Spacer()
                    Text(match.progress.percent).font(.subheadline).foregroundStyle(.secondary)
                }
                ProgressView(value: match.progress)
            }
        }
    }
}

/// Shows progress while the job runs, then the result.
struct MatchDetailView: View {
    @EnvironmentObject private var store: MatchStore
    var id: UUID

    var body: some View {
        if let m = store.match(id) {
            if m.status == .done {
                ResultView(match: m)
            } else {
                ProcessingView(match: m)
            }
        } else {
            ContentUnavailableView("Không tìm thấy trận", systemImage: "questionmark")
        }
    }
}
