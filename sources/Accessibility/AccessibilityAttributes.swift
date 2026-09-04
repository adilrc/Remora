import ApplicationServices

/// Typed readers for Accessibility attributes, shared by the window tracker and the launch timer.

/// Reads `attribute` from `element` as `Value`, unwrapping `AXValue` geometry and `NSNumber` booleans.
func axValue<Value>(_ element: AXUIElement, attribute: String) -> Value? {
  var raw: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
  guard error == .success, let raw else { return nil }

  if Value.self == AXUIElement.self {
    return (raw as! AXUIElement) as? Value
  }
  if Value.self == Bool.self {
    return (raw as? NSNumber)?.boolValue as? Value
  }
  if Value.self == String.self {
    return (raw as? String) as? Value
  }
  if Value.self == CGPoint.self, CFGetTypeID(raw) == AXValueGetTypeID() {
    var point = CGPoint.zero
    AXValueGetValue(raw as! AXValue, .cgPoint, &point)
    return point as? Value
  }
  if Value.self == CGSize.self, CFGetTypeID(raw) == AXValueGetTypeID() {
    var size = CGSize.zero
    AXValueGetValue(raw as! AXValue, .cgSize, &size)
    return size as? Value
  }
  return raw as? Value
}

func axString(_ element: AXUIElement, attribute: String) -> String {
  axValue(element, attribute: attribute) ?? ""
}

func axBool(_ element: AXUIElement, attribute: String) -> Bool {
  axValue(element, attribute: attribute) ?? false
}

func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
  var raw: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
  guard error == .success, let raw else { return [] }
  guard let array = raw as? [AnyObject] else { return [] }
  return array.compactMap { value in
    if CFGetTypeID(value) == AXUIElementGetTypeID() {
      return (value as! AXUIElement)
    }
    return nil
  }
}

/// Screen frame of an Accessibility window, in top-left-origin screen coordinates.
func axWindowFrame(_ window: AXUIElement) -> CGRect? {
  guard let origin: CGPoint = axValue(window, attribute: kAXPositionAttribute),
        let size: CGSize = axValue(window, attribute: kAXSizeAttribute)
  else {
    return nil
  }
  return CGRect(origin: origin, size: size)
}
