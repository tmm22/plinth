import Foundation

// MARK: - Hosts Plinth never downloads from or uploads to
//
// Shared by the image-to-3D download (model links, the download itself and every redirect, ImageTo3D.swift) and
// 3DAPI's presigned upload link (`dapiUploadURLProblem`, DapiClient.swift). Both take a link from a service's reply,
// so a tampered or compromised reply must never point Plinth at the Mac itself or the seller's network.

/// The last labels of names that only ever mean the Mac or the seller's own network: `localhost` (RFC 6761), `local`
/// (mDNS, RFC 6762), `internal` (reserved for private use), `arpa` (`home.arpa`, RFC 8375, and reverse-lookup names),
/// and `localdomain`, `lan` and `home`, which routers and `/etc/hosts` use. None is a public top-level domain.
let networkLocalOnlyTopLabels: Set<String> = ["localhost", "local", "internal", "arpa", "localdomain", "lan", "home"]

/// True for a host Plinth never downloads from or uploads to: a local name (`localhost`, `*.localhost`, `*.local`,
/// `*.internal`, `*.home.arpa` and the other `networkLocalOnlyTopLabels`), a single-label name such as `router`, an IP
/// literal in any spelling URLSession resolves (IPv6, or IPv4 written as one to four decimal, octal or hex parts, such
/// as `127.1`, `2130706433`, `017700000001`, `0x7f000001` or `127.0x1`), or anything but a plain ASCII DNS name
/// (zone IDs, brackets, percent signs, non-ASCII). Case and trailing dots are ignored, as DNS ignores them.
///
/// It is a check of the name only: a public name that resolves to a private or loopback address (a DNS record
/// pointing at 127.0.0.1, say) still passes, because a name check can't see where a name resolves.
func networkHostIsLocalOrLiteral(_ raw: String) -> Bool {
    // ASCII first, so no other script's letter can lower-case into an ASCII one (the Kelvin sign becomes "k").
    guard raw.unicodeScalars.allSatisfy(\.isASCII) else { return true }
    var host = raw.lowercased()
    while host.hasSuffix(".") { host.removeLast() }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.".unicodeScalars)
    // IPv6 (':'), zone IDs ('%'), brackets, spaces and non-ASCII all fail here.
    guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains) else { return true }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, !labels.contains(where: \.isEmpty), let last = labels.last else { return true }
    if networkLocalOnlyTopLabels.contains(String(last)) { return true }
    // Every IPv4 spelling ends in a label that starts with a digit; no top-level domain does (they are letters, or
    // punycode `xn--…`).
    return !(last.first.map { $0.isLetter } ?? false)
}
