import SwiftUI
import UIKit

/// Screenshot mode for CI: launch with `-demoScreen court-manual|court-auto|export-done`.
/// Uses a drawn sample frame and canned preview data, no server needed.
enum Demo {
    static let screen = UserDefaults.standard.string(forKey: "demoScreen")
    static var frame: UIImage? { screen == nil ? nil : UIImage(named: "DemoFrame") }
    static let marks = [CGPoint(x: 0.5590, y: 0.5752), CGPoint(x: 0.9497, y: 0.5830),
                        CGPoint(x: 0.8090, y: 0.6348), CGPoint(x: 0.2483, y: 0.6074)]

    static func preview(manual: Bool, marks: [CGPoint]) -> PreviewResult {
        let players = [
            PreviewPlayer(slot: "far0", box: [0.5111, 0.5335, 0.5431, 0.5964]),
            PreviewPlayer(slot: "far1", box: [0.704, 0.5236, 0.7397, 0.594]),
            PreviewPlayer(slot: "near0", box: [0.1572, 0.5626, 0.1945, 0.6361]),
            PreviewPlayer(slot: "near1", box: [0.3838, 0.5533, 0.4451, 0.6739]),
        ]
        var lines: [[[Double]]] = []
        if !manual, let h = Homography(from: CourtModel.marks, to: Self.marks) {
            for (a, b) in CourtModel.segments {
                lines.append((0...20).compactMap { i in
                    let t = CGFloat(i) / 20
                    return h.apply(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)).map { [Double($0.x), Double($0.y)] }
                })
            }
        }
        return PreviewResult(mode: manual ? "manual" : "auto", court: manual ? nil : lines, players: players, message: nil)
    }

    @ViewBuilder static var root: some View {
        switch screen {
        case "court-manual", "court-auto":
            DemoCourt(manual: screen == "court-manual")
        case "export-done":
            Color(.systemGroupedBackground).ignoresSafeArea()
                .sheet(isPresented: .constant(true)) {
                    ExportView(match: Match(title: "Demo", kind: .doubles, names: [:], layers: []), demoDone: true)
                        .presentationDetents([.medium])
                }
        default:
            EmptyView()
        }
    }
}

private struct DemoCourt: View {
    @State var manual: Bool
    @State private var marks = Demo.marks
    @State private var names: [PlayerSlot: String] = [.near0: "Huy", .near1: "Dũng", .far0: "Vương", .far1: "Vui"]

    var body: some View {
        NavigationStack {
            CourtConfirmView(video: nil, start: 0, length: 14, kind: .doubles,
                             manual: $manual, marks: $marks, names: $names, onStart: {})
        }
    }
}
