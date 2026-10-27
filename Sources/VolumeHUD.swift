import SwiftUI
import AppKit

/// Riquadro che compare per un attimo quando cambi il volume da tastiera
/// (come quello del volume di macOS, visibile anche sopra i video a schermo intero).
@MainActor
final class VolumeHUD {
    static let shared = VolumeHUD()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Quanto resta visibile il riquadro dopo l'ultimo tasto (poi si dissolve).
    static let displayTime: TimeInterval = 1.5
    /// I messaggi restano un po' di più e si dissolvono più lentamente.
    static let messageDisplayTime: TimeInterval = 2

    func show(_ info: Mixer.HUDInfo) {
        model.name = info.name
        model.icon = info.icon
        model.gain = info.gain
        model.position = info.position
        model.isMessage = info.isMessage

        let panel = self.panel ?? makePanel()
        self.panel = panel
        // In alto al centro, appena sotto la barra dei menu.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 12))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = info.isMessage ? 0.8 : 0.35
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { panel?.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (info.isMessage ? Self.messageDisplayTime : Self.displayTime),
                                      execute: work)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 280, height: 86)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true

        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        panel.contentView = blur
        return panel
    }
}

final class HUDModel: ObservableObject {
    @Published var name = ""
    @Published var icon: NSImage?
    @Published var gain: Float = 1
    @Published var position: String?
    @Published var isMessage = false
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 14) {
            AppIconView(icon: model.icon, size: 44)
            if model.isMessage {
                Text(model.name).font(.headline).lineLimit(1)
                Spacer()
            } else {
                level
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var level: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.name).font(.headline).lineLimit(1)
                if let position = model.position {
                    // App scelta con ⌃⌥← / ⌃⌥→: mostra la posizione nell'elenco.
                    Text(verbatim: "‹ \(position) ›")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: "\(Int((model.gain * 100).rounded()))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(model.gain > 1 ? .orange : .primary)
            }
            LevelBar(gain: model.gain)
        }
    }
}

/// Barra 0–400% con una tacca al 100%.
private struct LevelBar: View {
    let gain: Float

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(gain > 1 ? Color.orange : Color.primary.opacity(0.8))
                    .frame(width: max(0, w * CGFloat(min(gain, 4) / 4)))
                Rectangle().fill(.primary.opacity(0.5))
                    .frame(width: 2, height: 10)
                    .offset(x: w / 4 - 1)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.12), value: gain)
    }
}
