import XCTest
@testable import Plinth

/// The shared host check behind the image-to-3D download (links, the download and redirects) and 3DAPI's presigned
/// upload link. Pure: nothing here touches the network.
final class NetworkHostSafetyTests: XCTestCase {
    /// Spellings of loopback, LAN and local names that URLSession resolves (checked against a local listener in the
    /// verification), plus IPv6 and zone IDs.
    static let hostile = ["127.0.0.1", "127.0.0.1.", "2130706433", "127.1", "0x7f.0.0.1", "0x7f000001", "0X7F000001", "017700000001",
                          "0177.0.0.1", "127.0x1", "127.0.0.0x1", "127.0.0X1", "0", "0.0.0.0", "localhost", "localhost.", "LOCALHOST",
                          "foo.localhost.", "printer.local.", "PRINTER.LOCAL", "metadata.google.internal", "[::1]", "[::ffff:127.0.0.1]",
                          "[fe80::1%25en0]", "10.0.0.1.", "router", "1.0x7f", "192.168.0.0x1"]
    /// Real model and storage hosts: Meshy's and Tripo's CDNs, S3, CloudFront, GCS, R2, BOS, OSS, an upper-case name
    /// with a trailing dot, punycode, and names with digits, hyphens and underscores.
    static let real = ["assets.meshy.ai", "cdn.meshy.ai", "cdn.tripo3d.ai", "CDN.Tripo3D.ai.", "my-bucket.s3.us-east-1.amazonaws.com",
                       "d111111abcdef8.cloudfront.net", "storage.googleapis.com", "abc.r2.cloudflarestorage.com", "tripo-data.cdn.bcebos.com",
                       "bucket.oss-cn-hangzhou.aliyuncs.com", "xn--fiqs8s.xn--fiqz9s", "1.example-cdn.io", "a_b.cdn.example.com",
                       "dapi-uploads.s3.eu-central-1.amazonaws.com", "files.example.com"]

    func testHostileSpellingsAreRefusedAndRealHostsAllowed() {
        XCTAssertEqual(Self.hostile.count, 28)
        XCTAssertEqual(Self.real.count, 15)
        for host in Self.hostile {
            XCTAssertTrue(networkHostIsLocalOrLiteral(host), host)
            // As URL parses it, where it parses at all.
            if let parsed = URL(string: "https://\(host)/m.stl")?.host {
                XCTAssertTrue(networkHostIsLocalOrLiteral(parsed), "\(host) parsed as \(parsed)")
            }
        }
        for host in Self.real {
            XCTAssertFalse(networkHostIsLocalOrLiteral(host), host)
            XCTAssertFalse(networkHostIsLocalOrLiteral(URL(string: "https://\(host)/m.stl")!.host!), host)
        }
    }

    func testOtherLocalNamesAndOddCharactersAreRefused() {
        for host in ["", ".", "..", "a..b", ".cdn.example.com", "nas.home.arpa", "1.0.0.127.in-addr.arpa", "router.lan", "box.home",
                     "printer.localdomain", "cdn.example.com:443", "cdn example.com", "cdn.example.com/x", "bücher.de",
                     "printer.loca\u{212A}", "cdn.example.123", "cdn.example.1a"] {
            XCTAssertTrue(networkHostIsLocalOrLiteral(host), host)
        }
        for host in ["a.b", "cdn.example.co.uk", "xn--p1ai.xn--p1ai", "s3.amazonaws.com."] {
            XCTAssertFalse(networkHostIsLocalOrLiteral(host), host)
        }
    }

    func testTheImageTo3DDownloadUsesIt() {
        for host in Self.hostile {
            guard let url = URL(string: "https://\(host)/m.stl") else { continue }
            XCTAssertNotNil(imageTo3DDownloadURLProblem(url), host)
            XCTAssertFalse(imageTo3DRedirectAllowed(from: URL(string: "https://cdn.tripo3d.ai/a.stl"), to: url), host)
            XCTAssertTrue(imageTo3DModelURLs(["stl": "https://\(host)/m.stl"]).isEmpty, host)
        }
        for host in Self.real {
            let url = URL(string: "https://\(host)/m.stl?X-Amz-Signature=1")!
            XCTAssertNil(imageTo3DDownloadURLProblem(url), host)
            XCTAssertTrue(imageTo3DRedirectAllowed(from: URL(string: "https://cdn.meshy.ai/a.stl"), to: url), host)
        }
        // Tripo's documented link without an extension.
        XCTAssertNil(imageTo3DDownloadURLProblem(URL(string: "https://cdn.tripo3d.ai/output/converted-model")!))
        let tripo = tripoTaskStatus(["code": 0, "data": ["task_id": "c1", "status": "success",
                                                         "output": ["model_url": "https://2130706433/output/converted-model"]]])
        XCTAssertEqual(tripo?.modelURLs, [:], "a Tripo link to a numeric address is dropped")
    }

    func testThe3DAPIUploadLinkUsesIt() {
        for host in Self.hostile {
            guard let url = URL(string: "https://\(host)/a.stl") else { continue }
            XCTAssertNotNil(dapiUploadURLProblem(url), host)
        }
        for host in ["127.0x1", "127.0.0.0x1", "192.168.0.0x1", "LOCALHOST", "localhost.", "printer.local.", "nas.home.arpa"] {
            XCTAssertEqual(dapiUploadURLProblem(URL(string: "https://\(host)/a.stl")!), "it points to a local or numeric address", host)
        }
        for host in Self.real {
            XCTAssertNil(dapiUploadURLProblem(URL(string: "https://\(host)/temp/a.stl?X-Amz-Signature=x")!), host)
        }
        // Its other checks are unchanged.
        XCTAssertNil(dapiUploadURLProblem(URL(string: "https://files.example.com:443/a.stl")!))
        XCTAssertNotNil(dapiUploadURLProblem(URL(string: "https://files.example.com:8443/a.stl")!))
        XCTAssertNotNil(dapiUploadURLProblem(URL(string: "http://files.example.com/a.stl")!))
        XCTAssertNotNil(dapiUploadURLProblem(URL(string: "https://user:pw@files.example.com/a.stl")!))
        XCTAssertNotNil(dapiUploadURLProblem(URL(string: "https://files.example.com/a.stl#x")!))
        XCTAssertNotNil(dapiUploadURLProblem(URL(string: "https://files.example.com/a.stl?k=dapi-test-key-1234")!, apiKey: "dapi-test-key-1234"))
    }
}
