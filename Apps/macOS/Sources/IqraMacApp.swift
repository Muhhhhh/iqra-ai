import AppKit
import RecitationCore
import SwiftUI

/// Releases the ML contexts before the process exits.
///
/// Without this, ggml's static Metal teardown runs while the whisper and Silero contexts
/// are still alive and calls `abort()` — a crash report on every quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppSettings.shared.releaseComponents()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct IqraMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("Iqra") {
            ContentView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Recitation") {
                Button("Start / Stop") {
                    NotificationCenter.default.post(name: .toggleRecitation, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Retry Passage") {
                    NotificationCenter.default.post(name: .resetRecitation, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Next Mistake") {
                    NotificationCenter.default.post(name: .selectNextMistake, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])

                Button("Previous Mistake") {
                    NotificationCenter.default.post(name: .selectPreviousMistake, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            }

            CommandGroup(after: .sidebar) {
                Button("Zoom In") {
                    settings.pageZoom = min(settings.pageZoom * 1.25, 5.0)
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button("Zoom Out") {
                    settings.pageZoom = max(settings.pageZoom / 1.25, 0.5)
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Fit Page") {
                    settings.pageZoom = 1.0
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let toggleRecitation = Notification.Name("IqraToggleRecitation")
    static let resetRecitation = Notification.Name("IqraResetRecitation")
    static let selectNextMistake = Notification.Name("IqraSelectNextMistake")
    static let selectPreviousMistake = Notification.Name("IqraSelectPreviousMistake")
}
