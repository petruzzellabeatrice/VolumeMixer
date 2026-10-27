import SwiftUI
import AppKit
import ServiceManagement

/// Finestra principale. Mentre è aperta l'app compare nel Dock e in Cmd+Tab.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "VolumeMixer"
            w.contentViewController = NSHostingController(rootView: MainView(mixer: .shared))
            w.setContentSize(NSSize(width: 540, height: 640))
            w.minSize = NSSize(width: 460, height: 420)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MainWindow")
            w.delegate = self
            if !w.setFrameUsingName("MainWindow") { w.center() }
            window = w
        }
        // Un'app "solo barra dei menu" può mostrare finestre sopra a tutto, anche dentro lo
        // spazio a schermo intero di un'altra app. Prima diventa un'app normale, poi (con un
        // attimo di ritardo, perché il cambio non è immediato) mostra la finestra: così macOS
        // la apre sulla scrivania come per qualsiasi altra app.
        let present = { [weak self] in
            NSApp.activate()
            self?.window?.makeKeyAndOrderFront(nil)
        }
        if NSApp.activationPolicy() == .regular {
            present()
        } else {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { present() }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MainView: View {
    @ObservedObject var mixer: Mixer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppsSection(mixer: mixer)
                    KeyboardSection()
                    PresetSection(mixer: mixer)
                }
                .padding(20)
            }
            Divider()
            FooterBar(mixer: mixer)
        }
    }
}

// MARK: - Sezioni

private struct SectionTitle: View {
    let title: LocalizedStringKey, subtitle: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct KeyboardSection: View {
    @AppStorage("hotkeysEnabled") private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Tastiera",
                         subtitle: "Regola il volume dell'app in primo piano senza aprire VolumeMixer.")
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 24) {
                            shortcut("⌃⌥↑", "Alza del 5%")
                            shortcut("⌃⌥↓", "Abbassa del 5%")
                        }
                        shortcut("⌃⌥← ⌃⌥→", "Scegli un'altra app che sta suonando")
                        Text("Dopo ⌃⌥← o ⌃⌥→, finché il riquadro è visibile, ⌃⌥↑ e ⌃⌥↓ regolano l'app scelta senza toglierla dal primo piano (comodo con un video a schermo intero).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .opacity(enabled ? 1 : 0.4)
                    Toggle("Attiva le scorciatoie da tastiera", isOn: $enabled)
                        .toggleStyle(.checkbox)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
        .onChange(of: enabled) { _, on in HotKeys.shared.setEnabled(on) }
    }

    private func shortcut(_ keys: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: keys)
                .font(.system(.body, design: .rounded).weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text(label)
        }
    }
}

private struct PresetSection: View {
    @ObservedObject var mixer: Mixer
    @StateObject private var form = PresetForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Preset",
                         subtitle: "Salva i volumi attuali e richiamali con un clic (anche dal menu).")
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if mixer.presets.isEmpty {
                        Text("Nessun preset salvato.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        FlowRow(spacing: 8) {
                            ForEach(mixer.presets) { p in
                                Button(p.name) { mixer.apply(p) }
                                    .buttonStyle(.bordered)
                                    .tint(mixer.isActive(p) ? .accentColor : nil)
                                    .help(summary(p))
                                    .contextMenu {
                                        Button("Elimina “\(p.name)”", role: .destructive) { mixer.delete(p) }
                                    }
                            }
                        }
                    }
                    if form.naming {
                        HStack {
                            TextField("Nome del preset (es. Serie con amici)", text: $form.newName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(save)
                            Button("Salva", action: save).keyboardShortcut(.defaultAction)
                                .disabled(form.newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Annulla") { form.naming = false; form.newName = "" }
                        }
                    } else {
                        Button {
                            form.naming = true
                        } label: {
                            Label("Salva volumi attuali come preset", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    private func save() {
        let name = form.newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        mixer.savePreset(named: name)
        form.naming = false
        form.newName = ""
    }

    private func summary(_ p: Preset) -> String {
        if p.gains.isEmpty { return String(localized: "Tutte le app al 100%") }
        return p.gains.map { "\(mixer.name(for: $0.key)): \(Int(($0.value * 100).rounded()))%" }
            .sorted().joined(separator: "\n")
    }
}

private struct AppsSection: View {
    @ObservedObject var mixer: Mixer
    @AppStorage("showSilent") private var showSilent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                SectionTitle(title: "App",
                             subtitle: "Volume di ogni app, da 0 a 400%.")
                Spacer()
                Toggle("Mostra app in silenzio", isOn: $showSilent).toggleStyle(.switch).controlSize(.small)
            }
            let list = mixer.apps + (showSilent ? mixer.silentApps : [])
            GroupBox {
                VStack(spacing: 0) {
                    if list.isEmpty {
                        Text("Nessuna app sta riproducendo audio.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, entry in
                        if i > 0 { Divider() }
                        LargeAppRow(entry: entry, mixer: mixer)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

private struct LargeAppRow: View {
    let entry: AppEntry
    @ObservedObject var mixer: Mixer

    var body: some View {
        let gain = mixer.gain(for: entry.id)
        HStack(spacing: 12) {
            AppIconView(icon: entry.icon, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(entry.isPlaying ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(entry.isPlaying ? LocalizedStringKey("In riproduzione") : LocalizedStringKey("In silenzio"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, alignment: .leading)

            MuteButton(id: entry.id, mixer: mixer)
            GainSlider(id: entry.id, mixer: mixer)
            PercentLabel(gain: gain).frame(width: 40, alignment: .trailing)
            Button {
                mixer.setGain(1, for: entry.id)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Riporta al 100%")
            .opacity(gain == 1 ? 0 : 1)
            .disabled(gain == 1)
        }
        .padding(.vertical, 10)
    }
}

private struct FooterBar: View {
    @ObservedObject var mixer: Mixer
    @StateObject private var login = LoginItem()

    var body: some View {
        HStack {
            Toggle("Avvia al login", isOn: Binding(get: { login.enabled }, set: login.set))
                .toggleStyle(.checkbox)
            if let error = login.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Button("Ripristina tutto al 100%") { mixer.resetAll() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private final class PresetForm: ObservableObject {
    @Published var naming = false
    @Published var newName = ""
}

/// Avvio automatico al login (SMAppService).
private final class LoginItem: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = String(localized: "Non riuscito: \(error.localizedDescription)")
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

/// Disposizione orizzontale che va a capo (per i pulsanti dei preset).
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (sub, p) in zip(subviews, arrange(subviews, width: bounds.width).positions) {
            sub.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], width: CGFloat, height: CGFloat) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x - spacing)
        }
        return (positions, maxW, y + rowH)
    }
}
