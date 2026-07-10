import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(ImageIO)
import ImageIO
#endif

enum DjVuPageDecoder {
    struct Image {
        let mediaType: String
        let data: Data
        let width: Int
        let height: Int
    }

    static func decodeDictionaries(
        chunks: [DjVuIFFChunk],
        documentData: Data,
        options: OpenOptions
    ) throws -> [DjVuJB2Bitmap] {
        var symbols: [DjVuJB2Bitmap] = []
        for chunk in chunks where chunk.id == "Djbz" {
            symbols = try DjVuJB2Decoder.decodeDictionary(
                chunk.payload(in: documentData),
                inheritedSymbols: symbols,
                maxOutputBytes: options.maxResourceBytes,
                maxRecords: options.maxArchiveEntries
            )
        }
        return symbols
    }

    static func decode(
        page: DjVuIFFPage,
        chunks: [DjVuIFFChunk],
        sharedSymbols: [DjVuJB2Bitmap],
        documentData: Data,
        options: OpenOptions
    ) throws -> Image {
        let backgroundWavelet = chunks.filter { $0.id == "BG44" }
        let foregroundWavelet = chunks.filter { $0.id == "FG44" }
        let backgroundJPEG = chunks.filter { $0.id == "BGjp" }
        let foregroundJPEG = chunks.filter { $0.id == "FGjp" }
        let jb2Chunks = chunks.filter { $0.id == "Sjbz" }
        let mmrChunks = chunks.filter { $0.id == "Smmr" }
        let paletteChunks = chunks.filter { $0.id == "FGbz" }

        try requireAtMostOne(backgroundJPEG, named: "BGjp")
        try requireAtMostOne(foregroundWavelet, named: "FG44")
        try requireAtMostOne(foregroundJPEG, named: "FGjp")
        try requireAtMostOne(jb2Chunks, named: "Sjbz")
        try requireAtMostOne(mmrChunks, named: "Smmr")
        try requireAtMostOne(paletteChunks, named: "FGbz")
        guard backgroundWavelet.isEmpty || backgroundJPEG.isEmpty else {
            throw BookError.malformedDocument("DjVu page has both BG44 and BGjp backgrounds")
        }
        guard foregroundWavelet.isEmpty || foregroundJPEG.isEmpty else {
            throw BookError.malformedDocument("DjVu page has both FG44 and FGjp foregrounds")
        }
        guard jb2Chunks.isEmpty || mmrChunks.isEmpty else {
            throw BookError.malformedDocument("DjVu page has both Sjbz and Smmr masks")
        }
        guard paletteChunks.isEmpty || foregroundWavelet.isEmpty && foregroundJPEG.isEmpty else {
            throw BookError.malformedDocument("DjVu page has multiple foreground color models")
        }

        let pageWidth = page.info.width
        let pageHeight = page.info.height
        guard pageWidth <= Int.max / pageHeight,
              pageWidth * pageHeight <= Int.max / 4,
              pageWidth * pageHeight * 4 <= options.maxResourceBytes
        else {
            throw BookError.renderingFailed("DjVu page dimensions exceed the configured resource limit")
        }

        let hasMask = !jb2Chunks.isEmpty || !mmrChunks.isEmpty
        let hasForeground = !foregroundWavelet.isEmpty || !foregroundJPEG.isEmpty || !paletteChunks.isEmpty
        guard !hasForeground || hasMask else {
            throw BookError.malformedDocument("DjVu foreground color data has no foreground mask")
        }

        if backgroundWavelet.isEmpty,
           let jpeg = backgroundJPEG.first,
           !hasMask,
           !hasForeground,
           page.info.rotation == .upright
        {
            let payload = jpeg.payload(in: documentData)
            guard payload.starts(with: Data([0xff, 0xd8])) else {
                throw BookError.malformedDocument("DjVu BGjp chunk is not a JPEG stream")
            }
            return Image(
                mediaType: "image/jpeg",
                data: payload,
                width: pageWidth,
                height: pageHeight
            )
        }

        let background: DjVuRasterImage?
        if !backgroundWavelet.isEmpty {
            background = try DjVuIW44Decoder.decode(
                chunks: backgroundWavelet.map { $0.payload(in: documentData) },
                maxOutputBytes: options.maxResourceBytes
            )
        } else if let jpeg = backgroundJPEG.first {
            background = try decodeJPEG(
                jpeg.payload(in: documentData),
                maxOutputBytes: options.maxResourceBytes,
                chunkName: "BGjp"
            )
        } else {
            background = nil
        }

        let foreground: DjVuRasterImage?
        if !foregroundWavelet.isEmpty {
            foreground = try DjVuIW44Decoder.decode(
                chunks: foregroundWavelet.map { $0.payload(in: documentData) },
                maxOutputBytes: options.maxResourceBytes
            )
        } else if let jpeg = foregroundJPEG.first {
            foreground = try decodeJPEG(
                jpeg.payload(in: documentData),
                maxOutputBytes: options.maxResourceBytes,
                chunkName: "FGjp"
            )
        } else {
            foreground = nil
        }

        if let background {
            try validateLayer(background, pageWidth: pageWidth, pageHeight: pageHeight, name: "background")
        }
        if let foreground {
            try validateLayer(foreground, pageWidth: pageWidth, pageHeight: pageHeight, name: "foreground")
        }

        let mask: Mask?
        if let chunk = jb2Chunks.first {
            let decoded = try DjVuJB2Decoder.decodeImage(
                chunk.payload(in: documentData),
                sharedSymbols: sharedSymbols,
                expectedWidth: pageWidth,
                expectedHeight: pageHeight,
                maxOutputBytes: options.maxResourceBytes,
                maxRecords: options.maxArchiveEntries
            )
            mask = Mask(
                pixels: decoded.mask,
                blitMap: decoded.blitMap,
                blitCount: decoded.blitCount
            )
        } else if let chunk = mmrChunks.first {
            mask = try decodeMMR(
                chunk.payload(in: documentData),
                width: pageWidth,
                height: pageHeight,
                maxOutputBytes: options.maxResourceBytes
            )
        } else {
            mask = nil
        }

        let palette = try paletteChunks.first.map {
            try ForegroundPalette.decode(
                $0.payload(in: documentData),
                expectedBlitCount: mask?.blitCount,
                maxOutputBytes: options.maxResourceBytes
            )
        }

        guard background != nil || mask != nil else {
            throw BookError.renderingFailed("DjVu page contains no supported visual layer")
        }

        var rgba = [UInt8](repeating: 255, count: pageWidth * pageHeight * 4)
        if let background {
            paint(background, into: &rgba, targetWidth: pageWidth, targetHeight: pageHeight)
        }
        if let mask {
            paintForeground(
                mask,
                foreground: foreground,
                palette: palette,
                into: &rgba,
                width: pageWidth,
                height: pageHeight
            )
        }

        let raster = try DjVuRasterImage(width: pageWidth, height: pageHeight, rgba: rgba)
            .rotated(page.info.rotation)
        return Image(
            mediaType: "image/png",
            data: try raster.pngData(),
            width: raster.width,
            height: raster.height
        )
    }
}

private extension DjVuPageDecoder {
    struct Mask {
        let pixels: [UInt8]
        let blitMap: [Int32]?
        let blitCount: Int?
    }

    struct ForegroundPalette {
        struct Color {
            let red: UInt8
            let green: UInt8
            let blue: UInt8
        }

        let colors: [Color]
        let indices: [Int]?

        static func decode(
            _ data: Data,
            expectedBlitCount: Int?,
            maxOutputBytes: Int
        ) throws -> ForegroundPalette {
            var cursor = DjVuByteCursor(data)
            let version = try cursor.readByte(context: "FGbz version")
            let hasCorrespondence = version & 0x80 != 0
            guard version & 0x7f == 0 else {
                throw BookError.renderingFailed("DjVu FGbz palette version is unsupported")
            }
            let count = try cursor.readUInt16(context: "FGbz palette size")
            guard count > 0, count <= maxOutputBytes / 3 else {
                throw BookError.malformedDocument("DjVu FGbz palette size is invalid")
            }
            var colors: [Color] = []
            colors.reserveCapacity(count)
            for _ in 0..<count {
                let blue = try cursor.readByte(context: "FGbz blue channel")
                let green = try cursor.readByte(context: "FGbz green channel")
                let red = try cursor.readByte(context: "FGbz red channel")
                colors.append(Color(red: red, green: green, blue: blue))
            }

            guard hasCorrespondence else {
                guard cursor.remaining == 0 else {
                    throw BookError.malformedDocument("DjVu FGbz palette has unexpected trailing data")
                }
                return ForegroundPalette(colors: colors, indices: nil)
            }

            let blitCount = try cursor.readUInt24(context: "FGbz blit count")
            if let expectedBlitCount, blitCount != expectedBlitCount {
                throw BookError.malformedDocument("DjVu FGbz color count does not match the JB2 blit count")
            }
            guard blitCount <= maxOutputBytes / 2 else {
                throw BookError.malformedDocument("DjVu FGbz correspondence exceeds the configured limit")
            }
            let decoded = try DjVuBZZDecoder.decode(
                cursor.readRemaining(),
                maxOutputBytes: min(maxOutputBytes, max(blitCount * 2, 1))
            )
            guard decoded.count == blitCount * 2 else {
                throw BookError.malformedDocument("DjVu FGbz correspondence length is inconsistent")
            }
            var decodedCursor = DjVuByteCursor(decoded)
            var indices: [Int] = []
            indices.reserveCapacity(blitCount)
            for _ in 0..<blitCount {
                let index = try decodedCursor.readUInt16(context: "FGbz palette index")
                guard colors.indices.contains(index) else {
                    throw BookError.malformedDocument("DjVu FGbz references an unavailable palette color")
                }
                indices.append(index)
            }
            return ForegroundPalette(colors: colors, indices: indices)
        }

        func color(forBlit blit: Int) -> Color {
            if let indices, indices.indices.contains(blit) {
                return colors[indices[blit]]
            }
            if colors.count == 1 { return colors[0] }
            return colors[min(max(blit, 0), colors.count - 1)]
        }
    }

    static func requireAtMostOne(_ chunks: [DjVuIFFChunk], named name: String) throws {
        guard chunks.count <= 1 else {
            throw BookError.malformedDocument("DjVu page contains multiple \(name) chunks")
        }
    }

    static func validateLayer(
        _ image: DjVuRasterImage,
        pageWidth: Int,
        pageHeight: Int,
        name: String
    ) throws {
        let isValid = (1...12).contains { factor in
            image.width == (pageWidth + factor - 1) / factor &&
                image.height == (pageHeight + factor - 1) / factor
        }
        guard isValid else {
            throw BookError.malformedDocument(
                "DjVu \(name) layer dimensions are not a valid page subsampling"
            )
        }
    }

    static func paint(
        _ source: DjVuRasterImage,
        into destination: inout [UInt8],
        targetWidth: Int,
        targetHeight: Int
    ) {
        for y in 0..<targetHeight {
            let sourceY = min(y * source.height / targetHeight, source.height - 1)
            for x in 0..<targetWidth {
                let sourceX = min(x * source.width / targetWidth, source.width - 1)
                let sourceOffset = (sourceY * source.width + sourceX) * 4
                let destinationOffset = (y * targetWidth + x) * 4
                destination[destinationOffset] = source.rgba[sourceOffset]
                destination[destinationOffset + 1] = source.rgba[sourceOffset + 1]
                destination[destinationOffset + 2] = source.rgba[sourceOffset + 2]
                destination[destinationOffset + 3] = 255
            }
        }
    }

    static func paintForeground(
        _ mask: Mask,
        foreground: DjVuRasterImage?,
        palette: ForegroundPalette?,
        into destination: inout [UInt8],
        width: Int,
        height: Int
    ) {
        for y in 0..<height {
            let foregroundY = foreground.map { min(y * $0.height / height, $0.height - 1) }
            for x in 0..<width {
                let pixelIndex = y * width + x
                guard mask.pixels[pixelIndex] != 0 else { continue }
                let output = pixelIndex * 4
                if let palette {
                    let blit = mask.blitMap.map { Int($0[pixelIndex]) } ?? 0
                    let color = palette.color(forBlit: blit)
                    destination[output] = color.red
                    destination[output + 1] = color.green
                    destination[output + 2] = color.blue
                } else if let foreground, let foregroundY {
                    let foregroundX = min(x * foreground.width / width, foreground.width - 1)
                    let input = (foregroundY * foreground.width + foregroundX) * 4
                    destination[output] = foreground.rgba[input]
                    destination[output + 1] = foreground.rgba[input + 1]
                    destination[output + 2] = foreground.rgba[input + 2]
                } else {
                    destination[output] = 0
                    destination[output + 1] = 0
                    destination[output + 2] = 0
                }
                destination[output + 3] = 255
            }
        }
    }

    static func decodeJPEG(
        _ data: Data,
        maxOutputBytes: Int,
        chunkName: String
    ) throws -> DjVuRasterImage {
        guard data.starts(with: Data([0xff, 0xd8])) else {
            throw BookError.malformedDocument("DjVu \(chunkName) chunk is not a JPEG stream")
        }
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw BookError.malformedDocument("DjVu \(chunkName) JPEG cannot be decoded")
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= Int.max / height,
              width * height <= Int.max / 4,
              width * height * 4 <= maxOutputBytes
        else {
            throw BookError.renderingFailed("DjVu \(chunkName) JPEG exceeds the configured limit")
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &rgba,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw BookError.renderingFailed("DjVu \(chunkName) raster buffer cannot be created")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try DjVuRasterImage(width: width, height: height, rgba: rgba)
        #else
        throw BookError.renderingFailed("DjVu JPEG decoding requires CoreGraphics and ImageIO")
        #endif
    }

    static func decodeMMR(
        _ data: Data,
        width: Int,
        height: Int,
        maxOutputBytes: Int
    ) throws -> Mask {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        var cursor = DjVuByteCursor(data)
        let magic = try cursor.readData(count: 3, context: "Smmr magic")
        guard magic == Data("MMR".utf8) else {
            throw BookError.malformedDocument("DjVu Smmr header is invalid")
        }
        let flags = try cursor.readByte(context: "Smmr flags")
        guard flags & 0xfc == 0 else {
            throw BookError.malformedDocument("DjVu Smmr flags are invalid")
        }
        let encodedWidth = try cursor.readUInt16(context: "Smmr width")
        let encodedHeight = try cursor.readUInt16(context: "Smmr height")
        guard encodedWidth == width, encodedHeight == height else {
            throw BookError.malformedDocument("DjVu Smmr dimensions do not match the INFO chunk")
        }
        let inverted = flags & 0x01 != 0
        let striped = flags & 0x02 != 0

        var rasters: [DjVuRasterImage] = []
        if striped {
            let rowsPerStripe = try cursor.readUInt16(context: "Smmr rows per stripe")
            guard rowsPerStripe > 0 else {
                throw BookError.malformedDocument("DjVu Smmr stripe height is zero")
            }
            var decodedRows = 0
            while decodedRows < height {
                let byteCount = try cursor.readUInt32(context: "Smmr stripe byte count")
                guard byteCount > 0, byteCount <= maxOutputBytes else {
                    throw BookError.malformedDocument("DjVu Smmr stripe size is invalid")
                }
                let stripeHeight = min(rowsPerStripe, height - decodedRows)
                let payload = try cursor.readData(count: byteCount, context: "Smmr stripe data")
                rasters.append(
                    try decodeRawMMR(
                        payload,
                        width: width,
                        height: stripeHeight,
                        inverted: inverted,
                        maxOutputBytes: maxOutputBytes
                    )
                )
                decodedRows += stripeHeight
            }
            guard cursor.remaining == 0 else {
                throw BookError.malformedDocument("DjVu Smmr contains trailing stripe data")
            }
        } else {
            rasters = [try decodeRawMMR(
                cursor.readRemaining(),
                width: width,
                height: height,
                inverted: inverted,
                maxOutputBytes: maxOutputBytes
            )]
        }

        let pixels = rasters.flatMap { raster in
            stride(from: 0, to: raster.rgba.count, by: 4).map { offset -> UInt8 in
            let luminance = Int(raster.rgba[offset]) + Int(raster.rgba[offset + 1]) + Int(raster.rgba[offset + 2])
            return luminance < 384 ? 1 : 0
            }
        }
        guard pixels.count == width * height else {
            throw BookError.malformedDocument("DjVu Smmr raster length is inconsistent")
        }
        return Mask(pixels: pixels, blitMap: nil, blitCount: nil)
        #else
        throw BookError.renderingFailed("DjVu Smmr decoding requires CoreGraphics and ImageIO")
        #endif
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    static func decodeRawMMR(
        _ payload: Data,
        width: Int,
        height: Int,
        inverted: Bool,
        maxOutputBytes: Int
    ) throws -> DjVuRasterImage {
        guard !payload.isEmpty else {
            throw BookError.malformedDocument("DjVu Smmr Fax-G4 payload is empty")
        }
        return try decodeTIFF(
            makeGroup4TIFF(
                payload: payload,
                width: width,
                height: height,
                photometric: inverted ? 1 : 0
            ),
            maxOutputBytes: maxOutputBytes
        )
    }

    static func decodeTIFF(_ data: Data, maxOutputBytes: Int) throws -> DjVuRasterImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw BookError.malformedDocument("DjVu Smmr Fax-G4 stream cannot be decoded")
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= Int.max / height,
              width * height <= Int.max / 4,
              width * height * 4 <= maxOutputBytes
        else {
            throw BookError.renderingFailed("DjVu Smmr image exceeds the configured limit")
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &rgba,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw BookError.renderingFailed("DjVu Smmr raster buffer cannot be created")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try DjVuRasterImage(width: width, height: height, rgba: rgba)
    }

    static func makeGroup4TIFF(
        payload: Data,
        width: Int,
        height: Int,
        photometric: UInt32
    ) -> Data {
        let entryCount: UInt16 = 10
        let directoryOffset: UInt32 = 8
        let payloadOffset = UInt32(8 + 2 + Int(entryCount) * 12 + 4)
        var output = Data([0x49, 0x49, 0x2a, 0x00])
        output.appendLittleEndian(directoryOffset)
        output.appendLittleEndian(entryCount)
        appendTIFFEntry(tag: 256, type: 4, count: 1, value: UInt32(width), to: &output)
        appendTIFFEntry(tag: 257, type: 4, count: 1, value: UInt32(height), to: &output)
        appendTIFFEntry(tag: 258, type: 3, count: 1, value: 1, to: &output)
        appendTIFFEntry(tag: 259, type: 3, count: 1, value: 4, to: &output)
        appendTIFFEntry(tag: 262, type: 3, count: 1, value: photometric, to: &output)
        appendTIFFEntry(tag: 266, type: 3, count: 1, value: 1, to: &output)
        appendTIFFEntry(tag: 273, type: 4, count: 1, value: payloadOffset, to: &output)
        appendTIFFEntry(tag: 278, type: 4, count: 1, value: UInt32(height), to: &output)
        appendTIFFEntry(tag: 279, type: 4, count: 1, value: UInt32(payload.count), to: &output)
        appendTIFFEntry(tag: 292, type: 4, count: 1, value: 0, to: &output)
        output.appendLittleEndian(UInt32(0))
        output.append(payload)
        return output
    }

    static func appendTIFFEntry(
        tag: UInt16,
        type: UInt16,
        count: UInt32,
        value: UInt32,
        to output: inout Data
    ) {
        output.appendLittleEndian(tag)
        output.appendLittleEndian(type)
        output.appendLittleEndian(count)
        if type == 3, count == 1 {
            output.appendLittleEndian(UInt16(truncatingIfNeeded: value))
            output.appendLittleEndian(UInt16(0))
        } else {
            output.appendLittleEndian(value)
        }
    }
    #endif
}

private extension DjVuRasterImage {
    func rotated(_ rotation: DjVuRotation) throws -> DjVuRasterImage {
        guard rotation != .upright else { return self }
        let outputWidth = rotation == .clockwise90 || rotation == .counterClockwise90
            ? height : width
        let outputHeight = rotation == .clockwise90 || rotation == .counterClockwise90
            ? width : height
        var output = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)
        for y in 0..<height {
            for x in 0..<width {
                let destination: (x: Int, y: Int)
                switch rotation {
                case .upright:
                    destination = (x, y)
                case .clockwise90:
                    destination = (height - y - 1, x)
                case .counterClockwise90:
                    destination = (y, width - x - 1)
                case .upsideDown:
                    destination = (width - x - 1, height - y - 1)
                }
                let sourceOffset = (y * width + x) * 4
                let destinationOffset = (destination.y * outputWidth + destination.x) * 4
                output[destinationOffset..<(destinationOffset + 4)] = rgba[sourceOffset..<(sourceOffset + 4)]
            }
        }
        return try DjVuRasterImage(width: outputWidth, height: outputHeight, rgba: output)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
