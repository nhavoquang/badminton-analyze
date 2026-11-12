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

/// The user drags 4 handles onto the court; the full court is drawn live so they can see it lines up.
struct CourtMarkView: View {
    var video: URL?
    var time: Double
    @Binding var marks: [CGPoint]  // fractions of the frame

    @State private var image: UIImage?
    @State private var dragStart: [CGPoint]?

    private static let labels = ["1", "2", "3", "4"]

    var body: some View {
        GeometryReader { geo in
            let size = fittedSize(in: geo.size)
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                } else {
                    Rectangle().fill(Color(.tertiarySystemFill)).frame(width: size.width, height: size.height)
                }
                Canvas { ctx, _ in
                    let pts = marks.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                    guard let h = Homography(from: CourtModel.marks, to: pts) else { return }
                    var path = Path()
                    for (a, b) in CourtModel.segments {
                        // draw in short steps so lines that run behind the camera are cut cleanly
                        var last: CGPoint?
                        for i in 0...20 {
                            let t = CGFloat(i) / 20
                            let p = h.apply(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                            if let p, let l = last { path.move(to: l); path.addLine(to: p) }
                            last = p
                        }
                    }
                    ctx.stroke(path, with: .color(.yellow.opacity(0.9)), lineWidth: 1.5)
                    var net = Path()
                    if let a = h.apply(CourtModel.marks[3]), let b = h.apply(CourtModel.marks[2]) {
                        net.move(to: a); net.addLine(to: b)
                    }
                    ctx.stroke(net, with: .color(.white), lineWidth: 3)
                }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)

                ForEach(marks.indices, id: \.self) { i in
                    handle(Self.labels[i])
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
            .frame(width: size.width, height: size.height)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(video?.path ?? "")-\(time)") {
            image = await VideoThumbnail.frame(video, at: time, maxSide: 1600)
        }
    }

    private func fittedSize(in box: CGSize) -> CGSize {
        let ratio = image.map { $0.size.width / max($0.size.height, 1) } ?? 16 / 9
        return box.width / box.height > ratio
            ? CGSize(width: box.height * ratio, height: box.height)
            : CGSize(width: box.width, height: box.width / ratio)
    }

    private func handle(_ label: String) -> some View {
        ZStack {
            Circle().fill(.clear).frame(width: 44, height: 44)  // touch target
            Circle().stroke(.white, lineWidth: 2).frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.85)))
            Text(label).font(.caption2.bold()).foregroundStyle(.white)
        }
        .contentShape(Circle())
    }
}
