import AVKit
import Photos
import SwiftUI

/// Black, Photos-style screen with the annotated video and the players' numbers.
struct ResultView: View {
    var match: Match
    @State private var player: AVPlayer?
    @State private var showExport = false

    private var summary: [PlayerSummary] { match.stats?.summary ?? [] }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(match.layers) { layer in
                            Text(layer.short)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .frame(height: 32)
                                .background(Color.white.opacity(0.14), in: Capsule())
                        }
                    }
                    .padding(.horizontal)
                }

                VStack(spacing: 0) {
                    ForEach(Array(summary.enumerated()), id: \.element.id) { i, p in
                        HStack(spacing: 12) {
                            PlayerDot(color: p.color)
                            Text(p.name)
                            Spacer()
                            Text("Tối đa \(p.maxSpeedKmh.oneDecimal) km/h")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .frame(height: 44)
                        .padding(.horizontal, 16)
                        if i < summary.count - 1 { Divider().padding(.leading, 38) }
                    }
                }
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)

                NavigationLink {
                    StatsView(match: match)
                } label: {
                    Text("Xem thống kê").font(.headline).frame(maxWidth: .infinity).frame(height: 50)
                        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationTitle(match.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Xuất và chia sẻ")
            }
        }
        .sheet(isPresented: $showExport) { ExportView(match: match).presentationDetents([.medium]) }
        .onAppear { if player == nil { player = AVPlayer(url: match.resultURL) } }
        .onDisappear { player?.pause() }
    }
}

struct ExportView: View {
    var match: Match
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { Task { await saveToPhotos() } } label: {
                        Label("Lưu vào Ảnh", systemImage: "photo.on.rectangle")
                    }
                    ShareLink(item: match.resultURL) {
                        Label("Chia sẻ…", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(message ?? "Video 1080p kèm âm thanh gốc.")
                }
            }
            .navigationTitle("Xuất video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Xong") { dismiss() } } }
        }
    }

    private func saveToPhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Hãy cho phép app lưu vào Ảnh trong Cài đặt."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: match.resultURL)
            }
            message = "Đã lưu vào Ảnh."
        } catch {
            message = error.localizedDescription
        }
    }
}
