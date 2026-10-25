import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // L'app parte come app normale (così la finestra si apre sulla scrivania).
        // All'avvio dal login passa subito alla sola barra dei menu, senza finestra.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        MainActor.assumeIsolated {
            _ = Mixer.shared
            if atLogin {
                NSApp.setActivationPolicy(.accessory)
            } else {
                MainWindowController.shared.show()
            }
        }
    }

    /// Doppio clic sull'app (o clic nel Dock) mentre è già aperta.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { MainWindowController.shared.show() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Mixer.shared.shutdown() }
    }
}

@main
struct VolumeMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var mixer = Mixer.shared

    var body: some Scene {
        MenuBarExtra("VolumeMixer", systemImage: "slider.horizontal.3") {
            MenuView(mixer: mixer)
        }
        .menuBarExtraStyle(.window)
    }
}
