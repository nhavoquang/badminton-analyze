import Foundation
import SwiftUI

@MainActor
final class MatchStore: ObservableObject {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let indexURL = documents.appendingPathComponent("matches.json")

    @Published private(set) var matches: [Match] = []
    @AppStorage("serverURL") var serverURL = "http://192.168.1.10:8000"

    init() {
        load()
        for m in matches where m.isWorking && m.jobID != nil {
            Task { await follow(m.id) }
        }
    }

    func match(_ id: UUID) -> Match? { matches.first { $0.id == id } }

    func delete(_ id: UUID) {
        if let m = match(id) { try? FileManager.default.removeItem(at: m.folder) }
        matches.removeAll { $0.id == id }
        save()
    }

    /// Copy the picked video into the app, upload it and follow the job until the result is downloaded.
    func start(_ draft: Match, video: URL) {
        var m = draft
        do {
            try FileManager.default.createDirectory(at: m.folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: m.sourceURL)
            try FileManager.default.copyItem(at: video, to: m.sourceURL)
        } catch {
            m.status = .failed
            m.error = error.localizedDescription
        }
        matches.insert(m, at: 0)
        save()
        guard m.status != .failed else { return }
        Task { await upload(m.id) }
    }

    func retry(_ id: UUID) {
        update(id) { $0.status = .uploading; $0.error = nil; $0.progress = 0 }
        Task {
            // Keep following a job the server still runs; otherwise (server restarted, job failed) upload again.
            if let job = match(id)?.jobID,
               let api = try? APIClient(baseString: serverURL),
               let s = try? await api.status(job), s.status != "failed" {
                await follow(id)
            } else {
                update(id) { $0.jobID = nil }
                await upload(id)
            }
        }
    }

    private func upload(_ id: UUID) async {
        guard let m = match(id) else { return }
        do {
            let api = try APIClient(baseString: serverURL)
            let opts = JobOptions(start: m.clipStart, duration: m.clipDuration,
                                  layers: m.layers.map(\.rawValue), names: m.names)
            let job = try await api.createJob(video: m.sourceURL, options: opts)
            update(id) { $0.jobID = job; $0.status = .queued }
            await follow(id)
        } catch {
            update(id) { $0.status = .failed; $0.error = error.localizedDescription }
        }
    }

    private func follow(_ id: UUID) async {
        guard let job = match(id)?.jobID else { return }
        do {
            let api = try APIClient(baseString: serverURL)
            while true {
                let s = try await api.status(job)
                update(id) {
                    $0.progress = s.progress
                    $0.step = s.step
                    $0.status = s.status == "queued" ? .queued : .processing
                }
                if s.status == "failed" { throw APIError.http(500, s.error ?? "phân tích thất bại") }
                if s.status == "done" { break }
                try await Task.sleep(for: .seconds(2))
            }
            update(id) { $0.status = .downloading }
            guard let m = match(id) else { return }
            try await api.downloadVideo(job, to: m.resultURL)
            let stats = try await api.stats(job)
            update(id) { $0.stats = stats; $0.status = .done; $0.progress = 1 }
        } catch {
            update(id) { $0.status = .failed; $0.error = error.localizedDescription }
        }
    }

    private func update(_ id: UUID, _ change: (inout Match) -> Void) {
        guard let i = matches.firstIndex(where: { $0.id == id }) else { return }
        change(&matches[i])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        matches = (try? JSONDecoder().decode([Match].self, from: data)) ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(matches) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }
}
