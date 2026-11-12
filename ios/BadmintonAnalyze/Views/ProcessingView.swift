import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject private var store: MatchStore
    @Environment(\.dismiss) private var dismiss
    var match: Match

    private var currentIndex: Int {
        guard let step = match.step, let i = AnalysisStep.allCases.firstIndex(where: { $0.rawValue == step }) else { return -1 }
        return i
    }

    var body: some View {
        List {
            Section {
                VideoThumbnail(url: match.sourceURL, time: match.clipStart ?? 0)
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(headline).font(.title2.bold())
                    ProgressView(value: match.progress)
                    HStack {
                        Text(match.progress.percent)
                        Spacer()
                        Text(statusText)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if match.status == .failed {
                Section {
                    Text(match.error ?? "Có lỗi xảy ra.").foregroundStyle(.red)
                    Button("Thử lại") { store.retry(match.id) }
                }
            } else {
                Section {
                    ForEach(Array(AnalysisStep.allCases.enumerated()), id: \.element) { i, step in
                        HStack(spacing: 12) {
                            icon(for: i)
                            Text(step.title).foregroundStyle(i > currentIndex ? .secondary : .primary)
                        }
                    }
                } footer: {
                    Text("Bạn có thể thoát app. Phân tích vẫn chạy trên máy chủ và sẽ tiếp tục khi bạn mở lại.")
                }
            }
        }
        .navigationTitle(match.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Xoá", role: .destructive) { store.delete(match.id); dismiss() }
                    .tint(.red)
            }
        }
    }

    private var headline: String {
        switch match.status {
        case .uploading: return "Đang tải video lên"
        case .queued: return "Đang chờ máy chủ"
        case .downloading: return "Đang tải kết quả về"
        case .failed: return "Phân tích không thành công"
        default: return "Đang phân tích"
        }
    }

    private var statusText: String {
        match.status == .processing ? (AnalysisStep(rawValue: match.step ?? "")?.title ?? "") : ""
    }

    @ViewBuilder private func icon(for i: Int) -> some View {
        if i < currentIndex || match.status == .downloading {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if i == currentIndex {
            ProgressView()
        } else {
            Image(systemName: "circle").foregroundStyle(Color(.tertiaryLabel))
        }
    }
}
