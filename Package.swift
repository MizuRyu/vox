// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "vox",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "Vox", targets: ["Vox"]),
    .executable(name: "vox-doc-images", targets: ["VoxDocImages"]),
  ],
  targets: [
    .target(name: "VoxCore"),
    .target(name: "VoxApp", dependencies: ["VoxCore"]),
    .executableTarget(name: "VoxDocImages", dependencies: ["VoxCore", "VoxApp"]),
    .executableTarget(name: "Vox", dependencies: ["VoxApp"]),
    .testTarget(name: "VoxCoreTests", dependencies: ["VoxCore"]),
    .testTarget(name: "VoxAppTests", dependencies: ["VoxApp"]),
  ]
)
