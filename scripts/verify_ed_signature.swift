// Checks a Sparkle EdDSA signature with the PUBLIC key only (no keychain, no private key).
// Sparkle signs the update archive's bytes with Ed25519; the app verifies them against SUPublicEDKey before
// installing. release.sh runs this so a feed signed with another key (a test key) never ships.
//
//   xcrun swift scripts/verify_ed_signature.swift <SUPublicEDKey base64> <sparkle:edSignature base64> <file>
// Exit 0: valid. Exit 1: invalid. Exit 2: bad arguments.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let keyData = Data(base64Encoded: args[1]), let signature = Data(base64Encoded: args[2]),
    let file = FileManager.default.contents(atPath: args[3])
else {
    FileHandle.standardError.write(Data("usage: verify_ed_signature.swift <public key b64> <signature b64> <file>\n".utf8))
    exit(2)
}
guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("not an Ed25519 public key\n".utf8))
    exit(2)
}
if key.isValidSignature(signature, for: file) {
    print("ok   EdDSA signature matches SUPublicEDKey")
    exit(0)
}
print("FAIL EdDSA signature does not match SUPublicEDKey")
exit(1)
