import Foundation

/// A JSON value as the core sends it. Documents go back exactly as they came,
/// so fields this client doesn't know survive its writes.
public enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

public struct JSONError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

// MARK: - Reading and writing

extension JSON {
    public init(data: Data) throws {
        do {
            let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            self = JSON(any: any)
        } catch {
            throw JSONError(description: "invalid JSON: \(error.localizedDescription)")
        }
    }

    public init(bytes: UnsafeRawBufferPointer) throws {
        try self.init(data: Data(bytes))
    }

    public init(text: String) throws {
        try self.init(data: Data(text.utf8))
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n as CFNumber) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.int64Value)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSON.init(any:)))
        case let d as [String: Any]:
            self = .object(d.mapValues(JSON.init(any:)))
        default:
            self = .null
        }
    }

    var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): NSNumber(value: b)
        case .int(let i): NSNumber(value: i)
        case .double(let d): NSNumber(value: d)
        case .string(let s): s
        case .array(let a): a.map(\.foundation)
        case .object(let o): o.mapValues(\.foundation)
        }
    }

    /// Compact JSON with sorted keys, the way the core and herdr-app write it.
    public func data(pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { options.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: foundation, options: options)) ?? Data("null".utf8)
    }

    public var text: String { String(decoding: data(), as: UTF8.self) }
}

// MARK: - Access

extension JSON {
    public subscript(key: String) -> JSON? {
        get {
            if case .object(let o) = self { return o[key] }
            return nil
        }
        set {
            var o = object ?? [:]
            o[key] = newValue
            self = .object(o)
        }
    }

    public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var int64: Int64? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.rounded() == d && abs(d) < 9.2e18: Int64(d)
        default: nil
        }
    }

    public var int: Int? { int64.map { Int($0) } }

    public var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A string map (labels, env), dropping values that are not strings.
    public var stringMap: [String: String] {
        guard let o = object else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in o {
            if let s = v.string { out[k] = s }
        }
        return out
    }

    public var stringArray: [String] {
        (array ?? []).compactMap(\.string)
    }
}

// MARK: - Building

extension JSON {
    public init(_ s: String) { self = .string(s) }
    public init(_ i: Int) { self = .int(Int64(i)) }
    public init(_ d: Double) { self = .double(d) }
    public init(_ b: Bool) { self = .bool(b) }
    public init(_ map: [String: String]) { self = .object(map.mapValues { .string($0) }) }
    public init(_ list: [String]) { self = .array(list.map { .string($0) }) }
    public init(_ s: String?) { self = s.map { .string($0) } ?? .null }
    public init(_ i: Int?) { self = i.map { .int(Int64($0)) } ?? .null }
}

extension JSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSON: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
}

extension JSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

extension JSON: CustomStringConvertible {
    public var description: String { text }
}
