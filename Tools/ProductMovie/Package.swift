// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ProductMovie",
  platforms: [.macOS(.v26)],
  products: [.executable(name: "product-movie", targets: ["ProductMovie"])],
  targets: [
    .executableTarget(
      name: "ProductMovie", path: ".",
      exclude: ["README.md", "build.py", "music.py", "movie.json", "preview.html"],
      sources: ["main.swift"])
  ])
