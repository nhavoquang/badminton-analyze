import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A video picked from Photos, copied into a temporary file we own.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return Self(url: dst)
        }
    }
}

struct NewMatchView: View {
    @EnvironmentObject private var store: MatchStore
    @Environment(\.dismiss) private var dismiss

    @State private var pick: PhotosPickerItem?
    @State private var video: URL?
    @State private var loading = false
    @State private var length: Double = 0
    @State private var start: Double = 0
    @State private var clip: Double = 30
    @State private var title = ""
    @State private var kind: MatchKind = .doubles
    @State private var names: [PlayerSlot: String] = [:]
    @State private var layers: Set<OverlayLayer> = [.feet, .path, .hits, .speed]
    @AppStorage("markCourt") private var manualCourt = true
    @AppStorage("lastCourtMarks") private var lastMarks = ""  // the phone often stands in the same spot
    @State private var marks: [CGPoint] = [CGPoint(x: 0.35, y: 0.35), CGPoint(x: 0.65, y: 0.35),
                                           CGPoint(x: 0.85, y: 0.6), CGPoint(x: 0.15, y: 0.6)]

    private let clipChoices: [Double] = [15, 30, 60, 0]  // 0 = whole video

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $pick, matching: .videos, preferredItemEncoding: .current) {
                        ZStack {
                            if let video {
                                VideoThumbnail(url: video, time: start)
                            } else {
                                Rectangle().fill(Color(.tertiarySystemFill))
                                Label(loading ? "Đang tải video…" : "Chọn video từ Ảnh", systemImage: "video.badge.plus")
                                    .font(.headline)
                            }
                        }
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                if video != nil, length > 0 {
                    Section {
                        Picker("Độ dài đoạn", selection: $clip) {
                            ForEach(clipChoices, id: \.self) { c in
                                Text(c == 0 ? "Cả video" : "\(Int(c)) giây").tag(c)
                            }
                        }
                        if clip > 0, length > clip {
                            VStack(alignment: .leading) {
                                Text("Bắt đầu từ \(format(start))")
                                Slider(value: $start, in: 0...(length - clip), step: 1)
                            }
                        }
                    } header: {
                        Text("Đoạn phân tích")
                    } footer: {
                        Text("Video dài \(format(length)). Đoạn càng ngắn thì phân tích càng nhanh.")
                    }
                }

                Section("Tên trận") {
                    TextField("Ví dụ: Đôi nam tối thứ Năm", text: $title)
                }

                Section("Kiểu trận") {
                    Picker("Kiểu trận", selection: $kind) {
                        ForEach(MatchKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Người chơi") {
                    ForEach(kind.slots) { slot in
                        HStack(spacing: 12) {
                            PlayerDot(color: slot.color)
                            TextField(slot.placeholder, text: binding(for: slot))
                            Text(slot.position).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    ForEach(OverlayLayer.allCases) { layer in
                        Toggle(layer.title, isOn: Binding(
                            get: { layers.contains(layer) },
                            set: { on in if on { layers.insert(layer) } else { layers.remove(layer) } }
                        ))
                    }
                } header: {
                    Text("Vẽ lên video")
                } footer: {
                    Text("Âm thanh gốc luôn được giữ trong video kết quả.")
                }
            }
            .navigationTitle("Trận mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    NavigationLink("Tiếp") { CourtConfirmView(video: video, start: start, manual: $manualCourt, marks: $marks, onStart: begin) }
                        .disabled(video == nil)
                }
            }
            .onChange(of: pick) { _, item in Task { await load(item) } }
            .onAppear {
                if let saved = try? JSONDecoder().decode([[Double]].self, from: Data(lastMarks.utf8)), saved.count == 4 {
                    marks = saved.map { CGPoint(x: $0[0], y: $0[1]) }
                }
            }
        }
    }

    private func binding(for slot: PlayerSlot) -> Binding<String> {
        Binding(get: { names[slot] ?? "" }, set: { names[slot] = $0 })
    }

    private func format(_ s: Double) -> String {
        Duration.seconds(s).formatted(.time(pattern: .minuteSecond))
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loading = true
        defer { loading = false }
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return }
        video = movie.url
        let d = (try? await AVURLAsset(url: movie.url).load(.duration).seconds) ?? 0
        length = d.isFinite ? d : 0
        start = 0
    }

    private func begin() {
        guard let video else { return }
        let useClip = clip > 0 && length > clip
        var picked: [String: String] = [:]
        for slot in kind.slots { if let n = names[slot], !n.isEmpty { picked[slot.rawValue] = n } }
        let draft = Match(
            title: title.isEmpty ? "\(kind.title) · \(Date().formatted(.dateTime.day().month()))" : title,
            kind: kind,
            names: picked,
            layers: OverlayLayer.allCases.filter(layers.contains),
            clipStart: useClip ? start : nil,
            clipDuration: useClip ? clip : nil,
            court: manualCourt ? marks.map { [Double($0.x), Double($0.y)] } : nil
        )
        if manualCourt, let data = try? JSONEncoder().encode(marks.map { [Double($0.x), Double($0.y)] }) {
            lastMarks = String(decoding: data, as: UTF8.self)
        }
        store.start(draft, video: video)
        dismiss()
    }
}

/// The user marks the court on a frame of the video (or leaves it to automatic detection) before uploading.
struct CourtConfirmView: View {
    var video: URL?
    var start: Double
    @Binding var manual: Bool
    @Binding var marks: [CGPoint]
    var onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Cách nhận diện sân", selection: $manual) {
                Text("Tự chấm sân").tag(true)
                Text("Tự động").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            if manual {
                CourtMarkView(video: video, time: start, marks: $marks)
                    .padding(.horizontal)
                Text("Kéo **1** và **2** vào hai góc cuối sân phía bên kia lưới, **3** và **4** vào chân hai cột lưới. Khung vàng phải trùng với vạch sân.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
            } else {
                VideoThumbnail(url: video, time: start)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                Text("Hợp với video quay từ sau sân, thấy đủ 4 góc sân. Với video quay từ góc sân bằng điện thoại, hãy dùng Tự chấm sân.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
            }

            Button(action: onStart) {
                Text("Bắt đầu phân tích").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sân đấu")
        .navigationBarTitleDisplayMode(.inline)
    }
}
