#!/usr/bin/env python3
"""Render the real palette view with synthetic data and no visible windows."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
RENDERER = r'''
@MainActor
func renderExample() throws {
  let app = NSApplication.shared
  app.setActivationPolicy(.prohibited)
  let model = PaletteModel()
  model.target = PaletteTarget(root: "/ExampleProject", source: .terminal)
  model.resolvingTarget = false
  model.files = [
    IndexedFile(path: "Sources/App.swift", status: .modified),
    IndexedFile(path: "Sources/Settings/SettingsView.swift"),
    IndexedFile(path: "Sources/Settings/SettingsModel.swift"),
    IndexedFile(path: "Tests/SettingsTests.swift"),
    IndexedFile(path: "README.md"),
  ]
  model.totalCount = model.files.count
  model.changedCount = 1
  model.refreshRows()
  model.setFileViewMode(.tree)
  for path in ["Sources", "Sources/Settings", "Tests"] {
    if let index = model.treeRows.firstIndex(where: { $0.path == path }) {
      model.toggleDirectory(at: index)
    }
  }
  if let index = model.treeRows.firstIndex(where: { $0.path == "Sources/Settings/SettingsView.swift" }) {
    model.select(index)
  }
  model.preview = FilePreview(title: "SettingsView.swift", detail: "合成例",
    lines: ["import SwiftUI", "", "struct SettingsView: View {", "  var body: some View {",
      "    Text(\"音声入力の設定\")", "  }", "}"], notice: nil)
  let view = NSHostingView(rootView: PaletteView(model: model))
  view.frame = NSRect(x: 0, y: 0, width: 960, height: 580)
  view.appearance = NSAppearance(named: .darkAqua)
  view.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
  view.layoutSubtreeIfNeeded()
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    throw CocoaError(.fileWriteUnknown)
  }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
  guard app.windows.allSatisfy({ !$0.isVisible }) else { throw CocoaError(.validationMissingMandatoryProperty) }
  print("Palette example rendered from synthetic files; visibleWindows=0")
}
try MainActor.assumeIsolated { try renderExample() }
'''


def render(output):
    with tempfile.TemporaryDirectory(prefix="vox-palette-render-") as temporary:
        work = Path(temporary)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-emit-library", "-emit-module",
            "-module-name", "VoxCore", *map(str, sorted((ROOT / "Sources/VoxCore").rglob("*.swift"))),
            "-emit-module-path", str(work / "VoxCore.swiftmodule"), "-o", str(work / "libVoxCore.dylib"),
        ], check=True)
        # Same source file keeps the private views accessible without adding production test hooks.
        source = work / "main.swift"
        source.write_text("".join(
            (ROOT / "Sources/VoxApp/Palette" / name).read_text()
            for name in ("PalettePanel.swift", "PaletteView.swift")
        ) + RENDERER)
        executable = work / "render"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-I", temporary, "-L", temporary,
            "-lVoxCore", "-Xlinker", "-rpath", "-Xlinker", temporary,
            str(source), *[str(ROOT / "Sources/VoxApp" / name) for name in
                          ("Palette/FileIndexer.swift", "Support/Shell.swift", "Support/Metrics.swift")],
            "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable), str(output)], check=True)


def main():
    render(ROOT / "images/palette-tree.png")


if __name__ == "__main__":
    main()
