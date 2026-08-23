// swift-tools-version: 5.9
import PackageDescription

// A device-free regression harness for the parts of the app that are
// pure logic and expensive to get wrong.
//
// It exists because the scene player is the hardest-won thing in this
// project and there was no automated way to notice it breaking. There
// is no test target in the Xcode project, and this machine cannot
// resolve an iOS destination at all (no simulator runtime installed),
// so nothing that needs UIKit, SwiftUI or AVFoundation can be tested
// here. What CAN be tested is Models/Scene.swift, which imports only
// Foundation and holds the entire stream-routing decision - the table
// that decides, per codec and container, which URL the player is
// handed. Verified: it typechecks standalone with zero app symbols.
//
// Run it with ./run.sh, which copies the real source in first so there
// is exactly one copy of the logic and the tests cannot drift onto a
// stale duplicate.
let package = Package(
    name: "SceneLogic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SceneLogic"),
        .testTarget(name: "SceneLogicTests", dependencies: ["SceneLogic"]),
    ]
)
