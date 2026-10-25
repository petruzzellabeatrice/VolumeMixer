import SwiftUI

/// Casella che compare quando suonano esattamente due app:
/// spuntata = un solo cursore per le due, altrimenti un cursore per app.
struct PairModePicker: View {
    @Binding var pairMode: Bool
    let compact: Bool

    var body: some View {
        Toggle("Passa a bilanciamento tra due app", isOn: $pairMode)
            .toggleStyle(.checkbox)
            .font(compact ? .callout : .body)
    }
}

/// Un solo cursore che sposta il volume fra le due app che stanno suonando.
/// `compact` = versione per il menu della barra.
struct PairBalance: View {
    @ObservedObject var mixer: Mixer
    let a: AppEntry
    let b: AppEntry
    let compact: Bool
    @AppStorage("balanceBoost") private var boost = true

    /// -1 = solo A, 0 = entrambe al 100%, +1 = solo B.
    private var position: Binding<Double> {
        Binding(
            get: {
                let ga = mixer.gain(for: a.id), gb = mixer.gain(for: b.id)
                if ga < 1 { return Double(1 - ga) }
                if gb < 1 { return -Double(1 - gb) }
                return 0
            },
            set: { p in
                let p = abs(p) < 0.03 ? 0 : p
                if p >= 0 {
                    mixer.setGain(Float(1 - p), for: a.id)
                    mixer.setGain(boost ? Float(1 + p) : 1, for: b.id)
                } else {
                    mixer.setGain(Float(1 + p), for: b.id)
                    mixer.setGain(boost ? Float(1 - p) : 1, for: a.id)
                }
            })
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            HStack(alignment: .center, spacing: compact ? 6 : 12) {
                side(a)
                Slider(value: position, in: -1...1)
                    .controlSize(compact ? .small : .regular)
                side(b)
            }
            HStack {
                Toggle(compact ? LocalizedStringKey("Alza l'altra (fino al 200%)")
                               : LocalizedStringKey("Mentre abbassi un'app, alza l'altra (fino al 200%)"),
                       isOn: $boost)
                    .toggleStyle(.checkbox)
                    .font(compact ? .caption : .callout)
                Spacer()
                Button("Centra") { position.wrappedValue = 0 }
                    .controlSize(compact ? .small : .regular)
            }
        }
    }

    private func side(_ entry: AppEntry) -> some View {
        VStack(spacing: 2) {
            AppIconView(icon: entry.icon, size: compact ? 24 : 34)
            Text(entry.name)
                .font(compact ? .caption2 : .caption)
                .lineLimit(1).truncationMode(.tail)
            PercentLabel(gain: mixer.gain(for: entry.id))
        }
        .frame(width: compact ? 62 : 90)
    }
}
