import XCTest
@testable import Lookout

/// SPEC §12.4: jump to a window that is open *now*, and resolve a git worktree to the repository
/// whose window actually hosts it.
final class WorktreeJumpTests: XCTestCase {
    private var temporary: URL?

    override func tearDown() {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporary = url
        return url
    }

    // MARK: - The open windows (SPEC §12.4)

    /// Shaped like the real `globalStorage/storage.json` on this Mac.
    private let storage = Data("""
    {
      "windowsState": {
        "lastActiveWindow": {
          "folder": "file:///Users/you/Desktop/Nova%20v2%28mobil%29",
          "uiState": {"mode": 1}
        },
        "openedWindows": [
          {"folder": "file:///Users/you/Desktop/Acme/acme-web"},
          {"folder": "file:///Users/you/Desktop/Lookout"},
          {"backupPath": "/Users/you/Library/…/Backups/1"},
          {"folder": "file:///Users/you/Desktop/Nova%20v2%28mobil%29"}
        ]
      },
      "profileAssociations": {"workspaces": {"file:///Users/you/Desktop/never-open": "__default__"}}
    }
    """.utf8)

    func testTheOpenWindowsAreReadAndPercentDecoded() {
        let folders = WorkspaceIndex.openFolders(json: storage)
        XCTAssertEqual(folders, [
            "/Users/you/Desktop/Acme/acme-web",
            "/Users/you/Desktop/Lookout",
            // `Nova%20v2%28mobil%29` → `Nova v2(mobil)`, and the last-active window is the
            // same one, so it is not listed twice.
            "/Users/you/Desktop/Nova v2(mobil)",
        ])
        XCTAssertFalse(
            folders.contains("/Users/you/Desktop/never-open"),
            "profileAssociations lists workspaces that are not open"
        )
        XCTAssertTrue(WorkspaceIndex.openFolders(json: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(WorkspaceIndex.openFolders(json: Data("{}".utf8)).isEmpty)
    }

    func testTheLastActiveWindowCountsEvenWhenItIsNotInTheList() {
        let folders = WorkspaceIndex.openFolders(json: Data("""
        {"windowsState":{"lastActiveWindow":{"folder":"file:///Users/you/Desktop/Voyager"}}}
        """.utf8))
        XCTAssertEqual(folders, ["/Users/you/Desktop/Voyager"])
    }

    // MARK: - Candidates (SPEC §12.4)

    func testAWorktreeResolvesToItsMainRepository() throws {
        let root = try makeDirectory()
        let repository = root.appendingPathComponent("Acme/acme-web")
        let worktree = root.appendingPathComponent("Acme/_wt/wt-export-import")
        let nested = worktree.appendingPathComponent("src/components")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        // In a worktree, `.git` is a *file* that points back at the repository.
        try Data(
            "gitdir: \(repository.path)/.git/worktrees/wt-export-import\n".utf8
        ).write(to: worktree.appendingPathComponent(".git"))

        XCTAssertEqual(
            WorkspaceIndex.mainRepository(forWorktreeAt: worktree.path), repository.path
        )
        // The walk goes up from a subdirectory too.
        XCTAssertEqual(
            WorkspaceIndex.mainRepository(forWorktreeAt: nested.path), repository.path
        )
        // The repository itself has a `.git` *directory* — nothing to resolve.
        XCTAssertNil(WorkspaceIndex.mainRepository(forWorktreeAt: repository.path))
        XCTAssertNil(WorkspaceIndex.mainRepository(forWorktreeAt: root.path))
        XCTAssertNil(WorkspaceIndex.mainRepository(forWorktreeAt: ""))
    }

    func testTheGitFileIsParsedAndAnythingElseIsRefused() {
        XCTAssertEqual(
            WorkspaceIndex.repository(fromGitFile: "gitdir: /a/b/repo/.git/worktrees/wt\n"),
            "/a/b/repo"
        )
        XCTAssertEqual(
            WorkspaceIndex.repository(fromGitFile: "  gitdir:   /a/b/repo/.git/worktrees/wt  "),
            "/a/b/repo"
        )
        // A submodule's `.git` file points into `.git/modules`, not `worktrees` — not ours.
        XCTAssertNil(WorkspaceIndex.repository(fromGitFile: "gitdir: /a/b/repo/.git/modules/sub"))
        XCTAssertNil(WorkspaceIndex.repository(fromGitFile: "ref: refs/heads/main"))
        XCTAssertNil(WorkspaceIndex.repository(fromGitFile: ""))
    }

    func testTheCandidatesAreCwdThenOriginThenTheRepository() throws {
        let root = try makeDirectory()
        let repository = root.appendingPathComponent("repo")
        let worktree = root.appendingPathComponent("_wt/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        try Data("gitdir: \(repository.path)/.git/worktrees/feature".utf8)
            .write(to: worktree.appendingPathComponent(".git"))

        var session = Session()
        session.sessionID = "s1"
        session.cwd = worktree.path
        session.originCwd = worktree.path
        XCTAssertEqual(
            WorkspaceIndex.candidates(for: session), [worktree.path, repository.path]
        )

        // Different cwd and origin_cwd: both are candidates, in that order.
        session.originCwd = "/Users/you/Desktop/elsewhere"
        XCTAssertEqual(
            WorkspaceIndex.candidates(for: session),
            [worktree.path, "/Users/you/Desktop/elsewhere", repository.path]
        )

        // Nothing at all is no candidates, not a crash.
        XCTAssertTrue(WorkspaceIndex.candidates(for: Session()).isEmpty)
    }

    // MARK: - Matching (SPEC §12.4)

    func testTheLongestOpenFolderThatContainsACandidateWins() {
        let open = WorkspaceIndex.openFolders(json: storage)

        // Exact match.
        XCTAssertEqual(
            WorkspaceIndex.bestOpenFolder(
                for: ["/Users/you/Desktop/Lookout"], among: open
            ),
            "/Users/you/Desktop/Lookout"
        )
        // A directory inside an open window.
        XCTAssertEqual(
            WorkspaceIndex.bestOpenFolder(
                for: ["/Users/you/Desktop/Lookout/Sources/Lookout"], among: open
            ),
            "/Users/you/Desktop/Lookout"
        )
        // The worktree itself is open in no window; its repository is — and the candidates are
        // tried in order, so the repository is what the jump aims at.
        XCTAssertEqual(
            WorkspaceIndex.bestOpenFolder(
                for: [
                    "/Users/you/Desktop/Acme/_wt/wt-export-import",
                    "/Users/you/Desktop/Acme/acme-web",
                ],
                among: open
            ),
            "/Users/you/Desktop/Acme/acme-web"
        )
        // The decoded name matches a candidate with real spaces and brackets in it.
        XCTAssertEqual(
            WorkspaceIndex.bestOpenFolder(
                for: ["/Users/you/Desktop/Nova v2(mobil)/docs"], among: open
            ),
            "/Users/you/Desktop/Nova v2(mobil)"
        )
    }

    func testTheLongerOfTwoNestedOpenWindowsWins() {
        let open = [
            "/Users/you/Desktop/Acme",
            "/Users/you/Desktop/Acme/acme-web",
        ]
        XCTAssertEqual(
            WorkspaceIndex.bestOpenFolder(
                for: ["/Users/you/Desktop/Acme/acme-web/src"], among: open
            ),
            "/Users/you/Desktop/Acme/acme-web"
        )
    }

    /// The §12.1 bug: no open window for this session means activate the app, never open a new
    /// window — which is what `nil` here tells `Jumper`.
    func testNoOpenWindowMeansNoFolderToOpen() {
        let open = WorkspaceIndex.openFolders(json: storage)
        XCTAssertNil(
            WorkspaceIndex.bestOpenFolder(
                for: ["/Users/you/Desktop/Acme/_wt/wt-export-import"], among: open
            )
        )
        XCTAssertNil(WorkspaceIndex.bestOpenFolder(for: ["/tmp/elsewhere"], among: open))
        XCTAssertNil(WorkspaceIndex.bestOpenFolder(for: [], among: open))
        XCTAssertNil(WorkspaceIndex.bestOpenFolder(for: ["/Users/you"], among: []))
        // A prefix only counts on a path boundary.
        XCTAssertNil(
            WorkspaceIndex.bestOpenFolder(
                for: ["/Users/you/Desktop/LookoutArchive"], among: open
            )
        )
    }

    func testTheStorageFilePathIsTheGlobalOneNotTheWorkspaceOne() {
        let cursor = WorkspaceIndex.globalStorageFile(app: "Cursor").path
        XCTAssertTrue(cursor.hasSuffix(
            "Library/Application Support/Cursor/User/globalStorage/storage.json"
        ))
        XCTAssertTrue(WorkspaceIndex.globalStorageFile(app: "Devin").path.contains("/Devin/"))
        XCTAssertEqual(Jumper.workspaceStorageApp(for: .vscode), "Code")
        XCTAssertEqual(Jumper.launchArguments(for: .devin), ["-b", "com.exafunction.windsurf"])
        // A file that is not there yields no folders rather than throwing.
        XCTAssertTrue(
            WorkspaceIndex.openFolders(
                inStorageFile: URL(fileURLWithPath: "/tmp/lookout-no-such-storage.json")
            ).isEmpty
        )
    }
}
