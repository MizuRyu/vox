// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "vox-benchmarks",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "vox-m0-fact-check", targets: ["VoxM0FactCheck"]),
    .executable(name: "vox-m0", targets: ["VoxM0"]),
    .executable(name: "m0-core-tests", targets: ["M0HarnessCoreTests"]),
    .executable(name: "vox-m0-live-probe", targets: ["VoxM0LiveProbe"])
  ],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.0")
  ],
  targets: [
    .target(name: "M0HarnessCore"),
    .executableTarget(name: "VoxM0FactCheck", dependencies: ["M0HarnessCore"]),
    .executableTarget(
      name: "VoxM0",
      dependencies: [
        "M0HarnessCore",
        .product(name: "FluidAudio", package: "FluidAudio")
      ]
    ),
    .executableTarget(name: "VoxM0LiveProbe"),
    .executableTarget(
      name: "M0HarnessCoreTests",
      dependencies: ["M0HarnessCore"],
      path: "Tests/M0HarnessCoreTests"
    )
  ]
)
