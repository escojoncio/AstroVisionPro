// SPDX-License-Identifier: GPL-2.0-or-later
//
// The game: its artwork filling the window, its name, what it needs (executable memory, the
// game's files, a controller) as three glass cards that say what to do when something is
// missing, and the button that starts it.

import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var artwork = Artwork()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text("ASTRO BOT")
                        .font(.extraLargeTitle)
                        .fontWeight(.heavy)
                    Text("Rescue Mission · PlayStation VR")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 16) {
                    jitCard
                    gameCard
                    controllerCard
                }
                actions
            }
            .padding(48)
        }
        .onAppear {
            artwork.load(gamePath: model.gamePath)
        }
        .onChange(of: model.gamePath) { _, path in
            artwork.load(gamePath: path)
        }
    }

    // MARK: - Background

    private var background: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = artwork.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .transition(.opacity)
                } else {
                    LinearGradient(colors: [Color(red: 0.05, green: 0.10, blue: 0.30),
                                            Color(red: 0.02, green: 0.03, blue: 0.10)],
                                   startPoint: .top, endPoint: .bottom)
                }
                // The lower part darkened, so that the text and the cards read over any picture.
                LinearGradient(stops: [.init(color: .clear, location: 0.25),
                                       .init(color: .black.opacity(0.55), location: 0.65),
                                       .init(color: .black.opacity(0.8), location: 1.0)],
                               startPoint: .top, endPoint: .bottom)
            }
            .animation(.easeInOut(duration: 0.4), value: artwork.image != nil)
        }
        .ignoresSafeArea()
    }

    // MARK: - What the game needs

    private var jitCard: some View {
        let state = model.jit.state
        let verdict: Diagnostics.Verdict
        let detail: String
        switch state {
        case .ready(let megabytes):
            verdict = .ok
            detail = "Activo, \(megabytes) MB"
        case .waitingForDebugger:
            verdict = .warning
            detail = "Esperando a StikDebug…"
        case .preparing:
            verdict = .warning
            detail = "Preparando la memoria…"
        case .failed:
            verdict = .missing
            detail = "No se pudo activar"
        case .idle:
            verdict = .warning
            detail = model.jit.stikDebugInstalled ? "Sin activar" : "Hace falta StikDebug"
        }
        return StatusCard(title: "JIT", symbol: "bolt.fill", verdict: verdict, detail: detail) {
            switch state {
            case .idle, .failed:
                Button(state == .idle ? "Activar" : "Reintentar") {
                    model.jit.enable(arenaMegabytes: model.settings.jitArenaMB)
                }
            default:
                EmptyView()
            }
        }
    }

    private var gameCard: some View {
        StatusCard(title: "Juego", symbol: "opticaldisc.fill",
                   verdict: model.gamePath != nil ? .ok : .missing,
                   detail: model.gamePath?.lastPathComponent ?? "Copia CUSA12392 con Archivos") {
            if model.gamePath == nil {
                Button("Buscar") {
                    model.findGame()
                }
            }
        }
    }

    private var controllerCard: some View {
        let controller = model.controller
        let verdict: Diagnostics.Verdict = controller == nil ? .missing
            : (controller!.isPlayStation ? .ok : .warning)
        return StatusCard(title: "Mando", symbol: "gamecontroller.fill", verdict: verdict,
                          detail: controller?.name ?? "Empareja un DualSense") {
            EmptyView()
        }
    }

    // MARK: - Starting

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 16) {
            if model.coreState != AstroCoreStateIdle && !model.immersiveOpen {
                Button {
                    open()
                } label: {
                    Label("Volver al juego", systemImage: "arrow.uturn.forward")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .buttonBorderShape(.capsule)
            } else {
                Button {
                    if model.startGame() {
                        open()
                    }
                } label: {
                    Label("Jugar", systemImage: "play.fill")
                        .padding(.horizontal, 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .buttonBorderShape(.capsule)
                .disabled(!model.canStart)
            }
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassBackgroundEffect(in: .capsule)
            } else if !model.canStart && model.coreState == AstroCoreStateIdle {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hint: String {
        if !model.jit.isReady {
            return "Activa el JIT para poder jugar."
        }
        if model.gamePath == nil {
            return "Falta el juego."
        }
        return ""
    }

    private func open() {
        Task {
            switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
            case .opened:
                model.immersiveOpen = true
                LogFiles.log("Immersive space opened")
                // Only the game in view: the launcher comes back when the game's space closes.
                dismissWindow(id: AppModel.launcherID)
            default:
                model.message = "No se pudo abrir el espacio inmersivo."
            }
        }
    }
}

/// One of the things the game needs: what it is, whether it is there, and what to do if not.
struct StatusCard<Action: View>: View {
    let title: String
    let symbol: String
    let verdict: Diagnostics.Verdict
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.title3)
                Spacer()
                Image(systemName: StatusStyle.symbol(verdict))
                    .foregroundStyle(StatusStyle.color(verdict))
                    .font(.title3)
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(20)
        .frame(width: 240, alignment: .topLeading)
        .frame(minHeight: 150, alignment: .topLeading)
        .glassBackgroundEffect(in: .rect(cornerRadius: 28))
    }
}
