import AppKit
import SwiftUI
import Testing
@testable import Jambul

/// A finished turn's check is drawn rather than shown, so that it can pop in and draw itself.
@MainActor
struct PeekCheckTests {
    private static func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
    }

    /// Once drawn, it is the symbol it stands for, in the same frame: nothing jumps as it settles, and the title sits
    /// where it does on other peeks.
    @Test func aDrawnCheckEndsAsTheSymbol() throws {
        let drawn = PeekCheck(tint: .white, scale: 1, drawn: 1), symbol = Self.symbol("checkmark.circle.fill")
        #expect(NSHostingView(rootView: drawn).fittingSize == NSHostingView(rootView: symbol).fittingSize)
        let difference = try Self.difference(drawn, symbol)
        #expect(difference < 0.02, "\(difference * 100)% of what is drawn differs from the symbol")
    }

    /// It pops in from nothing, and its circle is whole before the check starts to draw.
    @Test func aDrawnCheckStartsFromNothing() throws {
        #expect(try Self.coverage(of: PeekCheck(tint: .white, scale: 0, drawn: 0)).allSatisfy { $0 == 0 })
        let difference = try Self.difference(PeekCheck(tint: .white, scale: 1, drawn: 0), Self.symbol("circle.fill"))
        #expect(difference < 0.02, "\(difference * 100)% of what is drawn differs from a whole circle")
    }

    /// The share of the pixels drawn in either view whose coverage differs by more than half.
    private static func difference(_ first: some View, _ second: some View) throws -> Double {
        let a = try coverage(of: first), b = try coverage(of: second)
        try #require(a.count == b.count)
        let drawn = zip(a, b).filter { $0 > 0 || $1 > 0 }.count
        let differing = zip(a, b).filter { abs(Int($0) - Int($1)) > 128 }.count
        return Double(differing) / Double(max(drawn, 1))
    }

    /// How much each pixel is covered, rendered at 8×.
    private static func coverage(of view: some View) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 8
        let image = try #require(renderer.cgImage)
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = try #require(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}
