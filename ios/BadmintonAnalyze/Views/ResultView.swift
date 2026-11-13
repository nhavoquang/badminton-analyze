import AVKit
import Photos
import SwiftUI

/// Black, Photos-style screen with the annotated video and the players' numbers.
struct ResultView: View {
    var match: Match
    @State private var player: AVPlayer?
    @State private var showExport = false
    @State private var aspect: CGFloat = 9 / 16
    @AppStorage("showStatCards") private var showCards = true

    private var videoURL: URL { showCards || !match.hasPlain ? match.resultURL : match.plainURL }

    private var summary: [PlayerSummary] { match.playerSummary }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxHeight: 560)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)

                if match.hasPlain {
                    Button {
                        withAnimation(.snappy) { showCards.toggle() }
                        swapVideo()
                    } label: {
                        Label(showCards ? "Ẩn thẻ số liệu" : "Hiện thẻ số liệu",
                              systemImage: showCards ? "chevron.down" : "chevron.up")
                            .font(.subheadline.weight(.medium))
                            .contentTransition(.symbolEffect(.replace))
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: showCards)
                }

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
        .sheet(isPresented: $showExport) { ExportView(match: match, url: videoURL).presentationDetents([.medium]) }
        .onAppear { if player == nil { player = AVPlayer(url: videoURL) } }
        .task { await loadAspect() }
        .onDisappear { player?.pause() }
    }
}

private extension ResultView {
    /// Switch between the video with and without the stat cards, keeping the position and play state.
    func swapVideo() {
        guard let player else { return }
        let t = player.currentTime(), playing = player.rate > 0
        player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in if playing { player.play() } }
    }

    /// Portrait phone videos should fill the screen height, not sit in a 16:9 box.
    func loadAspect() async {
        guard let track = try? await AVURLAsset(url: match.resultURL).loadTracks(withMediaType: .video).first,
              let (size, t) = try? await track.load(.naturalSize, .preferredTransform) else { return }
        let r = size.applying(t)
        if abs(r.width) > 0, abs(r.height) > 0 { aspect = abs(r.width) / abs(r.height) }
    }
}

struct ExportView: View {
    var match: Match
    var url: URL? = nil
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
                    ShareLink(item: url ?? match.resultURL) {
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
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url ?? match.resultURL)
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
