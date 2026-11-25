import CoreGraphics
import Foundation
import ImageIO

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let size = 1024
let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                       space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
canvas.translateBy(x: 0, y: 1024)
canvas.scaleBy(x: 1, y: -1)

func rgb(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
}

func round(_ rectangle: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rectangle, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ path: CGPath, _ color: CGColor) {
    canvas.addPath(path)
    canvas.setFillColor(color)
    canvas.fillPath()
}

func line(_ points: [CGPoint], width: CGFloat, color: CGColor, closed: Bool = false) {
    canvas.beginPath()
    canvas.addLines(between: points)
    if closed { canvas.closePath() }
    canvas.setLineWidth(width)
    canvas.setLineCap(.round)
    canvas.setLineJoin(.round)
    canvas.setStrokeColor(color)
    canvas.strokePath()
}

func gradient(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    canvas.saveGState()
    canvas.addPath(path)
    canvas.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    canvas.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    canvas.restoreGState()
}

let body = round(CGRect(x: 104, y: 96, width: 816, height: 816), 183)
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x0C3028, 0.36))
fill(body, rgb(0x0F342B))
canvas.restoreGState()
gradient(body, [rgb(0x377864), rgb(0x235549), rgb(0x133D33), rgb(0x0E2B25)],
         from: CGPoint(x: 152, y: 115), to: CGPoint(x: 827, y: 927))

canvas.saveGState()
canvas.addPath(body)
canvas.clip()
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xBCEFDA, 0.28), rgb(0x98E6C6, 0)] as CFArray, locations: nil)!
canvas.drawRadialGradient(glow, startCenter: CGPoint(x: 270, y: 176), startRadius: 4,
                          endCenter: CGPoint(x: 320, y: 257), endRadius: 510,
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
canvas.restoreGState()

canvas.addPath(round(CGRect(x: 106, y: 98, width: 812, height: 812), 181))
canvas.setStrokeColor(rgb(0xD4F6E3, 0.30))
canvas.setLineWidth(4)
canvas.strokePath()

let screen = round(CGRect(x: 260, y: 289, width: 503, height: 348), 41)
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -16), blur: 32, color: rgb(0x081F19, 0.46))
fill(screen, rgb(0x0A3026))
canvas.restoreGState()
gradient(screen, [rgb(0x326452), rgb(0x143C32)], from: CGPoint(x: 299, y: 293), to: CGPoint(x: 719, y: 650))
canvas.addPath(screen)
canvas.setStrokeColor(rgb(0xE0F8EC, 0.96))
canvas.setLineWidth(20)
canvas.strokePath()
fill(round(CGRect(x: 482, y: 314, width: 57, height: 7), 3.5), rgb(0xB0DDCA, 0.65))

let base = CGMutablePath()
base.move(to: CGPoint(x: 217, y: 637))
base.addLine(to: CGPoint(x: 804, y: 637))
base.addQuadCurve(to: CGPoint(x: 827, y: 656), control: CGPoint(x: 829, y: 637))
base.addQuadCurve(to: CGPoint(x: 771, y: 692), control: CGPoint(x: 804, y: 692))
base.addLine(to: CGPoint(x: 251, y: 692))
base.addQuadCurve(to: CGPoint(x: 196, y: 656), control: CGPoint(x: 221, y: 692))
base.addQuadCurve(to: CGPoint(x: 217, y: 637), control: CGPoint(x: 191, y: 637))
base.closeSubpath()
gradient(base, [rgb(0xE7FFF0), rgb(0xAAE0CA)], from: CGPoint(x: 512, y: 639), to: CGPoint(x: 512, y: 702))
fill(round(CGRect(x: 471, y: 640, width: 81, height: 9), 4.5), rgb(0x457E67, 0.46))

let dial = CGPath(ellipseIn: CGRect(x: 586, y: 459, width: 227, height: 227), transform: nil)
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -11), blur: 25, color: rgb(0x082B22, 0.62))
fill(dial, rgb(0x1E5444))
canvas.restoreGState()
gradient(dial, [rgb(0x276451), rgb(0x123A31)], from: CGPoint(x: 601, y: 479), to: CGPoint(x: 799, y: 689))
canvas.addPath(dial)
canvas.setStrokeColor(rgb(0xCDFAE1))
canvas.setLineWidth(17)
canvas.strokePath()
line([CGPoint(x: 700, y: 507), CGPoint(x: 700, y: 573), CGPoint(x: 739, y: 599)],
     width: 15, color: rgb(0xE9FFF1))

let image = canvas.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                  "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination))
