import SwiftUI
import AppKit

#if !HARNESS
@main
#endif
struct SnagApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    init() { Prefs.register() }

    var body: some Scene {
        Window("Snag", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 400, idealWidth: 460, maxWidth: 720, minHeight: 440)
                .preferredColorScheme(AppearanceModel.shared.scheme)
                .onAppear { model.launch() }
        }
        .defaultSize(width: 460, height: 620)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Open Downloads Folder") { AppModel.shared.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(AppearanceModel.shared.scheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }

    /// `open -a Snag <link>` and links dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppModel.shared.launch()
            for url in urls where url.scheme == "snag" {
                // snag://add?d=<base64 JSON from snag-mcp>
                guard let d = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value,
                      let data = Data(base64URL: d),
                      let req = try? JSONDecoder().decode(AddRequest.self, from: data) else { continue }
                AppModel.shared.enqueue(link: req.link, choice: req.choice, whole: req.whole)
            }
            if let url = urls.first(where: { !$0.isFileURL && $0.scheme != "snag" }) { AppModel.shared.text = url.absoluteString }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep going while something downloads; the Dock icon brings the window back.
        MainActor.assumeIsolated { !AppModel.shared.records.contains(where: \.isActive) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.saveNow() }
    }
}
