import Foundation
import CoreGraphics

/// A parsed KiCad S-expression: an atom (symbol, number or string, all kept as text) or a list.
enum SExpr {
    case atom(String)
    case list([SExpr])

    var items: [SExpr] {
        if case .list(let l) = self { return l }
        return []
    }
    var atom: String? {
        if case .atom(let s) = self { return s }
        return nil
    }
    /// The token name of a list: "segment" for (segment (start …) …).
    var name: String? { items.first?.atom }

    func first(_ name: String) -> SExpr? { items.first { $0.name == name } }
    func all(_ name: String) -> [SExpr] { items.filter { $0.name == name } }
    func string(_ i: Int) -> String? { i < items.count ? items[i].atom : nil }
    func number(_ i: Int) -> Double? { string(i).flatMap(Double.init) }

    /// (name x y …) → CGPoint
    func point(_ name: String) -> CGPoint? {
        guard let c = first(name), let x = c.number(1), let y = c.number(2) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

enum SExprError: Error { case unbalanced, empty }

enum SExprParser {
    private static let LP: UInt8 = 40, RP: UInt8 = 41, QUOTE: UInt8 = 34, BACKSLASH: UInt8 = 92
    private static let SP: UInt8 = 32, TAB: UInt8 = 9, LF: UInt8 = 10, CR: UInt8 = 13, N: UInt8 = 110

    /// Parses the first complete top-level list in `data`.
    static func parse(_ data: Data) throws -> SExpr {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> SExpr in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = 0
            var stack: [[SExpr]] = []

            func push(_ e: SExpr) throws {
                guard !stack.isEmpty else { throw SExprError.unbalanced }
                stack[stack.count - 1].append(e)
            }

            while i < n {
                let c = b[i]
                if c == LP {
                    stack.append([])
                    i += 1
                } else if c == RP {
                    guard let items = stack.popLast() else { throw SExprError.unbalanced }
                    i += 1
                    if stack.isEmpty { return .list(items) }
                    stack[stack.count - 1].append(.list(items))
                } else if c == SP || c == TAB || c == LF || c == CR {
                    i += 1
                } else if c == QUOTE {
                    i += 1
                    var buf: [UInt8] = []
                    while i < n, b[i] != QUOTE {
                        if b[i] == BACKSLASH, i + 1 < n {            // \n is a newline; \" \\ etc. keep the char
                            i += 1
                            buf.append(b[i] == N ? LF : b[i])
                            i += 1
                            continue
                        }
                        buf.append(b[i])
                        i += 1
                    }
                    i += 1
                    try push(.atom(String(decoding: buf, as: UTF8.self)))
                } else {
                    let start = i
                    while i < n {
                        let d = b[i]
                        if d == LP || d == RP || d == SP || d == TAB || d == LF || d == CR || d == QUOTE { break }
                        i += 1
                    }
                    try push(.atom(String(decoding: b[start..<i], as: UTF8.self)))
                }
            }
            throw stack.isEmpty ? SExprError.empty : SExprError.unbalanced
        }
    }
}
