// SPDX-License-Identifier: GPL-2.0-or-later
//
// The launcher's background picture. It is not part of the app: the first time, it is fetched
// from PlayStation's servers (the game's own key art, the address below) and kept in the app's
// caches; until then, or without a connection, the background of the player's own copy of the
// game is used (sce_sys/pic1.png, what the PS4 shows behind the game's tile).

import Observation
import UIKit

@MainActor
@Observable
final class Artwork {
    static let address = URL(string: "https://image.api.playstation.com/vulcan/img/rnd/202010/2716/OkEr3rN2ceueg6wFV6sycSrH.png")!

    private(set) var image: UIImage?
    private var fetching = false

    private static var cached: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("astro-bot-background.png")
    }

    /// Shows what is at hand at once, and fetches the key art if it is not kept yet.
    func load(gamePath: URL?) {
        if let kept = UIImage(contentsOfFile: Self.cached.path) {
            image = kept
            return
        }
        if image == nil, let gamePath {
            for name in ["pic1.png", "pic0.png"] {
                let file = gamePath.appendingPathComponent("sce_sys").appendingPathComponent(name)
                if let picture = UIImage(contentsOfFile: file.path) {
                    image = picture
                    break
                }
            }
        }
        guard !fetching else { return }
        fetching = true
        Task {
            defer { fetching = false }
            guard let (data, response) = try? await URLSession.shared.data(from: Self.address),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let picture = UIImage(data: data) else {
                return
            }
            try? data.write(to: Self.cached, options: .atomic)
            image = picture
        }
    }
}
