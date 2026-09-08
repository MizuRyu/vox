import Darwin
import Foundation
import VoxCore

final class AppLogRouter {
  private static let maximumBytes: off_t = 2 * 1024 * 1024
  private let descriptor: Int32
  private var timer: DispatchSourceTimer?
  let url: URL

  private init(descriptor: Int32, url: URL) {
    self.descriptor = descriptor
    self.url = url
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60))
    timer.setEventHandler { [descriptor] in Self.enforceBound(descriptor) }
    // Close only after any queued timer callback has finished using this descriptor.
    timer.setCancelHandler { close(descriptor) }
    timer.resume()
    self.timer = timer
  }

  deinit {
    timer?.cancel()
  }

  static func install(applicationSupport: URL? = nil) throws -> AppLogRouter {
    let base = applicationSupport ??
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    let url = base.appendingPathComponent("vox/logs/vox.log")
    let baseFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard baseFD >= 0 else { throw PrivateFileSafetyError.systemCall("open-log-base", errno) }
    defer { close(baseFD) }
    let voxFD = try openPrivateDirectory(parent: baseFD, name: "vox")
    defer { close(voxFD) }
    let logsFD = try openPrivateDirectory(parent: voxFD, name: "logs")
    defer { close(logsFD) }
    let descriptor = openat(
      logsFD, url.lastPathComponent,
      O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw PrivateFileSafetyError.systemCall("open-log", errno) }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid()
    else {
      close(descriptor)
      throw PrivateFileSafetyError.unsafeFile(url)
    }
    guard fchmod(descriptor, 0o600) == 0 else {
      let code = errno
      close(descriptor)
      throw PrivateFileSafetyError.systemCall("chmod-log", code)
    }
    enforceBound(descriptor)
    guard dup2(descriptor, STDERR_FILENO) >= 0 else {
      let code = errno
      close(descriptor)
      throw PrivateFileSafetyError.systemCall("redirect-stderr", code)
    }
    return AppLogRouter(descriptor: descriptor, url: url)
  }

  private static func enforceBound(_ descriptor: Int32) {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_size > maximumBytes else { return }
    _ = ftruncate(descriptor, 0)
  }

  private static func openPrivateDirectory(parent: Int32, name: String) throws -> Int32 {
    if mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
      throw PrivateFileSafetyError.systemCall("create-log-directory", errno)
    }
    let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw PrivateFileSafetyError.systemCall("open-log-directory", errno)
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0
    else {
      close(descriptor)
      throw PrivateFileSafetyError.unsafeFile(URL(fileURLWithPath: name))
    }
    guard fchmod(descriptor, 0o700) == 0 else {
      let code = errno
      close(descriptor)
      throw PrivateFileSafetyError.systemCall("chmod-log-directory", code)
    }
    return descriptor
  }
}
