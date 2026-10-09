// SPDX-License-Identifier: GPL-2.0-or-later
//
// ASTRO BOT Rescue Mission (PS4 / PlayStation VR) on Apple Vision Pro: AstroQuest
// (https://github.com/bigmak94/AstroQuest) ported from the Quest 3 and the PC.
//
// A launcher window (the game's folder, executable memory through StikDebug, the controller),
// and a full immersive space the game is shown in.

import CompositorServices
import SwiftUI

@main
struct AstroQuestApp: App {
    @State private var model = AppModel()
    @State private var immersion: ImmersionStyle = .full

#if VPENGINE
    init() {
        // Before the app finishes launching: what runs when visionOS grants background time to
        // go on with a conversion.
        VPConversion.registerBackgroundTask()
    }
#endif

    var body: some Scene {
        WindowGroup(id: AppModel.launcherID) {
            LauncherView()
                .environment(model)
#if VPENGINE
                .onOpenURL { url in
                    model.handleOpenURL(url)
                }
#endif
        }
        .defaultSize(width: 1280, height: 760)

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            CompositorLayer(configuration: GameLayerConfiguration(
                foveation: model.settings.foveation,
                renderQuality: model.settings.renderQuality)) { layerRenderer in
                GameRenderer.start(layerRenderer: layerRenderer, settings: model.settings) { [model] in
                    Task { @MainActor in
                        model.immersiveEnded()
                    }
                }
            }
        }
        .immersionStyle(selection: $immersion, in: .full)
        .upperLimbVisibility(model.settings.showHands ? .visible : .hidden)
        .persistentSystemOverlays(.hidden)
    }
}
