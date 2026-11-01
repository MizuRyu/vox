import AVFoundation
import AppKit
import CoreVideo
import CoreText

NSApplication.shared.setActivationPolicy(.prohibited)

struct MovieSpec: Decodable {
  let slug: String
  let name: String
  let icon: String
  let repository: String
  let duration: Double
  let sceneStarts: [Double]
  let demo: [String: String]
  let locales: [String: [String: String]]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 || arguments.count == 4 else {
  fatalError("Usage: render <movie.json> <locale> <output-directory> [--stills]")
}
let configURL = URL(fileURLWithPath: arguments[0])
let spec = try JSONDecoder().decode(MovieSpec.self, from: Data(contentsOf: configURL))
let locale = arguments[1]
guard let strings = spec.locales[locale] else { fatalError("Unsupported locale: \(locale)") }
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let duration = spec.duration
let fps: Int32 = 30
let width = 1920
let height = 1080
let iconURL = configURL.deletingLastPathComponent().appendingPathComponent(spec.icon)
guard let icon = NSImage(contentsOf: iconURL) else { fatalError("Cannot load product icon") }
let demoVoice = spec.demo["voice"]!
let demoTyped = spec.demo["typed"]!
let demoPath = spec.demo["path"]!

@MainActor
func copy(_ key: String) -> String {
  guard let value = strings[key] else { fatalError("Missing copy: \(key)") }
  return value
}

struct TextLayout {
  var width: CGFloat = 1200
  var alignment: NSTextAlignment = .left
  var monospaced = false
}

@MainActor
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 255) / 255,
    green: CGFloat((hex >> 8) & 255) / 255,
    blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let ink = color(0x272820)
let muted = color(0x848379)
let gold = color(0x9A7B42)
let paper = color(0xF5F4EE)
let blue = color(0x4176A5)
let red = color(0xD75A4C)

@MainActor
func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
@MainActor
func ease(_ x: Double) -> Double {
  let x = clamp(x)
  return 1 - pow(1 - x, 3)
}
@MainActor
func smooth(_ x: Double) -> Double {
  let x = clamp(x)
  return x * x * (3 - 2 * x)
}
@MainActor
func reveal(_ value: String, _ t: Double, _ length: Double) -> String {
  String(value.prefix(Int(Double(value.count) * clamp(t / length))))
}

@MainActor
func text(
  _ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
  _ weight: NSFont.Weight = .regular, _ tint: NSColor = ink,
  layout: TextLayout = TextLayout()
) {
  let font = layout.monospaced
    ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    : NSFont.systemFont(ofSize: size, weight: weight)
  let line = textLine(value, font: font, tint: tint)
  var ascent: CGFloat = 0
  let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
  let offset = layout.alignment == .center ? (layout.width - width) / 2 : 0
  let context = NSGraphicsContext.current!.cgContext
  context.saveGState()
  context.clip(to: CGRect(x: x, y: y, width: layout.width, height: size * 2))
  context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
  context.textPosition = CGPoint(x: x + offset, y: y + ascent)
  CTLineDraw(line, context)
  context.restoreGState()
}

@MainActor
func textLine(_ value: String, font: NSFont, tint: NSColor = ink) -> CTLine {
  let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font as CTFont,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): tint.cgColor
  ]
  return CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
}

@MainActor
func textWidth(_ value: String, font: NSFont) -> CGFloat {
  CGFloat(CTLineGetTypographicBounds(textLine(value, font: font), nil, nil, nil))
}

@MainActor
func box(_ rect: CGRect, _ fill: NSColor, radius: CGFloat = 0, stroke: NSColor? = nil) {
  let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  fill.setFill()
  path.fill()
  if let stroke {
    stroke.setStroke()
    path.lineWidth = 1
    path.stroke()
  }
}
@MainActor
func line(_ from: CGPoint, _ to: CGPoint, _ tint: NSColor, _ lineWidth: CGFloat = 1) {
  let path = NSBezierPath()
  path.move(to: from)
  path.line(to: to)
  path.lineWidth = lineWidth
  tint.setStroke()
  path.stroke()
}
@MainActor
func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ tint: NSColor) {
  tint.setFill()
  NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    .fill()
}
@MainActor
func layer(
  _ opacity: Double = 1, x: CGFloat = 0, y: CGFloat = 0, scale: CGFloat = 1, _ draw: () -> Void
) {
  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext.current!.cgContext
  context.setAlpha(CGFloat(clamp(opacity)))
  context.translateBy(x: x, y: y)
  context.scaleBy(x: scale, y: scale)
  draw()
  NSGraphicsContext.restoreGraphicsState()
}
@MainActor
func shadow(_ draw: () -> Void) {
  NSGraphicsContext.saveGraphicsState()
  let s = NSShadow()
  s.shadowColor = color(0x343225, 0.11)
  s.shadowBlurRadius = 28
  s.shadowOffset = NSSize(width: 0, height: -12)
  s.set()
  draw()
  NSGraphicsContext.restoreGraphicsState()
}
@MainActor
func key(_ value: String, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 44, active: Bool = false) {
  box(
    CGRect(x: x, y: y, width: width, height: 29), active ? ink : color(0xECECE6),
    radius: 6, stroke: active ? ink : color(0xDADBD3))
  text(
    value, x, y + 5, 12, .medium, active ? paper : muted,
    layout: TextLayout(width: width, alignment: .center, monospaced: true))
}
@MainActor
func symbol(_ name: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, tint: NSColor) {
  guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
  let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
    .applying(.init(hierarchicalColor: tint))
  image.withSymbolConfiguration(config)?.draw(
    in: CGRect(x: x, y: y, width: size, height: size),
    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}
@MainActor
func logo(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
  icon.draw(
    in: CGRect(x: x, y: y, width: size, height: size), from: .zero,
    operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}
@MainActor
func waveform(
  _ x: CGFloat, _ y: CGFloat, t: Double, tint: NSColor = muted, count: Int = 28,
  height: CGFloat = 20
) {
  for i in 0..<count {
    let envelope = 0.25 + 0.75 * sin(Double(i + 1) / Double(count + 1) * .pi)
    let h = CGFloat(0.2 + 0.8 * abs(sin(Double(i) * 1.8 + t * 7))) * height * envelope
    box(
      CGRect(x: x + CGFloat(i) * 5, y: y - h / 2, width: 2.8, height: max(2, h)), tint, radius: 1.4)
  }
}
@MainActor
func chrome(_ time: Double, dark: Bool = false) {
  let secondary = dark ? color(0x9A9C91) : muted
  text(spec.name, 64, 38, 27, .semibold, dark ? paper : ink)
  text("LOCAL VOICE INPUT", 132, 48, 10, .medium, secondary, layout: TextLayout(monospaced: true))
  text("macOS", 1140, 46, 12, .medium, secondary)
  line(CGPoint(x: 64, y: 82), CGPoint(x: 1216, y: 82), dark ? color(0x33372D) : color(0xE1E1D8))
  text(copy("footer"), 64, 676, 11, .regular, secondary)
  text(
    String(format: "%02d / %02d", Int(min(duration, time)), Int(duration)), 1140, 676, 11, .medium,
    secondary, layout: TextLayout(monospaced: true))
  box(
    CGRect(x: 64, y: 703, width: 1152 * clamp(time / duration), height: 2),
    dark ? color(0xA69770) : gold)
}
@MainActor
func eyebrow(_ number: String, _ value: String, y: CGFloat = 119) {
  text(number, 92, y + 2, 12, .medium, gold, layout: TextLayout(monospaced: true))
  text(value, 130, y, 14, .medium, muted)
}
@MainActor
func hud(
  _ t: Double, y: CGFloat = 340, voice: String, typed: String = "", path: String = "",
  tentative: Bool = false, active: Bool = false
) {
  let x: CGFloat = 200
  let w: CGFloat = 880
  shadow { box(CGRect(x: x, y: y, width: w, height: 168), color(0xFFFFFF), radius: 18) }
  box(
    CGRect(x: x, y: y, width: w, height: 168), color(0xFFFFFF), radius: 18, stroke: color(0xDEDFD6))
  circle(x + 28, y + 28, 4, red)
  text("録音中", x + 42, y + 19, 13, .medium, muted)
  waveform(x + 112, y + 29, t: t, count: 24, height: 16)
  symbol("gearshape", x + w - 72, y + 20, size: 17, tint: muted)
  symbol("chevron.up", x + w - 40, y + 24, size: 13, tint: muted)
  text(
    voice, x + 26, y + 62, 25, .medium, tentative ? color(0x999B90) : ink,
    layout: TextLayout(width: w - 52))
  if !typed.isEmpty {
    let vwidth = textWidth(voice, font: NSFont.systemFont(ofSize: 25, weight: .medium))
    let tx = x + 26 + vwidth + 5
    let tw = textWidth(typed, font: NSFont.systemFont(ofSize: 25, weight: .medium))
    box(CGRect(x: tx - 2, y: y + 61, width: tw + 5, height: 35), color(0xE9DFC4), radius: 4)
    text(typed, tx, y + 62, 25, .medium, ink, layout: TextLayout(width: w - 52 - vwidth))
  }
  if !path.isEmpty {
    text(
      path, x + 27, y + 99, 16, .medium, blue, layout: TextLayout(width: w - 50, monospaced: true))
  }
  key("⌘⇧Space", x + 25, y + 126, width: 101, active: active)
  text("確定して貼り付け", x + 136, y + 132, 11, .regular, muted)
  key("@", x + 270, y + 126, width: 28)
  text("ファイル", x + 307, y + 132, 11, .regular, muted)
  key("esc", x + 390, y + 126, width: 38)
  text("破棄", x + 439, y + 132, 11, .regular, muted)
}
@MainActor
func appCard(_ y: CGFloat, pasted: Bool, alpha: Double = 1) {
  layer(alpha) {
    shadow { box(CGRect(x: 230, y: y, width: 820, height: 215), color(0xFFFFFF), radius: 17) }
    box(
      CGRect(x: 230, y: y, width: 820, height: 215), color(0xFFFFFF), radius: 17,
      stroke: color(0xDEDFD6))
    for i in 0..<3 { circle(253 + CGFloat(i) * 15, y + 22, 4, color(0xD8D9D0)) }
    text(
      "いつもの入力欄", 520, y + 12, 13, .medium, muted, layout: TextLayout(width: 240, alignment: .center)
    )
    line(CGPoint(x: 230, y: y + 44), CGPoint(x: 1050, y: y + 44), color(0xEEEEEA))
    if pasted {
      text(demoVoice, 262, y + 73, 25, .medium)
      text(demoTyped, 262, y + 113, 25, .medium)
      text(demoPath, 262, y + 160, 17, .medium, blue, layout: TextLayout(monospaced: true))
    } else {
      text("変更したいことを入力…", 262, y + 85, 24, .regular, color(0xB2B4A8))
      box(CGRect(x: 263, y: y + 90, width: 2, height: 28), gold, radius: 1)
    }
  }
}
@MainActor
func palette(_ t: Double) {
  let x: CGFloat = 315
  let y: CGFloat = 274
  let w: CGFloat = 650
  let h: CGFloat = 276
  shadow { box(CGRect(x: x, y: y, width: w, height: h), ink, radius: 18) }
  box(CGRect(x: x, y: y, width: w, height: h), ink, radius: 18, stroke: color(0x4B4E42))
  circle(x + 24, y + 24, 3.5, red)
  text("音声入力は録音中のまま", x + 37, y + 15, 12, .medium, color(0xBCBFB0))
  text(
    "/ExampleProject", x + w - 185, y + 16, 12, .regular, color(0x929787),
    layout: TextLayout(monospaced: true))
  box(CGRect(x: x + 18, y: y + 47, width: w - 36, height: 45), color(0x3B3E33), radius: 8)
  text("@", x + 32, y + 56, 21, .semibold, color(0xC7AC72), layout: TextLayout(monospaced: true))
  text(
    reveal("settings", t - 0.35, 0.65), x + 62, y + 58, 19, .medium, paper,
    layout: TextLayout(monospaced: true))
  text("Changes", x + 24, y + 111, 13, .regular, color(0x969B8A))
  text("Tree", x + 118, y + 111, 13, .medium, paper)
  line(CGPoint(x: x + 118, y: y + 135), CGPoint(x: x + 150, y: y + 135), color(0xC7AC72), 2)
  text(
    "Sources / Settings", x + 28, y + 149, 13, .regular, color(0x969B8A),
    layout: TextLayout(monospaced: true))
  let selected = t > 1.2
  box(
    CGRect(x: x + 18, y: y + 174, width: w - 36, height: 38),
    selected ? color(0x4B523F) : color(0x303329), radius: 7)
  symbol("doc.text", x + 30, y + 183, size: 18, tint: color(0xBEC4AF))
  text(
    "SettingsView.swift", x + 60, y + 182, 17, .medium, paper, layout: TextLayout(monospaced: true))
  if selected { symbol("checkmark", x + w - 52, y + 185, size: 15, tint: color(0xE4DBBA)) }
  key("↵", x + 23, y + 230, width: 35, active: false)
  text("パスを挿入", x + 70, y + 237, 11, .regular, color(0xB0B7A2))
}

@MainActor
func introScene(_ t: Double, _ absolute: Double) {
  let p = ease(t / 1.1)
  layer(p, y: CGFloat(22 * (1 - p))) {
    text(copy("introFirst"), 90, 164, locale == "en" ? 65 : 76, .semibold, ink)
    text(copy("introSecond"), 90, 254, 76, .semibold, ink)
  }
  layer(ease((t - 0.6) / 0.8)) {
    text(copy("introSubtitle"), 95, 382, 21, .regular, muted)
    logo(860, 185, 250)
    waveform(867, 461, t: t, tint: gold, count: 44, height: 45)
  }
  layer(ease((t - 1.2) / 0.6)) {
    key("⌘⇧Space", 96, 475, width: 126, active: t > 2.3)
    text(copy("startHint"), 238, 480, 17, .regular, muted)
  }

}

@MainActor
func typingScene(_ t: Double, _ absolute: Double) {
  eyebrow("01", copy("typingEyebrow"))
  text(copy("typingTitle"), 90, 167, 48, .semibold)
  text(copy("typingSubtitle"), 94, 238, 18, .regular, muted)
  let voice = reveal(demoVoice, t - 0.2, 2.8)
  let typed = reveal(demoTyped, t - 1.1, 1.0)
  hud(absolute, voice: voice, typed: typed, tentative: t < 3.4)
  layer(ease((t - 1.1) / 0.4)) {
    let font = NSFont.systemFont(ofSize: 25, weight: .medium)
    let vw = textWidth(voice, font: font)
    let tw = textWidth(typed, font: font)
    line(CGPoint(x: 231 + vw + tw / 2, y: 443), CGPoint(x: 950, y: 548), color(0xB8A47D))
    text(copy("typedLabel"), 900, 563, 14, .medium, gold)
  }

}

@MainActor
func filesScene(_ t: Double, _ absolute: Double) {
  eyebrow("02", copy("filesEyebrow"))
  text(copy("filesTitle"), 90, 167, 45, .semibold)
  if t < 3.35 {
    layer(ease(t / 0.45), y: CGFloat(20 * (1 - ease(t / 0.45)))) { palette(t) }
    text(copy("filesSubtitle"), 92, 592, 18, .regular, muted)
    key("@", 1076, 577, width: 42, active: true)
    text(copy("searchLabel"), 1130, 583, 12, .regular, muted, layout: TextLayout(width: 130))
  } else {
    layer(ease((t - 3.35) / 0.45), y: CGFloat(16 * (1 - ease((t - 3.35) / 0.45)))) {
      hud(
        absolute, y: 330, voice: demoVoice, typed: demoTyped,
        path: demoPath)
    }
    text(copy("pathSubtitle"), 94, 567, 20, .regular, muted)
  }

}

@MainActor
func pasteScene(_ t: Double, _ absolute: Double) {
  eyebrow("03", copy("pasteEyebrow"))
  text(copy("pasteTitle"), 90, 167, 45, .semibold)
  let pasted = t > 2.25
  appCard(280, pasted: pasted)
  if !pasted {
    layer(1, x: CGFloat(125), y: CGFloat(338), scale: 0.72) {
      hud(
        absolute, y: 270, voice: demoVoice, typed: demoTyped,
        path: demoPath, active: t > 1.8)
    }
  } else {
    layer(ease((t - 2.25) / 0.5)) {
      symbol("checkmark.circle", 540, 553, size: 23, tint: gold)
      text(copy("pastedLabel"), 576, 553, 17, .medium, gold)
    }
  }

}

@MainActor
func localScene(_ t: Double, _ absolute: Double) {
  text(copy("localFirst"), 90, 164, locale == "en" ? 54 : 64, .semibold, paper)
  text(copy("localSecond"), 90, 248, locale == "en" ? 54 : 58, .semibold, paper)
  text(copy("localSubtitle"), 95, 369, 20, .regular, color(0xAEB3A3))
  text("Haas / Apple", 96, 430, 17, .medium, color(0xD1C5A4), layout: TextLayout(monospaced: true))
  let cx: CGFloat = 990
  let cy: CGFloat = 327
  for i in 0..<5 {
    let r: CGFloat = CGFloat(93 + i * 14) + CGFloat(sin(t * 0.9 + Double(i)) * 3)
    let rect = CGRect(x: cx - r, y: cy - r * 0.51, width: r * 2, height: r * 1.02)
    let path = NSBezierPath(ovalIn: rect)
    color(0xA6A78F, CGFloat(0.20 - Double(i) * 0.028)).setStroke()
    path.lineWidth = 1
    path.stroke()
  }
  box(
    CGRect(x: 922, y: 257, width: 136, height: 136), color(0x33392B), radius: 26,
    stroke: color(0x69705A))
  symbol("lock.fill", 967, 301, size: 46, tint: color(0xD6CCAD))
  text(copy("downloadNote"), 95, 553, 12, .regular, color(0x818A74))

}

@MainActor
func outroScene(_ t: Double, _ absolute: Double) {
  let p = ease(t / 0.9)
  layer(p, y: CGFloat(20 * (1 - p))) {
    logo(345, 162, 200)
    text(spec.name, 573, 199, 113, .semibold, ink)
    text(
      copy("outro"), 0, 397, 38, .medium, ink, layout: TextLayout(width: 1280, alignment: .center))
    text(
      "macOS 26+  /  Apple Silicon  /  MIT", 0, 471, 14, .medium, muted,
      layout: TextLayout(width: 1280, alignment: .center, monospaced: true))
    box(CGRect(x: 438, y: 533, width: 404, height: 52), ink, radius: 26)
    text(
      spec.repository, 438, 549, 16, .medium, paper,
      layout: TextLayout(width: 404, alignment: .center, monospaced: true))
  }
}

@MainActor
func scene(_ index: Int, _ t: Double, _ absolute: Double) {
  switch index {
  case 0: introScene(t, absolute)
  case 1: typingScene(t, absolute)
  case 2: filesScene(t, absolute)
  case 3: pasteScene(t, absolute)
  case 4: localScene(t, absolute)
  default: outroScene(t, absolute)
  }
}

let starts = spec.sceneStarts
@MainActor
func drawFrame(_ context: CGContext, _ time: Double) {
  NSGraphicsContext.saveGraphicsState()
  context.translateBy(x: 0, y: CGFloat(height))
  context.scaleBy(x: 1.5, y: -1.5)
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
  let index = starts.lastIndex(where: { $0 <= time }) ?? 0
  let dark = index == 4
  box(CGRect(x: 0, y: 0, width: 1280, height: 720), dark ? color(0x1E241B) : paper)
  // The ruled corners keep the composition anchored while the product UI moves.
  for x: CGFloat in [64, 1216] {
    line(CGPoint(x: x, y: 92), CGPoint(x: x, y: 652), dark ? color(0x2A3125) : color(0xEDEDE5))
  }
  chrome(time, dark: dark)
  let local = time - starts[index]
  let entrance = index == 0 ? 1 : ease(local / 0.42)
  let end = index < starts.count - 1 ? starts[index + 1] : duration
  let exit = index == starts.count - 1 ? 1 : smooth((end - time) / 0.28)
  layer(entrance * exit, y: CGFloat(14 * (1 - entrance))) { scene(index, local, time) }
  NSGraphicsContext.restoreGraphicsState()
}

@MainActor
func png(_ time: Double, _ name: String) throws {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: width * 4, bitsPerPixel: 32)!
  let context = CGContext(
    data: bitmap.bitmapData, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: bitmap.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  drawFrame(context, time)
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: output.appendingPathComponent(name))
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
if arguments.last == "--stills" {
  for (i, time) in [2.0, 6.6, 9.8, 12.3, 16.7, 19.8, 23.7].enumerated() {
    try png(time, "scene-\(i+1).png")
  }
  try png(6.6, "poster.png")
  print("OK: rendered seven storyboard frames and poster")
  exit(0)
}

let url = output.appendingPathComponent("silent.mp4")
if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
let input = AVAssetWriterInput(
  mediaType: .video,
  outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
      AVVideoAverageBitRateKey: 5_000_000,
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      AVVideoMaxKeyFrameIntervalKey: 60
    ]
  ])
input.expectsMediaDataInRealTime = false
let adapter = AVAssetWriterInputPixelBufferAdaptor(
  assetWriterInput: input,
  sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
  ])
writer.add(input)
guard writer.startWriting() else {
  fatalError("Writer start failed: \(String(describing: writer.error))")
}
writer.startSession(atSourceTime: .zero)
for frame in 0..<Int(duration * Double(fps)) {
  while !input.isReadyForMoreMediaData {
    guard writer.status == .writing else {
      fatalError("Writer failed: \(String(describing: writer.error))")
    }
    Thread.sleep(forTimeInterval: 0.002)
  }
  try autoreleasepool {
    var buffer: CVPixelBuffer?
    guard
      CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &buffer)
        == kCVReturnSuccess,
      let buffer
    else { fatalError("Pixel buffer allocation failed") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    drawFrame(context, Double(frame) / Double(fps))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
    else { throw writer.error ?? NSError(domain: "Video", code: 1) }
  }
  if frame % 150 == 0 { print("Rendered \(frame)/\(Int(duration * Double(fps)))") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else {
  fatalError("Writer failed: \(String(describing: writer.error))")
}
print("OK: rendered \(locale), \(duration)s, synthesized UI only")
