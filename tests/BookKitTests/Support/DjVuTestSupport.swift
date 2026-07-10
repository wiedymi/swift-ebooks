import Foundation

enum DjVuTestSupport {
    static let onePixelJPEG = Data(
        base64Encoded: """
        /9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////
        2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB
        /8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAF//8QAFBAB
        AAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBA
        AAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFBAB
        AAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAAABAf/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/a
        AAgBAwEBPxB//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPxB//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/a
        AAgBAQABPxB//9k=
        """,
        options: .ignoreUnknownCharacters
    )!

    static func info(
        width: UInt16 = 1200,
        height: UInt16 = 1800,
        dpi: UInt16 = 300,
        minorVersion: UInt8 = 26,
        flags: UInt8 = 1
    ) -> Data {
        var payload = Data()
        payload.appendBigEndian(width)
        payload.appendBigEndian(height)
        payload.append(minorVersion)
        payload.append(0)
        payload.appendLittleEndian(dpi)
        payload.append(22)
        payload.append(flags)
        return chunk("INFO", payload)
    }

    static func text(_ value: String) -> Data {
        let text = Data(value.utf8)
        var payload = Data()
        payload.appendUInt24(text.count)
        payload.append(text)
        payload.append(1)
        return chunk("TXTa", payload)
    }

    static func annotation(_ value: String) -> Data {
        chunk("ANTa", Data(value.utf8))
    }

    static func jpegPage(
        width: UInt16 = 1200,
        height: UInt16 = 1800,
        text: String? = nil,
        annotation: String? = nil
    ) -> Data {
        var chunks = [info(width: width, height: height), chunk("BGjp", onePixelJPEG)]
        if let text { chunks.append(self.text(text)) }
        if let annotation { chunks.append(self.annotation(annotation)) }
        return form("DJVU", chunks)
    }

    static func document(form: Data) -> Data {
        Data("AT&T".utf8) + form
    }

    static func form(_ type: String, _ chunks: [Data]) -> Data {
        chunk("FORM", Data(type.utf8) + chunks.reduce(into: Data(), { $0.append($1) }))
    }

    static func chunk(_ id: String, _ payload: Data) -> Data {
        precondition(id.utf8.count == 4)
        var output = Data(id.utf8)
        output.appendBigEndian(UInt32(payload.count))
        output.append(payload)
        if payload.count.isMultiple(of: 2) == false {
            output.append(0)
        }
        return output
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt24(_ value: Int) {
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
