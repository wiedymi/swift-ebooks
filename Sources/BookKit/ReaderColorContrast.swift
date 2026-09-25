import Foundation

/// Derives an opaque black or white foreground with the higher sRGB contrast.
/// Non-hex and translucent publisher colors retain the caller's own styling.
enum ReaderColorContrast {
    static func foreground(on background: String) -> String? {
        guard background.hasPrefix("#") else { return nil }
        var digits = String(background.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else { return nil }
        func linear(_ value: UInt32) -> Double {
            let channel = Double(value & 255) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb >> 16) + 0.7152 * linear(rgb >> 8) + 0.0722 * linear(rgb)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? "#000000" : "#ffffff"
    }
}

extension Theme {
    var usesDarkSelection: Bool { ReaderColorContrast.foreground(on: backgroundColor) == "#ffffff" }
    var selectionBackgroundColor: String { usesDarkSelection ? "#36516B" : "#B4D7FA" }
    var selectionTextColor: String { usesDarkSelection ? "#ffffff" : "#000000" }
}
