import AppKit
import DesignSystem
import Testing

@Suite("Design tokens")
struct TokenTests {

    @Test("hex colors decode channel by channel")
    func hexDecoding() {
        let color = NSColor(hex: 0x3B9CF6).usingColorSpace(.sRGB)
        #expect(abs((color?.redComponent ?? 0) - 0x3B / 255.0) < 0.001)
        #expect(abs((color?.greenComponent ?? 0) - 0x9C / 255.0) < 0.001)
        #expect(abs((color?.blueComponent ?? 0) - 0xF6 / 255.0) < 0.001)
    }

    @Test("the minimum window fits the sidebar and a reading column")
    func layoutFits() {
        #expect(EchoLayout.sidebarWidth + 400 <= EchoLayout.minimumWindow.width)
        #expect(EchoLayout.defaultWindow.width >= EchoLayout.minimumWindow.width)
    }

    @Test("spacing steps grow monotonically")
    func spacingSteps() {
        let steps = [
            EchoSpacing.xxs, EchoSpacing.xs, EchoSpacing.s, EchoSpacing.m, EchoSpacing.l, EchoSpacing.xl,
            EchoSpacing.xxl,
        ]
        #expect(steps == steps.sorted())
        #expect(Set(steps).count == steps.count)
    }
}
