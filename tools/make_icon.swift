// Renders the 白手套 app icon: black square, white bold 手 centred, red status square bottom-right.
// usage: swift tools/make_icon.swift <out.png> [size=1024]
// The red square is the widget's 8pt status square at home-screen scale (8pt on a 60pt icon),
// so it stays visible; at a literal 8px on 1024 it would vanish below one pixel.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make_icon.swift <out.png> [size]"); exit(2) }
let size = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
let s = CGFloat(size)

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }

ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

// System bold; CJK falls back to PingFang SC.
let base = CTFontCreateUIFontForLanguage(.system, s * 0.6, "zh-Hans" as CFString)!
let traits = [kCTFontWeightTrait: 0.4] as CFDictionary
let desc = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
let font = CTFontCreateCopyWithAttributes(base, s * 0.6, nil, desc)
let text = NSAttributedString(string: "手", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
])
let line = CTLineCreateWithAttributedString(text)
let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.textPosition = CGPoint(x: (s - glyphBounds.width) / 2 - glyphBounds.minX,
                           y: (s - glyphBounds.height) / 2 - glyphBounds.minY)
CTLineDraw(line, ctx)

let square = s * 8 / 60
let inset = s * 0.14   // clear of the iOS corner mask
ctx.setFillColor(CGColor(srgbRed: 1, green: 0x2d / 255.0, blue: 0x20 / 255.0, alpha: 1))
ctx.fill(CGRect(x: s - inset - square, y: inset, width: square, height: square))

let out = URL(fileURLWithPath: args[1]) as CFURL
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out, UTType.png.identifier as CFString, 1, nil) else { fatalError("no image") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(args[1]) \(size)px")
