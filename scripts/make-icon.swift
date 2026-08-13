#!/usr/bin/env swift
//
// Renders the Baton app icon and builds Baton.icns.
//
// The icon is generated, not committed as a binary blob, so a change to it is a
// code review instead of a file swap.
//
// Usage:
//   swift scripts/make-icon.swift            Write dist/Baton.icns
//   swift scripts/make-icon.swift --preview  Also write dist/icon-preview.png
//
// Design: the app's own shape. A glass tab hangs from the top edge of a deep
// indigo field, with one warm dot for a waiting task. At 16 points that reads as
// a white tab with a dot, which is the whole product in one glyph.

import AppKit
import Foundation

// MARK: - Geometry

/// A squircle, not a rounded rectangle. Apple's continuous corner curve is a
/// superellipse, and the difference shows at 1024 points.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let halfWidth = rect.width / 2
    let halfHeight = rect.height / 2
    let centerX = rect.midX
    let centerY = rect.midY
    let steps = 720

    for step in 0...steps {
        let theta = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(theta)
        let sine = sin(theta)
        // |x/a|^n + |y/b|^n = 1
        let pointX = centerX + halfWidth * pow(abs(cosine), 2 / exponent) * (cosine < 0 ? -1 : 1)
        let pointY = centerY + halfHeight * pow(abs(sine), 2 / exponent) * (sine < 0 ? -1 : 1)
        if step == 0 {
            path.move(to: CGPoint(x: pointX, y: pointY))
        } else {
            path.addLine(to: CGPoint(x: pointX, y: pointY))
        }
    }
    path.closeSubpath()
    return path
}

/// The notch tab. Square at the top edge, rounded at the bottom, with concave
/// shoulders. This mirrors `NotchShape` in the app.
func notchTab(width: CGFloat, height: CGFloat, top: CGFloat, centerX: CGFloat) -> CGPath {
    let shoulder = height * 0.42
    let bottom = height * 0.46
    let left = centerX - width / 2
    let right = centerX + width / 2
    // Core Graphics is y-up here, so `top` is the larger y value.
    let bottomY = top - height

    let path = CGMutablePath()
    path.move(to: CGPoint(x: left - shoulder, y: top))
    path.addQuadCurve(to: CGPoint(x: left, y: top - shoulder), control: CGPoint(x: left, y: top))
    path.addLine(to: CGPoint(x: left, y: bottomY + bottom))
    path.addQuadCurve(to: CGPoint(x: left + bottom, y: bottomY), control: CGPoint(x: left, y: bottomY))
    path.addLine(to: CGPoint(x: right - bottom, y: bottomY))
    path.addQuadCurve(to: CGPoint(x: right, y: bottomY + bottom), control: CGPoint(x: right, y: bottomY))
    path.addLine(to: CGPoint(x: right, y: top - shoulder))
    path.addQuadCurve(to: CGPoint(x: right + shoulder, y: top), control: CGPoint(x: right, y: top))
    path.closeSubpath()
    return path
}

// MARK: - Layers

/// The plate: shadow, gradient, and a highlight along the top edge.
func drawPlate(_ context: CGContext, plate: CGRect, path platePath: CGPath) {
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10),
        blur: 28,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30)
    )
    context.addPath(platePath)
    context.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.24, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(platePath)
    context.clip()

    // Indigo to violet, top to bottom.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 0.36, green: 0.31, blue: 0.86, alpha: 1),
            CGColor(red: 0.20, green: 0.16, blue: 0.55, alpha: 1),
            CGColor(red: 0.11, green: 0.09, blue: 0.32, alpha: 1),
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )

    // A soft highlight, so the plate reads as glass.
    let highlight = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        highlight,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.maxY - plate.height * 0.42),
        options: []
    )
    context.restoreGState()
}

/// The tab hangs from the top of the plate, exactly like the real notch.
func drawTab(_ context: CGContext, plate: CGRect, platePath: CGPath, width: CGFloat, height: CGFloat) {
    let tab = notchTab(width: width, height: height, top: plate.maxY, centerX: plate.midX)
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    context.setShadow(
        offset: CGSize(width: 0, height: -6),
        blur: 18,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
    )
    context.addPath(tab)
    context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 1.0, alpha: 0.96))
    context.fillPath()
    context.restoreGState()
}

/// The waiting dot. Warm against the cool field, which is where the eye lands.
func drawDot(_ context: CGContext, plate: CGRect, tabHeight: CGFloat) {
    let radius = tabHeight * 0.23
    let center = CGPoint(x: plate.midX, y: plate.maxY - tabHeight * 0.52)
    context.saveGState()
    context.setShadow(
        offset: .zero,
        blur: radius * 1.6,
        color: CGColor(red: 1.0, green: 0.45, blue: 0.10, alpha: 0.55)
    )
    context.addEllipse(in: CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    ))
    context.setFillColor(CGColor(red: 1.0, green: 0.52, blue: 0.11, alpha: 1))
    context.fillPath()
    context.restoreGState()
}

/// The queue hanging below the tab. Three bars, each narrower and fainter, so
/// the icon says "a line of work waiting" and fills the plate.
func drawQueueBars(_ context: CGContext, plate: CGRect, tabWidth: CGFloat, tabHeight: CGFloat) {
    let barHeight = plate.height * 0.060
    for index in 0..<3 {
        let alpha = 0.40 - Double(index) * 0.11
        let width = tabWidth * (0.66 - CGFloat(index) * 0.11)
        let rect = CGRect(
            x: plate.midX - width / 2,
            y: plate.maxY - tabHeight - plate.height * (0.135 + CGFloat(index) * 0.165),
            width: width,
            height: barHeight
        )
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: barHeight / 2,
            cornerHeight: barHeight / 2,
            transform: nil
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        context.fillPath()
    }
}

// MARK: - Composition

func drawIcon(size: CGFloat) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Draw in a 1024 space and scale, so every size shares one set of ratios.
    context.scaleBy(x: size / 1024, y: size / 1024)
    context.setAllowsAntialiasing(true)

    // macOS app icons leave a margin. 824 of 1024 matches the system apps.
    let plateSize: CGFloat = 824
    let plate = CGRect(
        x: (1024 - plateSize) / 2,
        y: (1024 - plateSize) / 2 + 12,
        width: plateSize,
        height: plateSize
    )
    let platePath = squircle(in: plate)
    let tabWidth = plate.width * 0.60
    let tabHeight = plate.height * 0.235

    drawPlate(context, plate: plate, path: platePath)
    drawTab(context, plate: plate, platePath: platePath, width: tabWidth, height: tabHeight)
    drawDot(context, plate: plate, tabHeight: tabHeight)
    drawQueueBars(context, plate: plate, tabWidth: tabWidth, tabHeight: tabHeight)

    return context.makeImage()
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "make-icon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"]
        )
    }
    try data.write(to: url)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dist = root.appendingPathComponent("dist")
let iconset = dist.appendingPathComponent("Baton.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The names `iconutil` expects.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = drawIcon(size: variant.size) else { fail("render failed at \(variant.name)") }
    try write(image, to: iconset.appendingPathComponent("\(variant.name).png"))
}

let icns = dist.appendingPathComponent("Baton.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fail("iconutil failed") }

if CommandLine.arguments.contains("--preview"), let image = drawIcon(size: 512) {
    try write(image, to: dist.appendingPathComponent("icon-preview.png"))
}

print("Wrote \(icns.path)")
