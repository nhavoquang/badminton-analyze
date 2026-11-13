import AVFoundation
import SwiftUI

/// First frame of a local video, generated off the main thread.
struct VideoThumbnail: View {
    var url: URL?
    var time: Double = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .clipped()
        .task(id: "\(url?.path ?? "")-\(time)") {
            image = await Self.frame(url, at: time)
        }
    }

    static func frame(_ url: URL?, at seconds: Double, maxSide: CGFloat = 800) async -> UIImage? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        guard let result = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

struct PlayerDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 10, height: 10) }
}

/// Pill used to switch overlay layers on and off.
struct LayerChip: View {
    var title: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .foregroundStyle(isOn ? Color.black : Color.white)
                .background(isOn ? Color.white : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension Double {
    var oneDecimal: String { formatted(.number.precision(.fractionLength(1))) }
    var percent: String { formatted(.percent.precision(.fractionLength(0))) }
}

/// Compact colour picker for a player: tap the dot, pick from the iOS system colours.
struct ColorMenu: View {
    @Binding var selection: PlayerTint

    var body: some View {
        Menu {
            Picker("Màu", selection: $selection) {
                ForEach(PlayerTint.allCases) { t in
                    Label { Text(t.title) } icon: { Image(uiImage: t.swatch) }.tag(t)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Circle().fill(selection.color).frame(width: 14, height: 14)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 30, minHeight: 30)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Màu người chơi: \(selection.title)")
    }
}
