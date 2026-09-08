import AppKit
import VoxCore

/// Read only the captured input, with a short AX timeout. No text escapes this transient snapshot.
enum AccessibleInput {
  static func snapshot(_ element: AXUIElement?) -> TextInsertionSnapshot? {
    guard let element, AXUIElementSetMessagingTimeout(element, 0.05) == .success,
      let role = attribute(element, kAXRoleAttribute) as? String,
      [kAXTextFieldRole, kAXTextAreaRole].contains(role),
      subroleState(element).allowsTextInspection,
      let countValue = attribute(element, kAXNumberOfCharactersAttribute),
      CFGetTypeID(countValue) == CFNumberGetTypeID()
    else { return nil }
    var count = 0
    guard CFNumberGetValue(unsafeDowncast(countValue, to: CFNumber.self), .cfIndexType, &count),
      count >= 0, count <= AutoEnterPlan.maximumUTF16Length,
      let value = attribute(element, kAXValueAttribute) as? String,
      value.utf16.count == count,
      let rangeValue = attribute(element, kAXSelectedTextRangeAttribute),
      CFGetTypeID(rangeValue) == AXValueGetTypeID()
    else { return nil }
    let axRange = unsafeDowncast(rangeValue, to: AXValue.self)
    var range = CFRange()
    guard AXValueGetType(axRange) == .cfRange, AXValueGetValue(axRange, .cfRange, &range),
      range.location >= 0, range.length >= 0,
      range.location <= count, range.length <= count - range.location
    else { return nil }
    return TextInsertionSnapshot(value: value,
      selection: NSRange(location: range.location, length: range.length))
  }

  private static func subroleState(_ element: AXUIElement) -> InputSubroleState {
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) {
    case .noValue, .attributeUnsupported: return .missing
    case .success:
      guard let name = value as? String else { return .failed }
      return .named(name)
    default: return .failed
    }
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }
}
