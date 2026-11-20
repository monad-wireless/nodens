import XCTest
@testable import NodensCore

final class ResolverPlanTests: XCTestCase {
    private let quad100 = ResolverPlan.quad100

    /// Extra records under the MagicDNS suffix, one split-DNS route with its own resolver.
    func testSuffixAndSplitRoute() {
        let entries = ResolverPlan.entries(
            magicDNSSuffix: "corp.internal",
            extraRecordNames: [
                "db.services.corp.internal",
                "cache.services.corp.internal",
            ],
            splitRoutes: [SplitRoute(domain: "k8s.internal", resolvers: ["10.43.0.10"])]
        )
        XCTAssertEqual(entries, [
            ResolverEntry(domain: "corp.internal", nameservers: [quad100]),
            ResolverEntry(domain: "k8s.internal", nameservers: ["10.43.0.10"]),
        ])
    }

    /// A Headscale tailnet whose service names live outside the MagicDNS suffix
    /// (node names under .tailnet, services under .internal).
    func testExtraRecordsOutsideTheSuffixGetTheirParentDomain() {
        let entries = ResolverPlan.entries(
            magicDNSSuffix: "lab.tailnet.",
            extraRecordNames: ["grafana.lab.internal", "otlp.lab.internal", "a.b.lab.internal"],
            splitRoutes: []
        )
        XCTAssertEqual(entries, [
            ResolverEntry(domain: "lab.internal", nameservers: [quad100]),
            ResolverEntry(domain: "lab.tailnet", nameservers: [quad100]),
        ])
    }

    func testPublicDomainsAreNeverRouted() {
        let entries = ResolverPlan.entries(
            magicDNSSuffix: "example.ts.net",
            extraRecordNames: ["grafana.example.com", "wiki.example.edu"],
            splitRoutes: []
        )
        XCTAssertEqual(entries, [ResolverEntry(domain: "example.ts.net", nameservers: [quad100])])
    }

    func testInvalidInputIsDropped() {
        let entries = ResolverPlan.entries(
            magicDNSSuffix: "",
            extraRecordNames: ["localhost", "bad_name.lab.internal", "x.internal"],
            splitRoutes: [
                SplitRoute(domain: ".", resolvers: ["10.0.0.1"]),
                SplitRoute(domain: "internal", resolvers: ["10.0.0.1"]),
                SplitRoute(domain: "doh.lab.internal", resolvers: ["https://dns.example/dns-query"]),
            ]
        )
        XCTAssertEqual(entries, [])
    }

    func testSplitRouteWinsOverABroaderDomain() {
        let entries = ResolverPlan.entries(
            magicDNSSuffix: "corp.internal",
            extraRecordNames: [],
            splitRoutes: [SplitRoute(domain: "k8s.corp.internal", resolvers: ["10.43.0.10"])]
        )
        XCTAssertEqual(entries, [
            ResolverEntry(domain: "corp.internal", nameservers: [quad100]),
            ResolverEntry(domain: "k8s.corp.internal", nameservers: ["10.43.0.10"]),
        ])
    }

    func testFileContents() {
        let entry = ResolverEntry(domain: "corp.internal", nameservers: [quad100])
        XCTAssertEqual(entry.fileContents, "nameserver 100.100.100.100\ntimeout 2\n")
    }

    func testEntriesFile() {
        let text = ResolverPlan.entriesFile([
            ResolverEntry(domain: "lab.internal", nameservers: ["100.100.100.100"]),
            ResolverEntry(domain: "k8s.internal", nameservers: ["10.43.0.10", "10.43.0.11"]),
            ResolverEntry(domain: "bad_domain.internal", nameservers: ["10.0.0.1"]),
            ResolverEntry(domain: "x.internal", nameservers: ["not-an-ip"]),
        ])
        XCTAssertEqual(text, "lab.internal 100.100.100.100\nk8s.internal 10.43.0.10 10.43.0.11\n")
    }

    func testDomainValidation() {
        XCTAssertTrue(ResolverPlan.isValidDomain("k8s.corp.internal"))
        XCTAssertFalse(ResolverPlan.isValidDomain("internal"))
        XCTAssertFalse(ResolverPlan.isValidDomain("a..internal"))
        XCTAssertFalse(ResolverPlan.isValidDomain("-a.internal"))
        XCTAssertFalse(ResolverPlan.isValidDomain("a/b.internal"))
        XCTAssertFalse(ResolverPlan.isValidDomain("Upper.internal"))
    }

    func testIPAddressValidation() {
        XCTAssertTrue(ResolverPlan.isIPAddress("10.43.0.10"))
        XCTAssertTrue(ResolverPlan.isIPAddress("fd7a:115c:a1e0::53"))
        XCTAssertFalse(ResolverPlan.isIPAddress("10.43.0"))
        XCTAssertFalse(ResolverPlan.isIPAddress("dns.example"))
    }
}
