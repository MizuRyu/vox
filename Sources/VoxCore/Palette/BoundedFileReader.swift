import Darwin
import Foundation

public enum BoundedFileStatus: Equatable, Sendable {
  case text
  case binary
  case invalidEncoding
  case outsideRoot
  case notRegularFile
  case unavailable
}

public struct BoundedFileResult: Sendable {
  public let status: BoundedFileStatus
  public let lines: [String]
  public let bytesRead: Int
  public let fileSize: UInt64?
}

public enum BoundedFileReader {
  public static func read(
    root: String,
    relativePath: String,
    byteLimit: Int = 64 * 1024,
    lineLimit: Int = 40
  ) -> BoundedFileResult {
    guard !root.isEmpty, !relativePath.hasPrefix("/") else { return result(.outsideRoot) }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(
      String.init)
    guard !components.contains("..") else { return result(.outsideRoot) }
    let rootDescriptor = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard rootDescriptor >= 0 else { return result(.unavailable) }
    defer { close(rootDescriptor) }
    var descriptor = dup(rootDescriptor)
    guard descriptor >= 0 else { return result(.unavailable) }
    for (index, component) in components.enumerated() where component != "." {
      let final = index == components.count - 1
      let next = openat(
        descriptor, component,
        O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
          | (final ? 0 : O_DIRECTORY))
      close(descriptor)
      guard next >= 0 else {
        return result(errno == ELOOP ? .outsideRoot : .unavailable)
      }
      descriptor = next
    }
    defer { close(descriptor) }
    var after = stat()
    guard fstat(descriptor, &after) == 0, (after.st_mode & S_IFMT) == S_IFREG else {
      return result(.notRegularFile)
    }

    let limit = max(0, byteLimit)
    var data = Data(count: limit)
    let count = data.withUnsafeMutableBytes { buffer in
      guard let address = buffer.baseAddress, limit > 0 else { return 0 }
      return Darwin.read(descriptor, address, limit)
    }
    guard count >= 0 else { return result(.unavailable) }
    data.count = count
    let size = UInt64(after.st_size)
    if data.contains(0) {
      return BoundedFileResult(status: .binary, lines: [], bytesRead: count, fileSize: size)
    }

    var text = String(data: data, encoding: .utf8)
    if text == nil, count == limit, UInt64(count) < size {
      for _ in 0..<min(3, data.count) where text == nil {
        data.removeLast()
        text = String(data: data, encoding: .utf8)
      }
    }
    guard let text else {
      return BoundedFileResult(
        status: .invalidEncoding, lines: [], bytesRead: count, fileSize: size)
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      .prefix(max(0, lineLimit)).map(String.init)
    return BoundedFileResult(status: .text, lines: lines, bytesRead: count, fileSize: size)
  }

  private static func result(_ status: BoundedFileStatus) -> BoundedFileResult {
    BoundedFileResult(status: status, lines: [], bytesRead: 0, fileSize: nil)
  }
}
