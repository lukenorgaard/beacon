import XCTest
@testable import Lookout

final class WorkspaceIndexTests: XCTestCase {
    private let roots = [
        "/Users/you/Desktop",
        "/Users/you/Desktop/Lookout",
        "/Users/you/Desktop/Example Demo Project",
        "/Users/you/Other",
    ]

    func testLongestPrefixWins() {
        XCTAssertEqual(
            WorkspaceIndex.bestRoot(for: "/Users/you/Desktop/Lookout/Sources/Lookout", among: roots),
            "/Users/you/Desktop/Lookout"
        )
    }

    func testAnExactMatchCounts() {
        XCTAssertEqual(
            WorkspaceIndex.bestRoot(for: "/Users/you/Desktop/Lookout", among: roots),
            "/Users/you/Desktop/Lookout"
        )
    }

    func testShallowerRootIsUsedWhenNothingDeeperMatches() {
        XCTAssertEqual(
            WorkspaceIndex.bestRoot(for: "/Users/you/Desktop/Beacon/Sources", among: roots),
            "/Users/you/Desktop"
        )
    }

    /// The whole reason for the boundary check: `/Users/you/Desktop` must not claim
    /// `/Users/you/DesktopArchive`.
    func testPrefixesOnlyMatchOnAPathBoundary() {
        XCTAssertNil(
            WorkspaceIndex.bestRoot(for: "/Users/you/DesktopArchive/thing", among: roots)
        )
    }

    func testTrailingSlashesAreIgnored() {
        XCTAssertEqual(
            WorkspaceIndex.bestRoot(
                for: "/Users/you/Desktop/Lookout/", among: ["/Users/you/Desktop/Lookout/"]
            ),
            "/Users/you/Desktop/Lookout/"
        )
    }

    func testNoMatchAndEmptyInputAreNil() {
        XCTAssertNil(WorkspaceIndex.bestRoot(for: "/tmp/elsewhere", among: roots))
        XCTAssertNil(WorkspaceIndex.bestRoot(for: "", among: roots))
        XCTAssertNil(WorkspaceIndex.bestRoot(for: "/Users/you/Desktop", among: []))
    }

    func testFileURIsArePercentDecoded() {
        XCTAssertEqual(
            WorkspaceIndex.path(fromFileURI: "file:///Users/you/Desktop/Example%20Demo%20Project"),
            "/Users/you/Desktop/Example Demo Project"
        )
        XCTAssertEqual(
            WorkspaceIndex.path(fromFileURI: "file:///Users/you/Desktop/fabrik"),
            "/Users/you/Desktop/fabrik"
        )
        XCTAssertNil(WorkspaceIndex.path(fromFileURI: "vscode-remote://ssh/thing"))
    }

    func testRootsAreReadFromAWorkspaceStorageTree() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-workspace-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: base) }

        for (folder, uri) in [
            ("aaa", "file:///Users/you/Desktop/fabrik"),
            ("bbb", "file:///Users/you/Desktop/Example%20Demo%20Project"),
        ] {
            let directory = base.appendingPathComponent(folder)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"folder": "\#(uri)"}"#.utf8)
                .write(to: directory.appendingPathComponent("workspace.json"))
        }
        // A storage folder with no workspace.json (an editor scratch dir) must be skipped.
        try fm.createDirectory(
            at: base.appendingPathComponent("ccc"), withIntermediateDirectories: true
        )

        let roots = WorkspaceIndex.roots(inStorage: base).sorted()
        XCTAssertEqual(
            roots,
            [
                "/Users/you/Desktop/Example Demo Project",
                "/Users/you/Desktop/fabrik",
            ]
        )
        XCTAssertEqual(
            WorkspaceIndex.bestRoot(
                for: "/Users/you/Desktop/Example Demo Project/src", among: roots
            ),
            "/Users/you/Desktop/Example Demo Project"
        )
    }

    func testTerminalAndITermReferenceHelpers() {
        XCTAssertEqual(Jumper.devicePath("ttys005"), "/dev/ttys005")
        XCTAssertEqual(Jumper.devicePath("s005"), "/dev/ttys005")
        XCTAssertEqual(Jumper.devicePath("/dev/ttys005"), "/dev/ttys005")
        XCTAssertNil(Jumper.devicePath(nil))
        XCTAssertNil(Jumper.devicePath(""))

        XCTAssertEqual(Jumper.itermSessionID("w0t0p0:8C1D6E20-4A7F"), "8C1D6E20-4A7F")
        XCTAssertEqual(Jumper.itermSessionID("8C1D6E20"), "8C1D6E20")
        XCTAssertNil(Jumper.itermSessionID(nil))
    }
}
