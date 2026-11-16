import Foundation

/// A minimal ASN.1 BER reader: enough to walk a CMS / PKCS#7 container. Accepts what real signing
/// software produces, including indefinite lengths and constructed OCTET STRINGs (common in files from
/// Windows and Outlook), with limits so a hostile file can't exhaust memory or the stack.
struct BER: Sendable {
    let tag: UInt8
    /// Content octets, or nil for a constructed value with indefinite length (use `children`).
    let content: Data
    let children: [BER]
    let isConstructed: Bool

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let maxDepth = 64

    init(tag: UInt8, content: Data, children: [BER], isConstructed: Bool) {
        self.tag = tag
        self.content = content
        self.children = children
        self.isConstructed = isConstructed
    }

    init(_ data: Data) throws {
        var offset = data.startIndex
        self = try BER.read(data, at: &offset, depth: 0)
    }

    static func read(_ data: Data, at offset: inout Data.Index, depth: Int) throws -> BER {
        guard depth < maxDepth else { throw ParseError(message: "The file nests too deeply.") }
        guard offset < data.endIndex else { throw ParseError(message: "The file ends unexpectedly.") }
        let tag = data[offset]
        offset += 1
        guard tag & 0x1F != 0x1F else { throw ParseError(message: "Unsupported ASN.1 tag.") }
        guard offset < data.endIndex else { throw ParseError(message: "The file ends unexpectedly.") }
        let constructed = tag & 0x20 != 0
        let first = data[offset]
        offset += 1

        if first == 0x80 {  // indefinite length: children until an end-of-contents marker (00 00)
            guard constructed else { throw ParseError(message: "Malformed indefinite length.") }
            var children: [BER] = []
            while true {
                guard offset + 1 < data.endIndex else { throw ParseError(message: "The file ends unexpectedly.") }
                if data[offset] == 0, data[offset + 1] == 0 {
                    offset += 2
                    break
                }
                children.append(try read(data, at: &offset, depth: depth + 1))
            }
            return BER(tag: tag, content: Data(), children: children, isConstructed: true)
        }

        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, offset + count <= data.endIndex else {
                throw ParseError(message: "Unsupported length encoding.")
            }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(data[offset])
                offset += 1
            }
        }
        guard length >= 0, offset + length <= data.endIndex else {
            throw ParseError(message: "The file is truncated.")
        }
        let content = data[offset..<offset + length]  // a slice: shares storage, no copy
        offset += length
        var children: [BER] = []
        if constructed {
            var inner = content.startIndex
            while inner < content.endIndex {
                children.append(try read(content, at: &inner, depth: depth + 1))
            }
        }
        return BER(tag: tag, content: content, children: children, isConstructed: constructed)
    }

    func child(_ index: Int) throws -> BER {
        guard index < children.count else { throw ParseError(message: "The file is not a signed (PKCS#7) container.") }
        return children[index]
    }

    /// Child with context-specific tag [n].
    func context(_ n: UInt8) -> BER? {
        children.first { $0.tag & 0xC0 == 0x80 && $0.tag & 0x1F == n }
    }

    var oid: String? {
        guard tag == 0x06, !content.isEmpty else { return nil }
        let bytes = [UInt8](content)
        var parts = [Int(bytes[0]) / 40, Int(bytes[0]) % 40]
        var value = 0
        for byte in bytes.dropFirst() {
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// The bytes of an OCTET STRING, joining the segments of a constructed one.
    var octets: Data? {
        switch tag {
        case 0x04: content
        case 0x24: children.reduce(into: Data()) { $0.append($1.octets ?? Data()) }
        default: nil
        }
    }

    var string: String? {
        switch tag {
        case 0x0C, 0x13, 0x16, 0x14: String(data: content, encoding: .utf8) ?? String(data: content, encoding: .isoLatin1)
        case 0x1E: String(data: content, encoding: .utf16BigEndian)
        default: nil
        }
    }
}
