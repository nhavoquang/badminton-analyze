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
                    NavigationLink("Tiếp") { CourtConfirmView(video: video, start: start, length: length, kind: kind,
                                     manual: $manualCourt, marks: $marks, names: $names, onStart: begin) }
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

/// Court setup with a preview: the user checks on a real frame that the court and the player names sit right,
/// for both manual marks and automatic detection, before the video is uploaded.
struct CourtConfirmView: View {
    var video: URL?
    var start: Double
    var length: Double
    var kind: MatchKind
    @Binding var manual: Bool
    @Binding var marks: [CGPoint]
    @Binding var names: [PlayerSlot: String]
    var onStart: () -> Void

    @AppStorage("serverURL") private var serverURL = "http://192.168.1.10:8000"
    @State private var time: Double = 0
    @State private var image: UIImage?
    @State private var result: PreviewResult?
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 12) {
            Picker("Cách nhận diện sân", selection: $manual) {
                Text("Tự chấm sân").tag(true)
                Text("Tự động").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            FrameOverlay(
                image: image,
                editable: manual,
                marks: $marks,
                serverCourt: manual ? nil : result?.court,
                players: result?.players ?? [],
                name: displayName,
                swapOptions: { slot in kind.slots.filter { $0.rawValue != slot } },
                onSwap: swap
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal)

            Text(hint)
                .font(.footnote)
                .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            if length > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "film").foregroundStyle(.secondary)
                    Slider(value: $time, in: 0...length) { editing in
                        if !editing { result = nil }
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: 12) {
                Button { Task { await check() } } label: {
                    HStack(spacing: 6) {
                        if checking { ProgressView() } else { Image(systemName: "eye") }
                        Text("Xem trước")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(checking || image == nil)

                Button(action: onStart) {
                    Text("Phân tích").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .padding(.top, 8)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sân đấu")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if time == 0 { time = start } }
        .onChange(of: manual) { result = nil; problem = nil }
        .onChange(of: marks) { if manual, result != nil { result = nil } }
        .task(id: Int(time * 10)) {
            if let demo = Demo.frame { image = demo; return }
            image = await VideoThumbnail.frame(video, at: time, maxSide: 1280)
        }
        .task {
            if Demo.screen != nil { result = Demo.preview(manual: manual, marks: marks) }
        }
    }

    private var hint: String {
        if let problem { return problem }
        if let r = result {
            if let m = r.message { return m }
            return "Kiểm tra tên trên đầu mỗi người. Sai thì chạm vào tên để đổi."
        }
        return manual
            ? "Kéo 1 và 2 vào hai góc cuối sân bên kia lưới, 3 và 4 vào chân hai cột lưới. Rồi bấm Xem trước."
            : "Bấm Xem trước để xem máy có nhận ra sân và người chơi không."
    }

    private func displayName(_ slot: String) -> String {
        guard let s = PlayerSlot(rawValue: slot) else { return slot }
        let n = names[s] ?? ""
        return n.isEmpty ? s.placeholder : n
    }

    private func swap(_ slot: String, _ other: PlayerSlot) {
        guard let s = PlayerSlot(rawValue: slot) else { return }
        let a = displayName(s.rawValue), b = displayName(other.rawValue)
        names[s] = b; names[other] = a
    }

    private func check() async {
        guard let image, let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        checking = true; problem = nil
        defer { checking = false }
        do {
            let api = try APIClient(baseString: serverURL)
            let court = manual ? marks.map { [Double($0.x), Double($0.y)] } : nil
            result = try await api.preview(frame: jpeg, court: court)
        } catch {
            problem = "Không xem trước được: \(error.localizedDescription)"
        }
    }
}
