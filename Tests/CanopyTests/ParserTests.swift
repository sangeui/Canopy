import XCTest
@testable import Canopy

final class StatusParserTests: XCTestCase {
    func testHeadersAndEntries() {
        let output = [
            "# branch.oid abc123",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 1111 2222 Sources/A.swift",
            "1 .M N... 100644 100644 100644 1111 1111 Sources/B.swift",
            "1 MM N... 100644 100644 100644 1111 2222 Sources/C.swift",
            "2 R. N... 100644 100644 100644 1111 1111 R100 New Name.swift",
            "Old Name.swift",
            "u UU N... 100644 100644 100644 100644 1111 2222 3333 conflict.txt",
            "? untracked.txt",
        ].joined(separator: "\u{0}") + "\u{0}"

        let snapshot = StatusParser.parse(output)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.upstream, "origin/main")
        XCTAssertEqual(snapshot.ahead, 2)
        XCTAssertEqual(snapshot.behind, 1)

        XCTAssertEqual(snapshot.staged.map(\.path), ["Sources/A.swift", "Sources/C.swift", "New Name.swift"])
        XCTAssertEqual(snapshot.unstaged.map(\.path), ["Sources/B.swift", "Sources/C.swift", "conflict.txt", "untracked.txt"])

        let rename = snapshot.staged.first { $0.path == "New Name.swift" }
        XCTAssertEqual(rename?.kind, .renamed)
        XCTAssertEqual(rename?.originalPath, "Old Name.swift")

        XCTAssertEqual(snapshot.unstaged.first { $0.path == "conflict.txt" }?.area, .conflicted)
        XCTAssertEqual(snapshot.unstaged.first { $0.path == "untracked.txt" }?.kind, .untracked)
    }

    func testInitialRepository() {
        let output = "# branch.oid (initial)\u{0}# branch.head main\u{0}"
        let snapshot = StatusParser.parse(output)
        XCTAssertNil(snapshot.headOID)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertTrue(snapshot.changes.isEmpty)
    }
}

final class LogParserTests: XCTestCase {
    func testTwoCommits() {
        let f = "\u{1f}"
        let output =
            "aaaa\(f)aaa\(f)Alice\(f)alice@example.com\(f)1700000000\(f)bbbb\(f)HEAD -> main, origin/main, tag: v1\(f)Second\(f)Body line\u{1e}\n" +
            "bbbb\(f)bbb\(f)Bob\(f)bob@example.com\(f)1600000000\(f)\(f)\(f)First\(f)\u{1e}\n"
        let commits = LogParser.parse(output)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].hash, "aaaa")
        XCTAssertEqual(commits[0].parents, ["bbbb"])
        XCTAssertEqual(commits[0].refs, ["HEAD -> main", "origin/main", "tag: v1"])
        XCTAssertEqual(commits[0].subject, "Second")
        XCTAssertEqual(commits[0].body, "Body line")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(commits[1].parents, [])
        XCTAssertEqual(commits[1].refs, [])
        XCTAssertEqual(commits[1].body, "")
    }
}

final class WorktreeParserTests: XCTestCase {
    func testThreeWorktrees() {
        let output = """
        worktree /repo
        HEAD 1111
        branch refs/heads/main

        worktree /repo-feature
        HEAD 2222
        branch refs/heads/feature/x
        locked

        worktree /repo-detached
        HEAD 3333
        detached

        """
        let worktrees = WorktreeParser.parse(output)
        XCTAssertEqual(worktrees.count, 3)
        XCTAssertTrue(worktrees[0].isMain)
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertEqual(worktrees[1].branch, "feature/x")
        XCTAssertTrue(worktrees[1].isLocked)
        XCTAssertFalse(worktrees[1].isMain)
        XCTAssertTrue(worktrees[2].isDetached)
        XCTAssertNil(worktrees[2].branch)
        XCTAssertEqual(worktrees[2].branchDisplay, "HEAD 분리됨 (3333)")
    }
}

final class BranchParserTests: XCTestCase {
    func testLocalAndRemote() {
        let f = "\u{1f}"
        let output =
            "refs/heads/main\(f)main\(f)*\(f)origin/main\(f)[ahead 1, behind 2]\(f)/repo\(f)abc\u{1e}\n" +
            "refs/heads/feature\(f)feature\(f) \(f)\(f)\(f)\(f)def\u{1e}\n" +
            "refs/remotes/origin/HEAD\(f)origin/HEAD\(f) \(f)\(f)\(f)\(f)abc\u{1e}\n" +
            "refs/remotes/origin/feature\(f)origin/feature\(f) \(f)\(f)\(f)\(f)def\u{1e}\n"
        let branches = BranchParser.parse(output)
        XCTAssertEqual(branches.map(\.name), ["main", "feature", "origin/feature"])
        XCTAssertTrue(branches[0].isHead)
        XCTAssertEqual(branches[0].ahead, 1)
        XCTAssertEqual(branches[0].behind, 2)
        XCTAssertEqual(branches[0].worktreePath, "/repo")
        XCTAssertFalse(branches[1].isHead)
        XCTAssertNil(branches[1].upstream)
        XCTAssertTrue(branches[2].isRemote)
        XCTAssertEqual(branches[2].nameWithoutRemote, "feature")
    }

    func testTrackParsing() {
        XCTAssertEqual(BranchParser.parseTrack("[gone]").ahead, 0)
        XCTAssertEqual(BranchParser.parseTrack("[behind 3]").behind, 3)
        XCTAssertEqual(BranchParser.parseTrack("").ahead, 0)
    }
}

final class DiffParserTests: XCTestCase {
    func testModifiedFile() {
        let text = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 1111..2222 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1,3 +1,4 @@
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        \\ No newline at end of file

        """
        let files = DiffParser.parse(text)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file.oldPath, "Sources/A.swift")
        XCTAssertEqual(file.newPath, "Sources/A.swift")
        XCTAssertEqual(file.hunks.count, 1)
        let lines = file.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .deletion, .addition, .addition, .context, .meta])
        XCTAssertEqual(lines[0].oldNumber, 1)
        XCTAssertEqual(lines[0].newNumber, 1)
        XCTAssertEqual(lines[1].oldNumber, 2)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[2].newNumber, 2)
        XCTAssertEqual(lines[3].newNumber, 3)
        XCTAssertEqual(lines[4].oldNumber, 3)
        XCTAssertEqual(lines[4].newNumber, 4)
        XCTAssertEqual(lines[5].text, "No newline at end of file")
    }

    func testNewBinaryAndRename() {
        let text = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000..1111
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        diff --git a/img.png b/img.png
        new file mode 100644
        index 0000..2222
        Binary files /dev/null and b/img.png differ
        diff --git a/old.txt b/renamed.txt
        similarity index 100%
        rename from old.txt
        rename to renamed.txt

        """
        let files = DiffParser.parse(text)
        XCTAssertEqual(files.count, 3)
        XCTAssertNil(files[0].oldPath)
        XCTAssertEqual(files[0].newPath, "new.txt")
        XCTAssertEqual(files[0].hunks[0].lines[0].newNumber, 1)
        XCTAssertTrue(files[1].isBinary)
        XCTAssertEqual(files[2].oldPath, "old.txt")
        XCTAssertEqual(files[2].newPath, "renamed.txt")
        XCTAssertTrue(files[2].isRename)
        XCTAssertTrue(files[2].hunks.isEmpty)
    }

    func testHunkStart() {
        XCTAssertEqual(DiffParser.hunkStart("@@ -12,7 +15,8 @@ func x()").old, 12)
        XCTAssertEqual(DiffParser.hunkStart("@@ -12,7 +15,8 @@ func x()").new, 15)
        XCTAssertEqual(DiffParser.hunkStart("@@ -0,0 +1 @@").new, 1)
    }
}

final class ReleaseParserTests: XCTestCase {
    func testSemanticVersionComparison() {
        XCTAssertTrue(AppInfo.isNewer(remote: "v0.2.0", than: "0.1.0"))
        XCTAssertTrue(AppInfo.isNewer(remote: "0.10.0", than: "0.2.0"))
        XCTAssertTrue(AppInfo.isNewer(remote: "1.0.0", than: "0.9.9"))
        XCTAssertFalse(AppInfo.isNewer(remote: "0.2.0", than: "0.2.0"))
        XCTAssertFalse(AppInfo.isNewer(remote: "0.1.9", than: "0.2.0"))
        XCTAssertFalse(AppInfo.isNewer(remote: "0.2.0", than: "개발 빌드"))
    }

    func testParseGitHubReleaseJSON() {
        let json = """
        {
          "tag_name": "v0.3.0",
          "name": "Canopy 0.3.0",
          "draft": false,
          "prerelease": false,
          "published_at": "2026-10-30T06:00:00Z",
          "html_url": "https://github.com/sangeui/Canopy/releases/tag/v0.3.0",
          "body": "## 변경 사항\\n\\n- **인앱 업데이트**: 새 버전을 자동으로 알려 줍니다.\\n- 버그 수정",
          "assets": [
            {
              "name": "Canopy-0.3.0.dmg",
              "browser_download_url": "https://github.com/sangeui/Canopy/releases/download/v0.3.0/Canopy-0.3.0.dmg"
            },
            {
              "name": "Canopy-0.3.0.dmg.sha256",
              "browser_download_url": "https://github.com/sangeui/Canopy/releases/download/v0.3.0/Canopy-0.3.0.dmg.sha256"
            }
          ]
        }
        """
        let release = ReleaseInfo.parse(json: Data(json.utf8))
        XCTAssertNotNil(release)
        XCTAssertEqual(release?.version, "0.3.0")
        XCTAssertEqual(release?.tagName, "v0.3.0")
        XCTAssertEqual(release?.dmgURL?.lastPathComponent, "Canopy-0.3.0.dmg")
        XCTAssertEqual(release?.sha256URL?.lastPathComponent, "Canopy-0.3.0.dmg.sha256")
        XCTAssertEqual(release?.summaryLine, "인앱 업데이트: 새 버전을 자동으로 알려 줍니다.")
    }

    func testParseReleaseWithoutDMGFallsBackToTarball() {
        let json = """
        {
          "tag_name": "v0.3.1",
          "name": "Canopy 0.3.1",
          "draft": false,
          "prerelease": false,
          "html_url": "https://github.com/sangeui/Canopy/releases/tag/v0.3.1",
          "tarball_url": "https://api.github.com/repos/sangeui/Canopy/tarball/v0.3.1",
          "body": "빠른 패치",
          "assets": []
        }
        """
        let release = ReleaseInfo.parse(json: Data(json.utf8))
        XCTAssertNotNil(release)
        XCTAssertNil(release?.dmgURL)
        XCTAssertEqual(release?.tarballURL?.absoluteString, "https://api.github.com/repos/sangeui/Canopy/tarball/v0.3.1")
    }
}
