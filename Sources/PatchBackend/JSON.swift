import Foundation

/// A Sendable JSON value. PostgREST rows are schemaless from our side (a relation cell is a
/// scalar or an array, a column may be absent), so rows are read through this.
enum JSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// A non-empty string value.
    var string: String? {
        if case .string(let s) = self, !s.isEmpty { return s }
        return nil
    }

    /// A number, or a string that parses as one (PostgREST renders `numeric` either way).
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// A scalar as a one-element list, an array as its non-empty strings, null as empty.
    var strings: [String] {
        switch self {
        case .string(let s): return s.isEmpty ? [] : [s]
        case .array(let a): return a.compactMap(\.string)
        default: return []
        }
    }
}
