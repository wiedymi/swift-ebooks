import Foundation

enum DjVuAnnotations {
    static func links(
        from text: String,
        pageHeight: Double? = nil,
        resolve: (String) -> String = { $0 }
    ) -> [PageLink] {
        var parser = SExpressionParser(text)
        guard let expressions = try? parser.parse() else { return [] }
        return expressions.compactMap {
            link($0, pageHeight: pageHeight, resolve: resolve)
        }
    }

    private static func link(
        _ expression: SExpression,
        pageHeight: Double?,
        resolve: (String) -> String
    ) -> PageLink? {
        guard case let .list(values) = expression,
              values.count >= 4,
              values[0].atom == "maparea",
              let href = mapAreaURL(values[1]),
              let area = values.dropFirst(3).compactMap(rectangle).first
        else {
            return nil
        }
        let title = values[2].atom?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounds: PageRectangle
        if let pageHeight {
            // DjVu map areas use a bottom-left origin on the displayed (already
            // rotated) page. BookKit page overlays use a top-left origin.
            bounds = PageRectangle(
                x: area.x,
                y: pageHeight - area.y - area.height,
                width: area.width,
                height: area.height
            )
        } else {
            bounds = area
        }
        return PageLink(
            href: resolve(href),
            title: title?.isEmpty == false ? title : nil,
            bounds: bounds
        )
    }

    private static func mapAreaURL(_ value: SExpression) -> String? {
        if let atom = value.atom { return atom }
        guard case let .list(values) = value,
              values.first?.atom == "url",
              values.count >= 2
        else {
            return nil
        }
        return values[1].atom
    }

    private static func rectangle(_ value: SExpression) -> PageRectangle? {
        guard case let .list(values) = value,
              let shape = values.first?.atom
        else {
            return nil
        }

        if ["rect", "oval", "text"].contains(shape) {
            guard values.count >= 5,
                  let x = values[1].double,
                  let y = values[2].double,
                  let width = values[3].double,
                  let height = values[4].double,
                  width >= 0,
                  height >= 0
            else {
                return nil
            }
            return PageRectangle(x: x, y: y, width: width, height: height)
        }

        guard shape == "poly" || shape == "line" else { return nil }
        let rawCoordinates = values.dropFirst().map(\.double)
        guard rawCoordinates.allSatisfy({ $0 != nil }) else { return nil }
        let coordinates = rawCoordinates.compactMap { $0 }
        let minimumCoordinateCount = shape == "poly" ? 6 : 4
        guard coordinates.count >= minimumCoordinateCount,
              coordinates.count.isMultiple(of: 2)
        else {
            return nil
        }

        let xs = stride(from: 0, to: coordinates.count, by: 2).map { coordinates[$0] }
        let ys = stride(from: 1, to: coordinates.count, by: 2).map { coordinates[$0] }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else {
            return nil
        }
        return PageRectangle(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
}

private enum SExpression {
    case atom(String)
    case list([SExpression])

    var atom: String? {
        guard case let .atom(value) = self else { return nil }
        return value
    }

    var double: Double? {
        atom.flatMap(Double.init)
    }
}

private struct SExpressionParser {
    private let characters: [Character]
    private var index = 0

    init(_ source: String) {
        characters = Array(source)
    }

    mutating func parse() throws -> [SExpression] {
        var result: [SExpression] = []
        while true {
            skipWhitespace()
            guard index < characters.count else { return result }
            result.append(try expression(depth: 0))
        }
    }

    private mutating func expression(depth: Int) throws -> SExpression {
        guard depth <= 32, index < characters.count else {
            throw BookError.malformedDocument("DjVu annotation nesting is invalid")
        }
        if characters[index] == "(" {
            index += 1
            var values: [SExpression] = []
            while true {
                skipWhitespace()
                guard index < characters.count else {
                    throw BookError.malformedDocument("DjVu annotation list is unterminated")
                }
                if characters[index] == ")" {
                    index += 1
                    return .list(values)
                }
                values.append(try expression(depth: depth + 1))
            }
        }
        return .atom(try atom())
    }

    private mutating func atom() throws -> String {
        guard index < characters.count else { return "" }
        if characters[index] == "\"" {
            index += 1
            var output = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "\"" { return output }
                if character == "\\", index < characters.count, characters[index] == "\"" {
                    output.append("\"")
                    index += 1
                } else {
                    output.append(character)
                }
            }
            throw BookError.malformedDocument("DjVu annotation string is unterminated")
        }

        let start = index
        while index < characters.count,
              !characters[index].isWhitespace,
              characters[index] != "(",
              characters[index] != ")"
        {
            index += 1
        }
        guard index > start else {
            throw BookError.malformedDocument("DjVu annotation token is invalid")
        }
        return String(characters[start..<index])
    }

    private mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
    }
}
