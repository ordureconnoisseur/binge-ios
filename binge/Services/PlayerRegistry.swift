import AVFoundation
import Foundation

// Weak global registry of every AVPlayer currently alive in the
// reel. Each SceneSlideView registers its player on creation and
// unregisters on teardown. The registry exists for two purposes:
//
//   1. Pause-all utility — kept here as a public method so a
//      future ScrollPhaseChange hook (iOS 18+) can stop every
//      mid-flight player during a swipe gesture. Not wired up yet
//      because we target iOS 17 and rely on per-slide isActive
//      flips for now.
//
//   2. Diagnostics — Console.log(playerCount) when investigating
//      decoder thrash. iOS allows ~4 concurrent H.264 hardware
//      decoders; LazyVStack mounting 3-5 slides at once is well
//      within that, but worth a check if scenes ever stop
//      decoding under aggressive scrolling.
//
// Weak storage so registering doesn't extend the player's
// lifetime — slides own their players.
enum PlayerRegistry {
    private static let players = NSHashTable<AVPlayer>.weakObjects()
    private static let lock = NSLock()

    static func register(_ player: AVPlayer) {
        lock.lock()
        defer { lock.unlock() }
        players.add(player)
    }

    static func unregister(_ player: AVPlayer) {
        lock.lock()
        defer { lock.unlock() }
        players.remove(player)
    }

    static func pauseAll() {
        lock.lock()
        let snapshot = players.allObjects
        lock.unlock()
        for p in snapshot { p.pause() }
    }

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return players.allObjects.count
    }
}
