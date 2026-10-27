import AppKit
import CoreAudio

struct AppEntry: Identifiable {
    let id: String              // bundle ID dell'app responsabile
    let name: String
    let icon: NSImage?
    let processIDs: Set<AudioObjectID>
    let isPlaying: Bool
    let isRegularApp: Bool      // app "vera" (con icona nel Dock), non un servizio di sistema
}

struct Preset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var gains: [String: Float]
}

@MainActor
final class Mixer: ObservableObject {
    static let shared = Mixer()

    /// App che stanno suonando o hanno un volume personalizzato.
    @Published private(set) var apps: [AppEntry] = []
    /// App aperte con un client audio ma in silenzio.
    @Published private(set) var silentApps: [AppEntry] = []
    @Published private(set) var gains: [String: Float]
    @Published private(set) var presets: [Preset]
    /// Nomi delle app viste almeno una volta (per i preset quando l'app è chiusa).
    @Published private(set) var knownNames: [String: String]

    /// Un'app che si è fermata da meno di così conta ancora come "in riproduzione"
    /// (una pausa breve della serie non la fa sparire dall'elenco).
    private let playingGrace: TimeInterval = 8
    private var lastPlayed: [String: Date] = [:]

    private var entries: [String: AppEntry] = [:]
    private var taps: [String: AppTap] = [:]
    private var outputUID: String?
    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let defaults = UserDefaults.standard

    private init() {
        let saved = defaults.dictionary(forKey: "gains") as? [String: Double] ?? [:]
        gains = saved.mapValues { Float($0) }
        presets = (defaults.data(forKey: "presets")).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
        knownNames = defaults.dictionary(forKey: "knownNames") as? [String: String] ?? [:]
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Volumi

    func gain(for id: String) -> Float { gains[id] ?? 1.0 }

    func setGain(_ value: Float, for id: String) {
        // Vicino al 100% torna esattamente a 100% (nessun tap: audio originale).
        let v = abs(value - 1.0) < 0.03 ? 1.0 : max(0, value)
        gains[id] = v == 1.0 ? nil : v
        saveGains()
        syncTaps()
    }

    func resetAll() {
        gains.removeAll()
        saveGains()
        syncTaps()
    }

    func name(for id: String) -> String { entries[id]?.name ?? knownNames[id] ?? id }

    func icon(for id: String) -> NSImage? {
        if let icon = entries[id]?.icon { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: Tastiera

    /// Passo delle scorciatoie ⌃⌥↑ / ⌃⌥↓.
    static let keyStep: Float = 0.05
    /// Per quanto resta valida l'app scelta con ⌃⌥← / ⌃⌥→ dopo l'ultimo tasto
    /// (un po' più del riquadro a schermo, che sparisce dopo 1,5 s + dissolvenza).
    static let selectionTimeout: TimeInterval = 1.9

    /// Cosa mostrare nel riquadro del volume.
    struct HUDInfo {
        let name: String
        let icon: NSImage?
        let gain: Float
        /// Es. "2/3" quando l'app è stata scelta con ⌃⌥← / ⌃⌥→.
        let position: String?
        /// Solo un messaggio, senza percentuale né barra (es. "Tutte le app al 100%").
        var isMessage = false
    }

    private var selectedID: String?
    private var selectionExpiry = Date.distantPast
    private var selectionActive: Bool { selectedID != nil && Date() < selectionExpiry }

    /// App fra cui scegliere con ⌃⌥← / ⌃⌥→: quelle dell'elenco (in riproduzione o con volume
    /// personalizzato), escluse quelle di sistema.
    private var selectableApps: [AppEntry] { apps.filter(\.isRegularApp) }

    /// ⌃⌥← / ⌃⌥→: passa all'app precedente/successiva dell'elenco, senza toglierla dal primo piano.
    func cycleSelection(forward: Bool) -> HUDInfo? {
        let list = selectableApps
        guard !list.isEmpty else { return nil }
        let current: Int?
        if selectionActive, let id = selectedID {
            current = list.firstIndex { $0.id == id }
        } else {
            // Si parte dall'app in primo piano, se è nell'elenco.
            current = list.firstIndex { $0.id == NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        }
        let next: Int
        if let current {
            next = (current + (forward ? 1 : -1) + list.count) % list.count
        } else {
            next = forward ? 0 : list.count - 1
        }
        selectedID = list[next].id
        selectionExpiry = Date().addingTimeInterval(Self.selectionTimeout)
        return info(for: list[next].id)
    }

    /// ⌃⌥↑ / ⌃⌥↓: alza o abbassa a multipli del 5% l'app scelta con ⌃⌥← / ⌃⌥→ se il riquadro
    /// è ancora visibile, altrimenti l'app in primo piano. Nil se in primo piano c'è VolumeMixer.
    func nudgeTarget(by delta: Float) -> HUDInfo? {
        let id: String
        if selectionActive, let selected = selectedID {
            id = selected
            selectionExpiry = Date().addingTimeInterval(Self.selectionTimeout)
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ownPID,
                  let bid = app.bundleIdentifier else { return nil }
            id = bid
            selectedID = nil
        }
        let value = min(4, max(0, ((gain(for: id) + delta) * 20).rounded() / 20))
        setGain(value, for: id)
        return info(for: id)
    }

    /// ⌃⌥0: riporta tutte le app al 100%.
    func resetAllFromKeyboard() -> HUDInfo {
        resetAll()
        selectedID = nil
        return HUDInfo(name: String(localized: "Tutte le app al 100%"), icon: NSApp.applicationIconImage, gain: 1,
                       position: nil, isMessage: true)
    }

    private func info(for id: String) -> HUDInfo {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        var position: String?
        if selectionActive, selectedID == id {
            let list = selectableApps
            if let i = list.firstIndex(where: { $0.id == id }) { position = "\(i + 1)/\(list.count)" }
        }
        return HUDInfo(name: entries[id]?.name ?? running?.localizedName.map(cleanName) ?? name(for: id),
                       icon: running?.icon ?? icon(for: id),
                       gain: gain(for: id),
                       position: position)
    }

    // MARK: Preset

    func savePreset(named name: String) {
        presets.append(Preset(name: name, gains: gains))
        savePresets()
    }

    func apply(_ preset: Preset) {
        gains = preset.gains
        saveGains()
        syncTaps()
    }

    func delete(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    func isActive(_ preset: Preset) -> Bool { preset.gains == gains }

    // MARK: Ciclo di vita

    func shutdown() {
        taps.values.forEach { $0.stop() }
        taps.removeAll()
    }

    private func saveGains() { defaults.set(gains.mapValues { Double($0) }, forKey: "gains") }
    private func savePresets() { defaults.set(try? JSONEncoder().encode(presets), forKey: "presets") }

    private func refresh() {
        let running = NSWorkspace.shared.runningApplications
        var groups: [String: (pid: pid_t, procs: Set<AudioObjectID>, playing: Bool)] = [:]
        for proc in listAudioProcesses() where proc.pid != ownPID {
            let rpid = responsiblePID(for: proc.pid)
            // Estensioni senza app responsabile (es. net.whatsapp.WhatsApp.ServiceExtension)
            // vanno con l'app il cui bundle ID è un prefisso del loro.
            let app = NSRunningApplication(processIdentifier: rpid) ?? proc.bundleID.flatMap { bid in
                running.first { $0.bundleIdentifier.map { bid.hasPrefix($0 + ".") } ?? false }
            }
            let key = app?.bundleIdentifier ?? proc.bundleID ?? "pid.\(rpid)"
            var g = groups[key] ?? (app?.processIdentifier ?? rpid, [], false)
            g.procs.insert(proc.objectID)
            g.playing = g.playing || proc.isPlaying
            groups[key] = g
        }

        var all: [String: AppEntry] = [:]
        for (key, g) in groups {
            let app = NSRunningApplication(processIdentifier: g.pid)
            all[key] = AppEntry(id: key,
                                name: cleanName(app?.localizedName ?? key),
                                icon: app?.icon,
                                processIDs: g.procs,
                                isPlaying: g.playing,
                                isRegularApp: app?.activationPolicy == .regular)
        }
        entries = all

        let now = Date()
        for e in all.values where e.isPlaying { lastPlayed[e.id] = now }
        lastPlayed = lastPlayed.filter { all[$0.key] != nil }
        let played = lastPlayed, grace = playingGrace
        let recentlyPlaying = { (id: String) in played[id].map { now.timeIntervalSince($0) < grace } ?? false }

        let sorted = all.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let newApps = sorted.filter { recentlyPlaying($0.id) || gains[$0.id] != nil }
        let newSilent = sorted.filter { !recentlyPlaying($0.id) && gains[$0.id] == nil && $0.isRegularApp }
        if newApps.map(\.id) != apps.map(\.id) || newApps.map(\.isPlaying) != apps.map(\.isPlaying) { apps = newApps }
        if newSilent.map(\.id) != silentApps.map(\.id) { silentApps = newSilent }

        var names = knownNames
        for e in sorted where e.isRegularApp { names[e.id] = e.name }
        if names != knownNames {
            knownNames = names
            defaults.set(names, forKey: "knownNames")
        }

        let uid = defaultOutputDeviceUID()
        if uid != outputUID {
            outputUID = uid
            shutdown()   // cambio uscita (es. cuffie collegate): ricrea tutto
        }
        syncTaps()
    }

    private func syncTaps() {
        for (id, tap) in taps {
            let entry = entries[id]
            if gains[id] == nil || entry == nil || entry!.processIDs != tap.processIDs || tap.outputUID != outputUID {
                tap.stop()
                taps[id] = nil
            }
        }
        guard let outputUID else { return }
        for (id, g) in gains {
            guard let entry = entries[id], !entry.processIDs.isEmpty else { continue }
            if let tap = taps[id] {
                tap.setGain(g)
            } else {
                taps[id] = AppTap(processIDs: entry.processIDs, outputUID: outputUID, gain: g)
            }
        }
    }
}

/// Toglie i caratteri invisibili di formattazione (es. U+200E in "‎WhatsApp")
/// che altrimenti sballano l'ordine alfabetico.
private func cleanName(_ name: String) -> String {
    String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.properties.generalCategory != .format }))
}
