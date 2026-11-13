import AVKit
import Photos
import SwiftUI

/// Black, Photos-style screen with the annotated video and the players' numbers.
struct ResultView: View {
    var match: Match
    @State private var player: AVPlayer?
    @State private var showExport = false

    private var summary: [PlayerSummary] { match.playerSummary }

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
                            Text("\(p.hits) cú · tối đa \(p.maxSpeedKmh.oneDecimal) km/h")
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
    var demoDone = false
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var done: String?

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
            .overlay {
                if let done {
                    DoneHUD(subtitle: done).transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .onAppear { if demoDone { done = "Video đã được lưu vào Ảnh" } }
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
            message = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(duration: 0.35)) { done = "Video đã được lưu vào Ảnh" }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { done = nil }
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Big, centred confirmation like the system "Done" HUD, so a save is impossible to miss.
struct DoneHUD: View {
    var title = "Xong!"
    var subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.white, .green)
                .symbolEffect(.bounce, value: subtitle)
            Text(title).font(.title2.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(minWidth: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .accessibilityElement(children: .combine)
    }
}
