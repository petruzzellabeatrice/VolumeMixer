import SwiftUI

/// Riga compatta usata nel menu della barra dei menu.
struct AppRow: View {
    let entry: AppEntry
    @ObservedObject var mixer: Mixer

    var body: some View {
        let gain = mixer.gain(for: entry.id)
        HStack(spacing: 10) {
            AppIconView(icon: entry.icon, size: 28)
                .opacity(entry.isPlaying ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    PercentLabel(gain: gain)
                }
                HStack(spacing: 6) {
                    MuteButton(id: entry.id, mixer: mixer)
                    GainSlider(id: entry.id, mixer: mixer).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Riporta al 100%") { mixer.setGain(1, for: entry.id) }
        }
    }
}

struct MenuView: View {
    @ObservedObject var mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Volume per app").font(.headline)
                Spacer()
                if !mixer.presets.isEmpty {
                    Menu("Preset") {
                        ForEach(mixer.presets) { p in
                            Button(p.name) { mixer.apply(p) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if mixer.apps.isEmpty {
                Text("Nessuna app sta riproducendo audio.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(mixer.apps) { AppRow(entry: $0, mixer: mixer) }
            }
            Text("0–400%. Oltre il 100% un limitatore evita la distorsione.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Apri VolumeMixer…") { MainWindowController.shared.show() }
                Spacer()
                Button("Ripristina") { mixer.resetAll() }
                Button("Esci") {
                    mixer.shutdown()
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Componenti condivisi

struct AppIconView: View {
    let icon: NSImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
    }
}

struct PercentLabel: View {
    let gain: Float
    var body: some View {
        Text(verbatim: "\(Int((gain * 100).rounded()))%")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(gain > 1 ? .orange : .secondary)
    }
}

struct MuteButton: View {
    let id: String
    @ObservedObject var mixer: Mixer
    var body: some View {
        let gain = mixer.gain(for: id)
        Button {
            mixer.setGain(gain == 0 ? 1 : 0, for: id)
        } label: {
            Image(systemName: gain == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help(gain == 0 ? Text("Riattiva") : Text("Silenzia"))
    }
}

struct GainSlider: View {
    let id: String
    @ObservedObject var mixer: Mixer
    var body: some View {
        Slider(value: Binding(get: { Double(mixer.gain(for: id)) },
                              set: { mixer.setGain(Float($0), for: id) }),
               in: 0...4)
    }
}
