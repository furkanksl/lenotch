import CryptoKit
import Foundation

// Signs LeNotch's update files for Sparkle (EdDSA = Ed25519 over the file's bytes, which Sparkle checks against
// SUPublicEDKey in the app's Info.plist). Built and run by tools/updates.sh.
//
//   tools/updates.sh keygen            new update-signing key (refuses to overwrite one)
//   tools/updates.sh pubkey            the public key for SUPublicEDKey in Resources/Info.plist
//   tools/updates.sh sign <file>       prints sparkle:edSignature="…" length="…" for the appcast
//   tools/updates.sh verify <file> <public-key> <signature>
//
// Back up the private key from .release/keys (0600). Installed copies trust the matching public key.

let keyDirectory = URL(fileURLWithPath: ".release/keys", isDirectory: true)
let keyFile = keyDirectory.appendingPathComponent("ed25519-private.key")
let publicKeyFile = keyDirectory.appendingPathComponent("ed25519-public.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No valid update-signing key at \(keyFile.path). Restore the original key for an existing release.")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    let files = FileManager.default
    let legacyKey = files.homeDirectoryForCurrentUser.appendingPathComponent(".config/lenotch/update-signing.key")
    guard ![keyFile, publicKeyFile, legacyKey].contains(where: { files.fileExists(atPath: $0.path) }) else {
        fail("A signing key already exists at .release/keys or ~/.config/lenotch. Keep the existing key.")
    }
    if let data = files.contents(atPath: "Resources/Info.plist"),
       let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
       let publicKey = info["SUPublicEDKey"] as? String, !publicKey.isEmpty {
        fail("This app already has a public signing key. Restore the matching private key from backup.")
    }
    try files.createDirectory(at: keyDirectory, withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: keyFile, options: .withoutOverwriting)
    try Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8)
        .write(to: publicKeyFile, options: .withoutOverwriting)
    print("Sparkle key pair written to .release/keys. Back up the private key securely.")
case "pubkey":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2 else { fail("usage: tools/updates.sh sign <file>") }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
    let key = loadKey()
    let signature = try key.signature(for: data)
    print("sparkle:edSignature=\"\(signature.base64EncodedString())\" length=\"\(data.count)\"")
case "verify":
    guard args.count == 4 else { fail("usage: tools/updates.sh verify <file> <public-key> <signature>") }
    guard let raw = Data(base64Encoded: args[2]),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let signature = Data(base64Encoded: args[3]) else { fail("Invalid public key or signature.") }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: data) else { fail("Invalid update signature for \(args[1]).") }
default:
    fail("usage: tools/updates.sh keygen | pubkey | sign <file> | verify <file> <public-key> <signature>")
}
