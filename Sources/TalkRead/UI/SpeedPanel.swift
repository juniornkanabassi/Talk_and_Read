// The speed panel (25 Oct, Junior's YouTube and Speechify brief): the speed large, minus and plus by 0.25×, a 0.5-4×
// slider with the presets marked on it, and the preset chips. Opens from the reader's speed button and the mini player's.
import SwiftUI
import TalkReadCore

/// The live panel: what is playing now (a preview shows its own speed), stepped and set through the model.
struct LiveSpeedPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SpeedPanel(speed: Double(model.activeSpeed), faster: model.settings.increaseSpeedShortcut.display,
                   slower: model.settings.decreaseSpeedShortcut.display,
                   set: { model.setSpeed(Float($0)) }, step: { model.stepSpeed(up: $0) })
            .background {   // ⌘+ / ⌘− keep working while the panel has the keyboard
                Group {
                    Button("Faster") { model.stepSpeed(up: true) }.keyboardShortcut("=", modifiers: .command)
                    Button("Slower") { model.stepSpeed(up: false) }.keyboardShortcut("-", modifiers: .command)
                }
                .opacity(0).accessibilityHidden(true)
            }
    }
}

/// The panel's face. Pure, so the snapshot can draw it at any speed.
struct SpeedPanel: View {
    static let width: CGFloat = 340
    static let range = Double(TalkReadCore.Settings.speedRange.lowerBound) ... Double(TalkReadCore.Settings.speedRange.upperBound)

    let speed: Double
    /// The ⌥D and ⌥S shortcuts as the user set them.
    let faster: String
    let slower: String
    let set: (Double) -> Void
    let step: (_ up: Bool) -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reading speed").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("about \(Theme.wordsPerMinute(speed)) words a minute").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(format: "%.2f", speed)).font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                Text("×").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Speed \(Theme.speed(speed))")
            HStack(spacing: 10) {
                RoundButton(symbol: "minus", label: "Slower by 0.25×") { step(false) }
                    .disabled(speed <= Self.range.lowerBound + 0.001)
                slider
                RoundButton(symbol: "plus", label: "Faster by 0.25×") { step(true) }
                    .disabled(speed >= Self.range.upperBound - 0.001)
            }
            HStack(spacing: 6) {
                ForEach(Theme.speedPresets, id: \.self) { p in
                    VStack(spacing: 3) {
                        Button(p == 2.75 ? "2.75" : String(format: "%.1f", p)) { set(p) }
                            .buttonStyle(SpeedChipStyle(selected: abs(speed - p) < 0.001))
                            .accessibilityLabel(Theme.speed(p))
                        Text(p == 1 ? "Normal" : " ").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if speed > 3.001 {
                Text("Above 3×, some words may start to blur.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Divider()
            HStack {
                Text("Steps of 0.25×")
                Spacer()
                Text("\(faster) faster · \(slower) slower")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: Self.width)
    }

    /// Snaps to 0.25×; dots above the track mark the presets (yellow once passed).
    private var slider: some View {
        VStack(spacing: 2) {
            GeometryReader { g in
                let inset: CGFloat = 10, track = g.size.width - 2 * inset
                ForEach(Theme.speedPresets, id: \.self) { p in
                    Circle().fill(p <= speed + 0.001 ? Theme.accent : Color.primary.opacity(0.3))
                        .frame(width: 4, height: 4)
                        .position(x: inset + track * (p - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound), y: 2)
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            Slider(value: Binding(get: { speed }, set: { set(($0 * 4).rounded() / 4) }), in: Self.range, step: 0.25)
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityLabel("Reading speed")
                .accessibilityValue(Theme.speed(speed))
            HStack {
                Text("0.5×")
                Spacer()
                Text("4×")
            }
            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}

/// The panel's circular minus and plus.
private struct RoundButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.08), in: Circle())
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// ChipStyle stretched to share the row evenly.
private struct SpeedChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(selected ? Theme.onAccent : .primary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)), in: Capsule())
            .contentShape(Capsule())
    }
}
