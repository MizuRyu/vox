// 履歴・診断ログをローカルファイルへ安全に書き読みする判定と手順。
// fd で種類・所有者・リンク数を検査し、書き込み時に 0600 を設定する
// （パスを見てから開くまでの隙に差し替えられないように、必ず fd 越しに検査する）。

import Darwin
import Foundation

public enum PrivateFileSafetyError: Error {
  case symbolicLink(URL)
  case unsafeFile(URL)
  case systemCall(String, Int32)
}

public enum PrivateFileSafety {
  public static func prepareForAppend(_ file: URL) throws {
    let manager = FileManager.default
    let directory = file.deletingLastPathComponent()
    if manager.fileExists(atPath: directory.path) {
      try rejectSymbolicLink(directory)
    } else {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
      try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
  }

  private static func rejectSymbolicLink(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true { throw PrivateFileSafetyError.symbolicLink(url) }
  }
}

public enum PrivateFileIO {
  public struct TailRead: Sendable {
    public let data: Data
    public let truncated: Bool
  }

  public static func append(_ data: Data, to file: URL) throws {
    try PrivateFileSafety.prepareForAppend(file)
    let (directoryFD, name) = try openParent(of: file)
    defer { close(directoryFD) }
    let fd = openat(
      directoryFD, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
      0o600)
    guard fd >= 0 else { throw PrivateFileSafetyError.systemCall("openat", errno) }
    defer { close(fd) }
    try validate(fd: fd, file: file)
    guard fchmod(fd, 0o600) == 0 else {
      throw PrivateFileSafetyError.systemCall("fchmod", errno)
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        guard count > 0 else { throw PrivateFileSafetyError.systemCall("write", errno) }
        offset += count
      }
    }
  }

  /// Intended for small private records. Refuses files larger than the explicit bound.
  public static func read(_ file: URL, maximumBytes: Int = 1024 * 1024) throws -> Data {
    let (directoryFD, name) = try openParent(of: file)
    defer { close(directoryFD) }
    let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw PrivateFileSafetyError.systemCall("openat", errno) }
    defer { close(fd) }
    try validate(fd: fd, file: file)
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw PrivateFileSafetyError.systemCall("fstat", errno)
    }
    guard info.st_size <= maximumBytes else { throw PrivateFileSafetyError.unsafeFile(file) }
    return try readData(fd: fd, maximumBytes: maximumBytes)
  }

  public static func readTail(_ file: URL, maximumBytes: Int) throws -> TailRead {
    precondition(maximumBytes > 0)
    let (directoryFD, name) = try openParent(of: file)
    defer { close(directoryFD) }
    let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw PrivateFileSafetyError.systemCall("openat", errno) }
    defer { close(fd) }
    try validate(fd: fd, file: file)
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw PrivateFileSafetyError.systemCall("fstat", errno)
    }
    let truncated = info.st_size > maximumBytes
    let offset = truncated ? info.st_size - off_t(maximumBytes) : 0
    guard lseek(fd, offset, SEEK_SET) >= 0 else {
      throw PrivateFileSafetyError.systemCall("lseek", errno)
    }
    var data = try readData(fd: fd, maximumBytes: maximumBytes)
    if truncated {
      if let newline = data.firstIndex(of: 0x0A) {
        data.removeSubrange(...newline)
      } else {
        data.removeAll(keepingCapacity: false)
      }
    }
    return TailRead(data: data, truncated: truncated)
  }

  private static func openParent(of file: URL) throws -> (Int32, String) {
    let directory = file.deletingLastPathComponent()
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw PrivateFileSafetyError.systemCall("open-parent", errno) }
    return (fd, file.lastPathComponent)
  }

  private static func validate(fd: Int32, file: URL) throws {
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw PrivateFileSafetyError.systemCall("fstat", errno)
    }
    guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid() else {
      throw PrivateFileSafetyError.unsafeFile(file)
    }
  }

  private static func readData(fd: Int32, maximumBytes: Int) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(16 * 1024, maximumBytes))
    while result.count < maximumBytes {
      let wanted = min(buffer.count, maximumBytes - result.count)
      let count = Darwin.read(fd, &buffer, wanted)
      guard count >= 0 else { throw PrivateFileSafetyError.systemCall("read", errno) }
      if count == 0 { break }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }
}
