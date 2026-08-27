// Copyright (c) 2026 DOTS
// `dotsplugin` CLI: keygen / pack / sign / verify for `.dotsplugin` packages.

import CryptoKit
import Foundation
import DotsHarnessCore

struct KeyFile: Codable {
    var id: String
    var privateKey: String
    var publicKey: String
}

let usage = """
dotsplugin keygen <publisher-id> [-o key.json]
dotsplugin pack   <folder> [-o out.dotsplugin]
dotsplugin sign   <package.dotsplugin> --key key.json [-o package.dotsplugin.sig]
dotsplugin verify <package.dotsplugin> --sig file.sig (--key key.json | --publishers publishers.json)
"""

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func flag(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { die(usage) }
let rest = Array(args.dropFirst())

do {
    switch command {
    case "keygen":
        guard let publisher = rest.first, !publisher.hasPrefix("-") else { die(usage) }
        let priv = Curve25519.Signing.PrivateKey()
        let key = KeyFile(
            id: publisher,
            privateKey: priv.rawRepresentation.base64EncodedString(),
            publicKey: priv.publicKey.rawRepresentation.base64EncodedString()
        )
        let output = URL(fileURLWithPath: flag("-o", in: rest) ?? "\(publisher).key.json")
        try JSONEncoder().encode(key).write(to: output, options: .atomic)
        print("wrote \(output.path)")
        print("publisher \(publisher) pinned key: \(key.publicKey)")

    case "pack":
        guard let folder = rest.first, !folder.hasPrefix("-") else { die(usage) }
        let source = URL(fileURLWithPath: folder)
        let output = URL(fileURLWithPath: flag("-o", in: rest) ?? source.lastPathComponent + ".dotsplugin")
        try PluginPackage.pack(folder: source, to: output)
        print("packed \(output.path)  sha256=\(try PluginPackage.sha256(of: output))")

    case "sign":
        guard let package = rest.first, !package.hasPrefix("-") else { die(usage) }
        guard let keyPath = flag("--key", in: rest) else { die(usage) }
        let keyFile = try JSONDecoder().decode(KeyFile.self, from: Data(contentsOf: URL(fileURLWithPath: keyPath)))
        guard let privData = Data(base64Encoded: keyFile.privateKey) else { die("bad private key") }
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privData)
        let signature = try PluginPackage.sign(
            package: URL(fileURLWithPath: package),
            publisher: keyFile.id,
            privateKey: priv
        )
        let output = URL(fileURLWithPath: flag("-o", in: rest) ?? package + ".sig")
        try JSONEncoder().encode(signature).write(to: output, options: .atomic)
        print("wrote \(output.path)")

    case "verify":
        guard let package = rest.first, !package.hasPrefix("-") else { die(usage) }
        guard let sigPath = flag("--sig", in: rest) else { die(usage) }
        let signature = try JSONDecoder().decode(
            PluginSignature.self,
            from: Data(contentsOf: URL(fileURLWithPath: sigPath))
        )
        var publishers: [String: String] = [:]
        if let keyPath = flag("--key", in: rest) {
            let keyFile = try JSONDecoder().decode(KeyFile.self, from: Data(contentsOf: URL(fileURLWithPath: keyPath)))
            publishers[keyFile.id] = keyFile.publicKey
        } else if let pubPath = flag("--publishers", in: rest) {
            publishers = try JSONDecoder().decode(
                [String: String].self,
                from: Data(contentsOf: URL(fileURLWithPath: pubPath))
            )
        } else {
            die(usage)
        }
        try PluginPackage.verify(
            package: URL(fileURLWithPath: package),
            signature: signature,
            publishers: publishers
        )
        print("OK  publisher=\(signature.publisher)  sha256=\(signature.sha256)")

    default:
        die(usage)
    }
} catch {
    die("error: \(error.localizedDescription)")
}
