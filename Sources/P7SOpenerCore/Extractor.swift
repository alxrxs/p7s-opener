import Foundation

/// Gets the original document out of a signed .p7s / .p7m file (PKCS#7 / CMS SignedData with the content
/// embedded). Signatures are deliberately not verified: the point is to recover the document, even from
/// expired or untrusted signers.
public enum Extractor {
    public struct Result: Sendable, Equatable {
        public let content: Data
        /// Common name(s) of whoever signed, outermost signature first.
        public let signers: [String]
    }

    public enum Failure: LocalizedError, Equatable {
        case notSigned
        case detached
        case encrypted
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .notSigned: "This isn't a signed file (PKCS#7 / CMS)."
            case .detached: "This is a detached signature: the document isn't inside it, it's the file next to it."
            case .encrypted: "This file is encrypted, not just signed, so it can't be opened without the recipient's key."
            case .unreadable(let reason): "The file can't be read: \(reason)"
            }
        }
    }

    static let signedData = "1.2.840.113549.1.7.2"
    static let envelopedData = "1.2.840.113549.1.7.3"
    static let authEnvelopedData = "1.2.840.113549.1.9.16.1.23"

    /// The embedded document. Files signed several times (a signed file signed again, as with Italian
    /// .p7m.p7m) are unwrapped down to the original.
    public static func extract(_ file: Data) throws -> Result {
        var data = try decodeTransport(file)
        var signers: [String] = []
        for _ in 0..<16 {
            let (content, signer) = try unwrapOnce(data)
            signers += signer
            // Signed again inside? Keep unwrapping.
            if let inner = try? BER(content), inner.children.first?.oid == signedData {
                data = content
                continue
            }
            return Result(content: content, signers: signers)
        }
        throw Failure.unreadable("too many nested signatures")
    }

    static func unwrapOnce(_ data: Data) throws -> (Data, [String]) {
        let contentInfo: BER
        do { contentInfo = try BER(data) } catch { throw Failure.notSigned }
        guard contentInfo.tag == 0x30, let type = contentInfo.children.first?.oid else { throw Failure.notSigned }
        if type == envelopedData || type == authEnvelopedData { throw Failure.encrypted }
        guard type == signedData, let wrapped = contentInfo.context(0), let signed = wrapped.children.first else {
            throw Failure.notSigned
        }
        // SignedData: version, digestAlgorithms, encapContentInfo, [0] certificates, [1] crls, signerInfos
        let encapsulated = try signed.child(2)
        guard let explicit = encapsulated.context(0), let payload = explicit.children.first else { throw Failure.detached }
        // CMS puts the content in an OCTET STRING; old PKCS#7 may embed any type directly.
        let content = payload.octets ?? (payload.isConstructed ? payload.content : payload.content)
        guard !content.isEmpty else { throw Failure.detached }
        return (content, signerNames(signed))
    }

    /// Common names of the signers, matched from signerInfos to the certificates in the file.
    static func signerNames(_ signed: BER) -> [String] {
        let certificates = signed.context(0)?.children ?? []
        guard let infos = signed.children.last, infos.tag == 0x31 else { return [] }
        return infos.children.compactMap { info -> String? in
            guard info.children.count > 1 else { return nil }
            let sid = info.children[1]
            let certificate = certificates.first { cert in
                guard let tbs = cert.children.first else { return false }
                let fields = tbs.children.first?.tag == 0xA0 ? Array(tbs.children.dropFirst()) : tbs.children
                guard fields.count > 4 else { return false }
                if sid.tag == 0x30, sid.children.count == 2 {  // issuerAndSerialNumber
                    return fields[2].content == sid.children[0].content && fields[0].content == sid.children[1].content
                }
                return false
            }
            guard let tbs = certificate?.children.first else { return nil }
            let fields = tbs.children.first?.tag == 0xA0 ? Array(tbs.children.dropFirst()) : tbs.children
            return commonName(fields[4])
        }
    }

    static func commonName(_ name: BER) -> String? {
        for rdn in name.children {
            for pair in rdn.children where pair.children.count == 2 && pair.children[0].oid == "2.5.4.3" {
                return pair.children[1].string
            }
        }
        return nil
    }

    /// The binary container from what's on disk: DER/BER as is, PEM, plain base64, or an S/MIME message.
    static func decodeTransport(_ file: Data) throws -> Data {
        if let first = file.first, first == 0x30 { return file }
        guard let text = String(data: file.prefix(64 << 20), encoding: .utf8) ?? String(data: file, encoding: .isoLatin1) else {
            throw Failure.notSigned
        }
        // PEM: -----BEGIN PKCS7----- / CMS / PKCS #7 SIGNED DATA
        if let begin = text.range(of: "-----BEGIN"),
           let headerEnd = text.range(of: "-----", range: text.index(begin.upperBound, offsetBy: 1)..<text.endIndex),
           let end = text.range(of: "-----END", range: headerEnd.upperBound..<text.endIndex),
           let der = base64(String(text[headerEnd.upperBound..<end.lowerBound])) {
            return der
        }
        // S/MIME: headers, a blank line, then the base64 body.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.lowercased().contains("content-type:"), let blank = normalized.range(of: "\n\n"),
           let der = base64(String(normalized[blank.upperBound...])) {
            return der
        }
        if let der = base64(text) { return der }
        throw Failure.notSigned
    }

    static func base64(_ text: String) -> Data? {
        let body = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !body.isEmpty, let data = Data(base64Encoded: body), data.first == 0x30 else { return nil }
        return data
    }

    // MARK: file names

    /// Where to write the document for `file`: next to it, with .p7s / .p7m removed (repeatedly, for
    /// files signed several times), never overwriting anything (name-1, name-2, …).
    public static func outputURL(for file: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var name = file.lastPathComponent
        var stripped = false
        while ["p7s", "p7m"].contains((name as NSString).pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension
            stripped = true
        }
        if !stripped || name.isEmpty { name = file.lastPathComponent + ".extracted" }
        let directory = file.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        while exists(candidate) {
            let numbered = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    /// Extracts `file` and writes the document next to it. Returns where it was written and who signed.
    @discardableResult
    public static func extract(fileAt file: URL) throws -> (url: URL, signers: [String]) {
        let result = try extract(Data(contentsOf: file, options: .mappedIfSafe))
        let destination = outputURL(for: file)
        try result.content.write(to: destination, options: .withoutOverwriting)
        return (destination, result.signers)
    }
}
