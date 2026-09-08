import Darwin
import Foundation
import VoxCore

final class AppInstanceLock {
  enum LockError: Error {
    case alreadyRunning
    case unavailable(Int32)
  }

  private let descriptor: Int32

  init(url: URL) throws {
    try PrivateFileSafety.prepareForAppend(url)
    let directory = url.deletingLastPathComponent()
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else { throw LockError.unavailable(errno) }
    defer { close(directoryFD) }
    let descriptor = openat(
      directoryFD, url.lastPathComponent,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw LockError.unavailable(errno) }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid()
    else {
      close(descriptor)
      throw LockError.unavailable(EINVAL)
    }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      let code = errno
      close(descriptor)
      throw LockError.unavailable(code)
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      close(descriptor)
      if lockError == EWOULDBLOCK { throw LockError.alreadyRunning }
      throw LockError.unavailable(lockError)
    }
    self.descriptor = descriptor
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }

  static var standardURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    return base.appendingPathComponent("vox/resident.lock")
  }
}
