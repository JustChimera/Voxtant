import AppKit
import SwiftUI

@main
enum VoxtantApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    private let smokeTest = CommandLine.arguments.contains("--ui-smoke-dir") || CommandLine.arguments.contains("--audio-smoke-dir")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--audio-smoke-dir"),
           CommandLine.arguments.indices.contains(index + 1) {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            Task { @MainActor in await AudioCaptureSmokeTest.run(folder: folder) }
            return
        }
        let preferences: UserDefaults
        if smokeTest {
            preferences = UserDefaults(suiteName: "local.voxtant.ui-smoke." + UUID().uuidString)!
        } else { preferences = .standard }
        let model = DemoModel(loadKeychain: !smokeTest, preferences: preferences)
        let controller = MenuBarController(model: model, preferences: preferences)
        self.controller = controller
        if let index = CommandLine.arguments.firstIndex(of: "--ui-smoke-dir"),
           CommandLine.arguments.indices.contains(index + 1) {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            Task { @MainActor in await WidgetSmokeTest.run(controller: controller, folder: folder) }
        } else if CommandLine.arguments.contains("--show-widget") {
            controller.showWidget()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showWidget()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !smokeTest, controller?.model.busy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Завершить Voxtant?"
        alert.informativeText = "Остановите запись, чтобы отменить оставшуюся обработку. Уже записанное аудио остаётся в папке сессии."
        alert.addButton(withTitle: "Вернуться")
        alert.addButton(withTitle: "Завершить")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
