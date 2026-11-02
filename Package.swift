// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voxtant",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Voxtant", targets: ["LectureTranslate"])],
    targets: [
        .target(name: "LectureCore"),
        .executableTarget(name: "LectureTranslate", dependencies: ["LectureCore"]),
        .testTarget(name: "LectureCoreTests", dependencies: ["LectureCore"])
    ],
    swiftLanguageModes: [.v5]
)
