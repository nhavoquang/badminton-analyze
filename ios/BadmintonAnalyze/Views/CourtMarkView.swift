import SwiftUI

/// Court geometry in metres, same model as the backend (backend/analyzer/court.py).
enum CourtModel {
    static let width = 6.10, length = 13.40
    static let across: [Double] = [0, 0.76, 4.72, 8.68, 12.64, 13.40]
    static let along: [Double] = [0, 0.46, 5.64, 6.10]

    static var segments: [(CGPoint, CGPoint)] {
        var s = across.map { (CGPoint(x: 0, y: $0), CGPoint(x: width, y: $0)) }
        s += along.map { (CGPoint(x: $0, y: 0), CGPoint(x: $0, y: length)) }
        s.append((CGPoint(x: 3.05, y: 0), CGPoint(x: 3.05, y: 4.72)))
        s.append((CGPoint(x: 3.05, y: 8.68), CGPoint(x: 3.05, y: length)))
        return s
    }

    /// Where the four marks sit on the court: the far half, which a phone behind or beside the court always sees.
    static let marks = [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0),
                        CGPoint(x: width, y: length / 2), CGPoint(x: 0, y: length / 2)]
}

/// Perspective transform from 4 point pairs (direct linear solve, h33 = 1).
struct Homography {
    private var h: [Double]

    init?(from src: [CGPoint], to dst: [CGPoint]) {
        var a = [[Double]](), b = [Double]()
        for (p, q) in zip(src, dst) {
            let (x, y, u, v) = (Double(p.x), Double(p.y), Double(q.x), Double(q.y))
            a.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
            a.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
        }
        guard let x = Self.solve(a, b) else { return nil }
        h = x + [1]
    }

    func apply(_ p: CGPoint) -> CGPoint? {
        let (x, y) = (Double(p.x), Double(p.y))
        let w = h[6] * x + h[7] * y + h[8]
        guard w > 1e-6 else { return nil }  // behind the camera
        return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / w, y: (h[3] * x + h[4] * y + h[5]) / w)
    }

    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = zip(a, b).map { $0 + [$1] }
        let n = b.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = m[r][c] / m[c][c]
                for k in c...n { m[r][k] -= f * m[c][k] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }
}

/// A video frame with the court and the players drawn on top. In manual mode the 4 court marks can be dragged.
struct FrameOverlay: View {
    var image: UIImage?
    var editable: Bool
    @Binding var marks: [CGPoint]          // fractions of the frame
    var serverCourt: [[[Double]]]?         // court polylines from the server (automatic mode)
    var players: [PreviewPlayer]
    var name: (String) -> String
    var swapOptions: (String) -> [PlayerSlot]
    var onSwap: (String, PlayerSlot) -> Void

    @State private var dragStart: [CGPoint]?

    var body: some View {
        GeometryReader { geo in
            let size = fitted(in: geo.size)
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable()
                    } else {
                        Rectangle().fill(Color(.tertiarySystemFill)).overlay(ProgressView())
                    }
                }
                .frame(width: size.width, height: size.height)

                Canvas { ctx, _ in
                    ctx.stroke(courtPath(in: size), with: .color(.yellow.opacity(0.9)), lineWidth: 1.5)
                }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)

                let lift = labelLift(size)
                ForEach(players, id: \.self) { p in playerBox(p, in: size, lift: lift[p.slot] ?? 0) }

                if editable {
                    ForEach(marks.indices, id: \.self) { i in
                        MarkHandle(label: "\(i + 1)")
                            .position(x: marks[i].x * size.width, y: marks[i].y * size.height)
                            .gesture(
                                DragGesture()
                                    .onChanged { g in
                                        if dragStart == nil { dragStart = marks }
                                        let s = dragStart![i]
                                        marks[i] = CGPoint(x: min(max(s.x + g.translation.width / size.width, 0), 1),
                                                           y: min(max(s.y + g.translation.height / size.height, 0), 1))
                                    }
                                    .onEnded { _ in dragStart = nil }
                            )
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private func fitted(in box: CGSize) -> CGSize {
        guard box.width > 0, box.height > 0 else { return .zero }
        let ratio = image.map { $0.size.width / max($0.size.height, 1) } ?? 9 / 16
        return box.width / box.height > ratio
            ? CGSize(width: box.height * ratio, height: box.height)
            : CGSize(width: box.width, height: box.width / ratio)
    }

    private func courtPath(in size: CGSize) -> Path {
        var path = Path()
        if editable {
            let pts = marks.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard let h = Homography(from: CourtModel.marks, to: pts) else { return path }
            for (a, b) in CourtModel.segments {
                var last: CGPoint?
                for i in 0...20 {  // short steps, so lines running behind the camera are cut cleanly
                    let t = CGFloat(i) / 20
                    let p = h.apply(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    if let p, let l = last { path.move(to: l); path.addLine(to: p) }
                    last = p
                }
            }
        } else if let lines = serverCourt {
            for line in lines where line.count > 1 {
                path.addLines(line.map { CGPoint(x: $0[0] * size.width, y: $0[1] * size.height) })
            }
        }
        return path
    }

    /// Raise labels that would overlap a neighbour's, so every name stays readable.
    private func labelLift(_ size: CGSize) -> [String: CGFloat] {
        var placed: [(x: CGFloat, y: CGFloat)] = []
        var lift: [String: CGFloat] = [:]
        for p in players.sorted(by: { $0.box[1] > $1.box[1] }) {  // nearest (lowest) first
            let x = (p.box[0] + p.box[2]) / 2 * size.width
            var y = max(p.box[1] * size.height - 16, 12)
            let y0 = y
            while placed.contains(where: { abs($0.x - x) < 90 && abs($0.y - y) < 26 }) { y -= 26 }
            placed.append((x, y)); lift[p.slot] = y0 - y
        }
        return lift
    }

    private func playerBox(_ p: PreviewPlayer, in size: CGSize, lift: CGFloat) -> some View {
        let color = PlayerSlot(rawValue: p.slot)?.color ?? .gray
        let r = CGRect(x: p.box[0] * size.width, y: p.box[1] * size.height,
                       width: (p.box[2] - p.box[0]) * size.width, height: (p.box[3] - p.box[1]) * size.height)
        return ZStack(alignment: .topLeading) {
            Ellipse()
                .stroke(color, lineWidth: 2.5)
                .frame(width: max(r.width * 1.3, 24), height: max(r.width * 0.45, 9))
                .position(x: r.midX, y: r.maxY)
            Menu {
                Section("Người này là") {
                    ForEach(swapOptions(p.slot)) { other in
                        Button(name(other.rawValue)) { onSwap(p.slot, other) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(name(p.slot)).font(.caption.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(.black.opacity(0.7), in: Capsule())
                .overlay(Capsule().stroke(color, lineWidth: 1.5))
                .fixedSize()
            }
            .position(x: r.midX, y: max(r.minY - 16, 12) - lift)
        }
    }
}

private struct MarkHandle: View {
    var label: String
    var body: some View {
        ZStack {
            Circle().fill(.clear).frame(width: 44, height: 44)  // touch target
            Circle().fill(Color.accentColor).frame(width: 24, height: 24)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            Text(label).font(.caption2.bold()).foregroundStyle(.white)
        }
        .contentShape(Circle())
    }
}
