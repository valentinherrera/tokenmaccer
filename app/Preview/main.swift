import AppKit
import SwiftUI

// Renders the widget view to PNGs (light/dark, all sizes) without adding it to the desktop.
// Build: swiftc app/Shared/*.swift app/Preview/main.swift -o render
// Usage: render <widget.json> <output dir> [period ...] [-AppleLocale en_US]
// TM_RENDER_CLEAR=1: transparent background, for the website, which draws the glass itself (scripts/render_site_images.sh).
// widget.json "none": the state before the collector's first pass (no file yet).
@MainActor
func render() {
    let args = CommandLine.arguments
    guard args.count > 2 else {
        print("usage: render <widget.json> <output dir> [period ...]")
        exit(2)
    }
    let data = WidgetData.load(from: URL(fileURLWithPath: args[1]))
    let out = URL(fileURLWithPath: args[2])
    // Remaining arguments are periods; "-Key value" pairs (e.g. -AppleLocale en_US) go to UserDefaults.
    var periods: [String] = []
    var i = 3
    while i < args.count {
        if args[i].hasPrefix("-") { i += 2; continue }
        periods.append(args[i])
        i += 1
    }
    if periods.isEmpty { periods = ["1D", "30D"] }
    let clear = ProcessInfo.processInfo.environment["TM_RENDER_CLEAR"] == "1"
    if data == nil && args[1] != "none" {
        print("could not read \(args[1])")
        exit(1)
    }
    let sizes: [(String, Size, CGSize)] = [
        ("small", .small, CGSize(width: 170, height: 170)),
        ("medium", .medium, CGSize(width: 364, height: 170)),
        ("large", .large, CGSize(width: 364, height: 382)),
    ]
    for period in periods {
        for (name, size, frame) in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let v = TickerView(data: data, period: period, unit: .tokens, size: size)
                    .padding(14)
                    .frame(width: frame.width, height: frame.height)
                    .background(clear ? Color.clear : scheme == .dark ? Color(white: 0.17) : Color(white: 0.95))
                    .environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: v)
                r.scale = 2
                guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                let file = out.appendingPathComponent("\(period)_\(name)_\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: file)
            }
        }
    }
}

MainActor.assumeIsolated { render() }
