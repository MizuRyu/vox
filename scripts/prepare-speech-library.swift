import CryptoKit
import Foundation

// 配布物の URL とハッシュはアプリ側の固定値を使う。
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  fputs("NG: prepare-speech-library SOURCE OUTPUT\n", stderr)
  exit(64)
}
let source = try String(contentsOfFile: arguments[1], encoding: .utf8)
let output = URL(fileURLWithPath: arguments[2])

func value(_ name: String, pattern: String? = nil) throws -> String {
  let expression = try NSRegularExpression(
    pattern: pattern ?? "static let " + name + " = \"([^\"]+)\"")
  let range = NSRange(source.startIndex..., in: source)
  guard let match = expression.firstMatch(in: source, range: range),
    let captured = Range(match.range(at: 1), in: source)
  else { throw CocoaError(.fileReadCorruptFile) }
  return String(source[captured])
}

func matches(_ path: URL, expected: String) throws -> Bool {
  guard FileManager.default.fileExists(atPath: path.path) else { return false }
  let hash = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
  return hash == expected
}

let libraryHash = try value("librarySHA256")
if try matches(output, expected: libraryHash) {
  print("OK: speech library cached")
  exit(0)
}
let urlString = try value("runtimeURL", pattern: "static let runtimeURL = URL\\(\\s*string: \"([^\"]+)\"")
guard let url = URL(string: urlString) else { throw CocoaError(.fileReadCorruptFile) }
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let staging = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: staging) }
let archive = staging.appendingPathComponent("runtime.zip")
let (data, response) = try await URLSession.shared.data(from: url)
guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
try data.write(to: archive)
guard try matches(archive, expected: value("archiveSHA256")) else { throw CocoaError(.fileReadCorruptFile) }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
process.arguments = ["-j", "-qq", archive.path, "libspeech.4.dylib", "-d", staging.path]
try process.run()
process.waitUntilExit()
let library = staging.appendingPathComponent("libspeech.4.dylib")
guard process.terminationStatus == 0, try matches(library, expected: libraryHash) else {
  throw CocoaError(.fileReadCorruptFile)
}
try Data(contentsOf: library).write(to: output, options: .atomic)
print("OK: speech library verified")
