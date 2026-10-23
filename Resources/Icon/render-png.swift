// SVG → PNG. 사용: swift render-png.swift 입력.svg 출력.png 크기   (또는 가로x세로, 예: 1200x630)
import AppKit
let args = CommandLine.arguments
let dims = args.count == 4 ? args[3].split(separator: "x").compactMap { Int($0) } : []
guard dims.count == 1 || dims.count == 2, let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: render-png.swift in.svg out.png size\n".data(using: .utf8)!); exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dims[0], pixelsHigh: dims.last!, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: dims[0], height: dims.last!))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
