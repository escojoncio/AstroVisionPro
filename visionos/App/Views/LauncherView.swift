// SPDX-License-Identifier: GPL-2.0-or-later
//
// The launcher window, laid out the way visionOS apps are (Human Interface Guidelines): a tab
// bar along the window's leading edge for its parts - the game, the check, the settings and the
// logs - with the game's part full of its artwork, glass panels over it, and one prominent
// action. Everything else is a step away, in its own tab.

import SwiftUI
import UIKit

struct LauncherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label(L("Jugar", "Play"), systemImage: "gamecontroller.fill")
                }
            CheckView()
                .tabItem {
                    Label(L("Comprobación", "Check"), systemImage: "checkmark.shield")
                }
            SettingsView()
                .tabItem {
                    Label(L("Ajustes", "Settings"), systemImage: "slider.horizontal.3")
                }
            LogsView()
                .tabItem {
                    Label(L("Registros", "Logs"), systemImage: "doc.text.magnifyingglass")
                }
        }
        .environment(\.locale, Language.shared.locale)
        .onAppear {
            model.openLauncher = openWindow
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.findGame()
                model.refreshDiagnostics()
            }
        }
    }
}

/// Green, orange or red, and the symbol that goes with it, wherever a state is shown.
enum StatusStyle {
    static func symbol(_ verdict: Diagnostics.Verdict) -> String {
        switch verdict {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .missing: "xmark.octagon.fill"
        }
    }

    static func color(_ verdict: Diagnostics.Verdict) -> Color {
        switch verdict {
        case .ok: .green
        case .warning: .orange
        case .missing: .red
        }
    }
}

/// The system's share sheet (AirDrop, Mail, Save to Files...) for the log files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
