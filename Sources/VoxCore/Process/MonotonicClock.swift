import Foundation

/// Shared production clock for timestamps that cross module boundaries.
public enum VoxMonotonicClock {
  public static func nowSeconds() -> Double { ProcessInfo.processInfo.systemUptime }

  public static func nowMilliseconds() -> Double { nowSeconds() * 1_000 }
}
