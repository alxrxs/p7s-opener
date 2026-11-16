import Foundation
import Testing
@testable import P7SOpenerCore

/// Real .p7s files made by LibreSSL (/usr/bin/openssl, part of macOS) in every encoding found in the wild.
final class Samples: @unchecked Sendable {
    static let shared = Samples()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("p7s-tests-\(UUID().uuidString)")
    let document = Data("Hello, signed world! %PDF-1.7 \u{0}\u{1}\u{2} binary bytes".utf8)

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? document.write(to: directory.appendingPathComponent("doc.pdf"))
        run("openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -subj '/CN=Test Signer/C=RO' -days 2")
    }

    @discardableResult
    func run(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "cd '\(directory.path)' && PATH=/usr/bin:/bin \(command) >/dev/null 2>&1"]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Signs (or encrypts) `input` with openssl `arguments`, returning the file's bytes.
    func make(_ name: String, _ arguments: String, input: String = "doc.pdf") throws -> Data {
        let recipient = arguments.contains("-encrypt") ? " c.pem" : " -signer c.pem -inkey k.pem"
        #expect(run("openssl \(arguments) -in \(input) -out \(name)\(recipient)") == 0)
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

@Suite struct ExtractionTests {
    let samples = Samples.shared

    @Test(arguments: [
        "cms -sign -nodetach -binary -outform DER",            // plain DER
        "cms -sign -nodetach -binary -outform DER -stream",    // BER, indefinite lengths
        "cms -sign -nodetach -binary -outform PEM",            // PEM
        "smime -sign -nodetach -binary -outform SMIME",        // S/MIME message (.p7m from email)
        "smime -sign -nodetach -binary -outform DER",          // legacy PKCS#7
    ])
    func extractsEveryEncoding(arguments: String) throws {
        let file = try samples.make("sample-\(abs(arguments.hashValue)).p7s", arguments)
        let result = try Extractor.extract(file)
        #expect(result.content == samples.document)
        #expect(result.signers == ["Test Signer"])
    }

    @Test func unwrapsDoubleSignedFiles() throws {
        _ = try samples.make("once.pdf.p7m", "cms -sign -nodetach -binary -outform DER")
        let twice = try samples.make("twice.pdf.p7m.p7m", "cms -sign -nodetach -binary -outform DER", input: "once.pdf.p7m")
        let result = try Extractor.extract(twice)
        #expect(result.content == samples.document)
        #expect(result.signers == ["Test Signer", "Test Signer"])
    }

    @Test func explainsDetachedAndEncryptedFiles() throws {
        let detached = try samples.make("detached.p7s", "cms -sign -binary -outform DER")
        #expect(throws: Extractor.Failure.detached) { try Extractor.extract(detached) }
        let encrypted = try samples.make("encrypted.p7m", "cms -encrypt -binary -outform DER")
        #expect(throws: Extractor.Failure.encrypted) { try Extractor.extract(encrypted) }
    }

    @Test func refusesOtherFiles() {
        #expect(throws: Extractor.Failure.notSigned) { try Extractor.extract(Data("just some text".utf8)) }
        #expect(throws: Extractor.Failure.notSigned) { try Extractor.extract(Data([0x30, 0x03, 0x02, 0x01, 0x05])) }
        // Hostile nesting must fail cleanly, not crash.
        let deep = Data([UInt8](repeating: 0x30, count: 2) + [UInt8](repeating: 0x80, count: 1) + [UInt8](repeating: 0x30, count: 5000))
        #expect(throws: (any Error).self) { try Extractor.extract(deep) }
    }
}

@Suite struct NamingTests {
    @Test func stripsSignatureExtensionsAndNeverOverwrites() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let none: (URL) -> Bool = { _ in false }
        #expect(Extractor.outputURL(for: folder.appendingPathComponent("invoice.pdf.p7s"), exists: none).lastPathComponent == "invoice.pdf")
        #expect(Extractor.outputURL(for: folder.appendingPathComponent("act.pdf.P7M"), exists: none).lastPathComponent == "act.pdf")
        #expect(Extractor.outputURL(for: folder.appendingPathComponent("act.pdf.p7m.p7m"), exists: none).lastPathComponent == "act.pdf")
        #expect(Extractor.outputURL(for: folder.appendingPathComponent("contract.p7s"), exists: none).lastPathComponent == "contract")
        #expect(Extractor.outputURL(for: folder.appendingPathComponent("mystery.bin"), exists: none).lastPathComponent == "mystery.bin.extracted")
        let taken: Set<String> = ["invoice.pdf", "invoice-1.pdf"]
        #expect(Extractor.outputURL(for: folder.appendingPathComponent("invoice.pdf.p7s"), exists: { taken.contains($0.lastPathComponent) })
            .lastPathComponent == "invoice-2.pdf")
    }

    @Test func writesNextToTheFile() throws {
        let samples = Samples.shared
        _ = try samples.make("letter.pdf.p7s", "cms -sign -nodetach -binary -outform DER")
        let first = try Extractor.extract(fileAt: samples.directory.appendingPathComponent("letter.pdf.p7s"))
        let second = try Extractor.extract(fileAt: samples.directory.appendingPathComponent("letter.pdf.p7s"))
        #expect(first.url.lastPathComponent == "letter.pdf" && second.url.lastPathComponent == "letter-1.pdf")
        #expect(try Data(contentsOf: second.url) == samples.document)
    }
}
