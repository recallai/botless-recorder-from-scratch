// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "macos-recorder",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "macos-recorder", targets: ["MacOSRecorder"])
  ],
  targets: [
    .executableTarget(
      name: "MacOSRecorder",
      path: "Sources/MacOSRecorder"
    )
  ]
)
