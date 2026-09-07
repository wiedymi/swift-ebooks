import Foundation

enum BoundedDataReader {
    static func file(_ url: URL, limit: Int) throws -> Data {
        guard limit > 0, let stream = InputStream(url: url) else {
            throw BookError.io("Unable to open file or invalid byte limit")
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            // Read at most one byte past the limit to distinguish EOF from overflow.
            let count = stream.read(&buffer, maxLength: min(limit - data.count, buffer.count - 1) + 1)
            guard count >= 0 else {
                throw stream.streamError ?? BookError.io("Unable to read file")
            }
            if count == 0 { return data }
            guard count <= limit - data.count else {
                throw BookError.io("Data exceeds configured size limit")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func remote(_ url: URL, limit: Int) async throws -> Data {
        guard limit > 0 else { throw BookError.io("Invalid byte limit") }
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        defer { bytes.task.cancel() }
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw BookError.io("Remote data returned HTTP \(response.statusCode)")
        }
        guard response.expectedContentLength <= Int64(limit) else {
            throw BookError.io("Data exceeds configured size limit")
        }
        var data = Data()
        var buffer: [UInt8] = []
        buffer.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            guard buffer.count < limit - data.count else {
                throw BookError.io("Data exceeds configured size limit")
            }
            buffer.append(byte)
            if buffer.count == 64 * 1024 {
                try Task.checkCancellation()
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        data.append(contentsOf: buffer)
        return data
    }
}
