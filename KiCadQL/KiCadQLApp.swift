import SwiftUI

/// The host app does nothing by itself. It exists so macOS can find the QuickLook extension embedded
/// in it, and so its Info.plist can teach macOS what a .kicad_pcb file is. Launching it once registers
/// the extension.
@main
struct KiCadQLApp: App {
    var body: some Scene {
        Window("KiCad QuickLook", id: "main") {
            VStack(alignment: .leading, spacing: 12) {
                Text("KiCad QuickLook is installed").font(.title2.bold())
                Text("Select a .kicad_pcb or .kicad_sch file in Finder and press Space to preview it. You can quit this app.")
                Text("If previews don't appear, enable the extension in System Settings → General → Login Items & Extensions → Quick Look.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 440)
        }
        .windowResizability(.contentSize)
    }
}
