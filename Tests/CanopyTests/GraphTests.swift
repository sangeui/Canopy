import XCTest
@testable import Canopy

final class CommitGraphTests: XCTestCase {
    private func commit(_ hash: String, parents: [String], refs: [String] = [], subject: String = "") -> Commit {
        Commit(hash: hash, shortHash: String(hash.prefix(7)), authorName: "a", authorEmail: "a@x", date: Date(), parents: parents, refs: refs, subject: subject, body: "")
    }

    /// feature가 develop에서 갈라졌고 HEAD다. develop의 옛 커밋은 develop 것이어야 한다.
    func testFeatureDoesNotClaimBaseHistory() {
        let commits = [
            commit("f2", parents: ["f1"], refs: ["HEAD -> feature/x", "origin/feature/x"]),
            commit("f1", parents: ["d2"]),
            commit("d2", parents: ["d1"], refs: ["develop", "origin/develop"]),
            commit("d1", parents: []),
        ]
        let graph = CommitGraph.build(commits, remoteNames: ["origin"])
        XCTAssertEqual(graph.owner(of: "f2")?.name, "feature/x")
        XCTAssertEqual(graph.owner(of: "f1")?.name, "feature/x")
        XCTAssertEqual(graph.owner(of: "d2")?.name, "develop")
        XCTAssertEqual(graph.owner(of: "d1")?.name, "develop")
        XCTAssertTrue(graph.owner(of: "f2")?.isHead == true)
        XCTAssertEqual(graph.rows[0].lane, 0)
    }

    /// 아직 받지 않은 origin/main 커밋이 내 커밋보다 아래에 있다. main의 선은 origin/main 끝 위로 이어지지 않고
    /// 갈라진 커밋(m1)까지 자기 열로 내려가서 합쳐져야 한다. 그렇지 않으면 o2의 자식처럼 보인다.
    func testBranchJoinsParentLaneAtForkPoint() {
        let commits = [
            commit("m3", parents: ["m1"], refs: ["HEAD -> main"]),
            commit("o2", parents: ["o1"], refs: ["origin/main"]),
            commit("o1", parents: ["m1"]),
            commit("m1", parents: ["m0"]),
            commit("m0", parents: []),
        ]
        let graph = CommitGraph.build(commits, remoteNames: ["origin"])
        XCTAssertEqual(graph.owner(of: "m1")?.name, "origin/main")
        let head = graph.rows[0], tip = graph.rows[1], fork = graph.rows[3]
        XCTAssertEqual(head.lane, 0)
        XCTAssertEqual(head.outgoing, [0], "main은 자기 열로 내려간다")
        XCTAssertFalse(tip.hasIncoming, "origin/main 끝 위로 들어오는 선이 없어야 한다")
        XCTAssertTrue(tip.through.contains(0), "main의 선이 옆으로 지나간다")
        XCTAssertEqual(fork.lane, tip.lane)
        XCTAssertEqual(fork.incomingFrom, [0], "갈라진 커밋에서 main의 선이 합쳐진다")
    }

    /// develop에 P(1일) Y(2일) Z(4일), feature는 P에서 갈라져 X(3일). 날짜순 목록은 Z X Y P.
    /// X의 선은 develop 열에 바로 합류하면 Y에서 갈라진 것처럼 보인다. P까지 따로 내려가 합쳐져야 한다.
    func testBranchJoinsAtItsRealParentWhenParentLaneIsOpen() {
        let commits = [
            commit("Z", parents: ["Y"], refs: ["develop"]),
            commit("X", parents: ["P"], refs: ["HEAD -> feature/x"]),
            commit("Y", parents: ["P"]),
            commit("P", parents: []),
        ]
        let graph = CommitGraph.build(commits, remoteNames: [])
        let x = graph.rows[1], y = graph.rows[2], p = graph.rows[3]
        XCTAssertEqual(graph.owner(of: "Y")?.name, "develop")
        XCTAssertFalse(x.outgoing.contains(y.lane), "X의 선이 Y의 열로 들어가지 않는다")
        XCTAssertTrue(y.incomingFrom.isEmpty, "Y로 합쳐지는 다른 선이 없다")
        XCTAssertEqual(p.incomingFrom.count, 1, "X의 선은 P에서 합쳐진다")
    }

    /// 기준 이름이 아니어도 끝이 깊은 브랜치가 먼저 커밋을 가져간다.
    func testDeeperTipWalksFirst() {
        let commits = [
            commit("b2", parents: ["b1"], refs: ["HEAD -> topic/b"]),
            commit("b1", parents: ["a1"]),
            commit("a1", parents: ["r1"], refs: ["topic/a"]),
            commit("r1", parents: []),
        ]
        let graph = CommitGraph.build(commits, remoteNames: [])
        XCTAssertEqual(graph.owner(of: "a1")?.name, "topic/a")
        XCTAssertEqual(graph.owner(of: "r1")?.name, "topic/a")
        XCTAssertEqual(graph.owner(of: "b1")?.name, "topic/b")
    }

    /// main: m3 ← m2 ← m1, feature: f1 ← m1. 머지 커밋 m3가 f1을 합쳤다.
    func testBranchAndMerge() {
        let commits = [
            commit("m3", parents: ["m2", "f1"], refs: ["HEAD -> main"], subject: "Merge branch 'feature'"),
            commit("f1", parents: ["m1"], refs: ["feature"]),
            commit("m2", parents: ["m1"]),
            commit("m1", parents: []),
        ]
        let graph = CommitGraph.build(commits, remoteNames: ["origin"])
        XCTAssertEqual(graph.owner(of: "m3")?.name, "main")
        XCTAssertEqual(graph.owner(of: "m2")?.name, "main")
        XCTAssertEqual(graph.owner(of: "m1")?.name, "main")
        XCTAssertEqual(graph.owner(of: "f1")?.name, "feature")
        XCTAssertTrue(graph.owner(of: "m3")?.isHead == true)

        // main은 0번 열, feature는 1번 열
        XCTAssertEqual(graph.rows[0].lane, 0)
        XCTAssertEqual(graph.rows[0].outgoing, [0, 1])
        XCTAssertFalse(graph.rows[0].hasIncoming)
        XCTAssertEqual(graph.rows[1].lane, 1)
        XCTAssertTrue(graph.rows[1].hasIncoming)
        XCTAssertEqual(graph.rows[1].through, [0])
        // f1의 부모는 m1이다. main 열에 바로 들어가면 m2에서 갈라진 것처럼 보이니 자기 열로 내려가 m1에서 합쳐진다.
        XCTAssertEqual(graph.rows[1].outgoing, [1])
        XCTAssertEqual(graph.rows[2].lane, 0)
        XCTAssertTrue(graph.rows[2].through.contains(1))
        XCTAssertEqual(graph.rows[3].lane, 0)
        XCTAssertEqual(graph.rows[3].incomingFrom, [1])
        XCTAssertTrue(graph.rows[3].outgoing.isEmpty)
        XCTAssertEqual(graph.maxLaneCount, 2)
        XCTAssertEqual(graph.mergeDescriptions["m3"], "feature → main 머지")
        XCTAssertEqual(graph.legend.map(\.name), ["main", "feature"])
    }

    /// 머지된 뒤 브랜치가 지워진 경우 메시지에서 이름을 추측한다.
    func testMergedBranchWithoutRef() {
        let commits = [
            commit("m3", parents: ["m2", "f1"], refs: ["HEAD -> main"], subject: "Merge branch 'feature/login' into main"),
            commit("f1", parents: ["m1"]),
            commit("m2", parents: ["m1"]),
            commit("m1", parents: []),
        ]
        let graph = CommitGraph.build(commits, remoteNames: [])
        XCTAssertEqual(graph.owner(of: "f1")?.name, "feature/login (머지됨)")
        XCTAssertTrue(graph.owner(of: "f1")?.isMerged == true)
        XCTAssertEqual(graph.mergeDescriptions["m3"], "feature/login (머지됨) → main 머지")
    }

    /// 원격이 앞서 있을 때 로컬 브랜치가 자기 커밋을 가져간다.
    func testLocalBranchWinsOverRemote() {
        let commits = [
            commit("r2", parents: ["l1"], refs: ["origin/main"]),
            commit("l1", parents: ["l0"], refs: ["HEAD -> main"]),
            commit("l0", parents: []),
        ]
        let graph = CommitGraph.build(commits, remoteNames: ["origin"])
        XCTAssertEqual(graph.owner(of: "r2")?.name, "origin/main")
        XCTAssertEqual(graph.owner(of: "l1")?.name, "main")
        XCTAssertEqual(graph.owner(of: "l0")?.name, "main")
        // 현재 브랜치가 0번 열을 예약하므로 origin/main은 1번 열에 간다.
        XCTAssertEqual(graph.rows[0].lane, 1)
        XCTAssertEqual(graph.rows[1].lane, 0)
    }

    func testAncestors() {
        let commits = [
            commit("c", parents: ["b"]),
            commit("x", parents: ["a"]),
            commit("b", parents: ["a"]),
            commit("a", parents: []),
        ]
        XCTAssertEqual(CommitGraph.ancestors(of: "c", in: commits), ["c", "b", "a"])
        XCTAssertEqual(CommitGraph.ancestors(of: "x", in: commits), ["x", "a"])
    }

    func testMergedBranchName() {
        XCTAssertEqual(CommitGraph.mergedBranchName(from: "Merge branch 'feature/x'"), "feature/x (머지됨)")
        XCTAssertEqual(CommitGraph.mergedBranchName(from: "Merge pull request #12 from org/fix-bug"), "fix-bug (머지됨)")
        XCTAssertEqual(CommitGraph.mergedBranchName(from: "Something else"), "머지된 브랜치")
    }
}

final class RefParserTests: XCTestCase {
    func testStashParser() {
        let f = "\u{1f}"
        let output = "stash@{0}\(f)aaaa\(f)1700000000\(f)On main: wip thing\u{1e}\nstash@{1}\(f)bbbb\(f)1600000000\(f)WIP on feature/x: 1234567 Subject\u{1e}\n"
        let stashes = StashParser.parse(output)
        XCTAssertEqual(stashes.count, 2)
        XCTAssertEqual(stashes[0].index, 0)
        XCTAssertEqual(stashes[0].ref, "stash@{0}")
        XCTAssertEqual(stashes[0].title, "wip thing")
        XCTAssertEqual(stashes[0].branch, "main")
        XCTAssertEqual(stashes[1].branch, "feature/x")
        XCTAssertEqual(stashes[1].title, "Subject")
    }

    func testTagParser() {
        let f = "\u{1f}"
        let output = "v1.0\(f)aaaa\(f)bbbb\(f)1700000000\(f)Release 1.0\u{1e}\nlight\(f)cccc\(f)\(f)1600000000\(f)Some commit\u{1e}\n"
        let tags = TagParser.parse(output)
        XCTAssertEqual(tags.count, 2)
        XCTAssertTrue(tags[0].isAnnotated)
        XCTAssertEqual(tags[0].targetHash, "bbbb")
        XCTAssertFalse(tags[1].isAnnotated)
        XCTAssertEqual(tags[1].targetHash, "cccc")
    }

    func testRemoteParser() {
        let output = "origin\tgit@github.com:a/b.git (fetch)\norigin\tgit@github.com:a/b.git (push)\nupstream\thttps://x/y (fetch)\n"
        let remotes = RemoteParser.parse(output)
        XCTAssertEqual(remotes.map(\.name), ["origin", "upstream"])
        XCTAssertEqual(remotes[1].url, "https://x/y")
    }

    func testHunkPatch() {
        let text = """
        diff --git a/A.swift b/A.swift
        index 1111..2222 100644
        --- a/A.swift
        +++ b/A.swift
        @@ -1,2 +1,3 @@
         a
        +b
         c

        """
        let file = DiffParser.parse(text)[0]
        let patch = file.patch(for: file.hunks[0])
        XCTAssertEqual(patch, "diff --git a/A.swift b/A.swift\n--- a/A.swift\n+++ b/A.swift\n@@ -1,2 +1,3 @@\n a\n+b\n c\n")
    }
}

final class ActivityParserTests: XCTestCase {
    func testDescribe() {
        XCTAssertEqual(ActivityParser.describe("checkout: moving from feature/login to main").1, "체크아웃 → main  (feature/login에서)")
        XCTAssertEqual(ActivityParser.describe("commit: Add version").1, "커밋: Add version")
        XCTAssertEqual(ActivityParser.describe("commit (amend): Fix").0, .amend)
        XCTAssertEqual(ActivityParser.describe("merge feature/login: Merge made by the 'ort' strategy.").1, "feature/login 머지")
        XCTAssertEqual(ActivityParser.describe("pull: Fast-forward").1, "풀 (fast-forward)")
        XCTAssertEqual(ActivityParser.describe("reset: moving to HEAD~1").1, "리셋 → HEAD~1")
        XCTAssertEqual(ActivityParser.describe("rebase (finish): returning to refs/heads/main").1, "리베이스 완료: main")
        XCTAssertEqual(ActivityParser.describe("cherry-pick: Thing").0, .cherryPick)
    }

    func testParse() {
        let f = "\u{1f}"
        let output = "aaaa\(f)aaa\(f)HEAD@{1761550000}\(f)commit: One\u{1e}\nbbbb\(f)bbb\(f)HEAD@{1761540000}\(f)checkout: moving from x to y\u{1e}\n"
        let entries = ActivityParser.parse(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].index, 0)
        XCTAssertEqual(entries[0].date, Date(timeIntervalSince1970: 1_761_550_000))
        XCTAssertEqual(entries[1].kind, .checkout)
    }

    func testNumstat() {
        let stat = NumstatParser.parse("3\t1\tA.swift\n-\t-\timg.png\n10\t0\tB.swift\n")
        XCTAssertEqual(stat.files, 3)
        XCTAssertEqual(stat.additions, 13)
        XCTAssertEqual(stat.deletions, 1)
    }
}

final class HistoryLayoutTests: XCTestCase {
    private func commit(_ hash: String, parents: [String], day: Int, refs: [String] = [], subject: String = "") -> Commit {
        Commit(hash: hash, shortHash: String(hash.prefix(7)), authorName: "a", authorEmail: "a@x", date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400 + 40_000), parents: parents, refs: refs, subject: subject, body: "")
    }

    /// main: m5 ← m4 ← m3 ← m2 ← m1. m4, m3, m2는 평범해서 접힌다. 날짜가 바뀌면 구분선이 들어간다.
    func testCompactGroupsAndDays() {
        let commits = [
            commit("m5", parents: ["m4"], day: 3, refs: ["HEAD -> main"]),
            commit("m4", parents: ["m3"], day: 3),
            commit("m3", parents: ["m2"], day: 2),
            commit("m2", parents: ["m1"], day: 2),
            commit("m1", parents: [], day: 1),
        ]
        let graph = CommitGraph.build(commits, remoteNames: [])
        let full = HistoryLayout(commits: commits, graph: graph, compact: false, expanded: [], selectedID: nil)
        XCTAssertEqual(full.items.map(\.id), ["c:m5", "c:m4", "c:m3", "c:m2", "c:m1"])
        // 날짜가 바뀌는 첫 줄에만 날짜가 얹힌다.
        let days = full.items.map { item -> Bool in
            if case .commit(_, _, let day) = item { return day != nil }
            return false
        }
        XCTAssertEqual(days, [true, false, true, false, true])

        let compact = HistoryLayout(commits: commits, graph: graph, compact: true, expanded: [], selectedID: nil)
        XCTAssertEqual(compact.items.map(\.id), ["c:m5", "c:m4", "g:m3", "c:m1"])

        let expanded = HistoryLayout(commits: commits, graph: graph, compact: true, expanded: ["m3"], selectedID: nil)
        XCTAssertTrue(expanded.items.contains { $0.id == "c:m2" })

        // 고른 커밋은 접히지 않는다.
        let selected = HistoryLayout(commits: commits, graph: graph, compact: true, expanded: [], selectedID: "m2")
        XCTAssertTrue(selected.items.contains { $0.id == "c:m2" })
    }

}

final class PathTreeTests: XCTestCase {
    func testBuild() {
        let tree = PathTree.build([("feature/login", 1), ("feature/settings", 2), ("main", 3), ("release/1.0/hotfix", 4)])
        XCTAssertEqual(tree.map(\.name), ["feature", "release", "main"])
        XCTAssertEqual(tree[0].children.map(\.name), ["login", "settings"])
        XCTAssertEqual(tree[0].leafCount, 2)
        XCTAssertEqual(tree[1].children[0].name, "1.0")
        XCTAssertEqual(tree[1].children[0].children[0].leaf, 4)
        XCTAssertEqual(tree[2].leaf, 3)
    }
}

final class MarkdownParserTests: XCTestCase {
    func testBlocks() {
        let source = """
        요약
        ---

        메인 배너 카드의 **크기** 값을 한 곳으로 모았습니다.

        ### 바꾸기 전

        | 값 | 아이폰 | 적혀 있던 곳 |
        | --- | --- | --- |
        | 카드 폭 | 312 | 3곳 |

        1. `A.swift`에 추가
        2. 레이아웃 함수가 씀
        - [ ] 할 일
        - [x] 한 일

        > 인용

        ```swift
        let a = 1
        ```
        """
        let blocks = MarkdownParser.parse(source)
        guard blocks.count == 7 else { return XCTFail("blocks: \(blocks)") }
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "요약"))
        XCTAssertEqual(blocks[1], .paragraph("메인 배너 카드의 **크기** 값을 한 곳으로 모았습니다."))
        XCTAssertEqual(blocks[2], .heading(level: 3, text: "바꾸기 전"))
        XCTAssertEqual(blocks[3], .table(header: ["값", "아이폰", "적혀 있던 곳"], rows: [["카드 폭", "312", "3곳"]]))
        if case .list(let items) = blocks[4] {
            XCTAssertEqual(items.count, 4)
            XCTAssertEqual(items[0].number, 1)
            XCTAssertEqual(items[2].checked, false)
            XCTAssertEqual(items[3].checked, true)
        } else {
            XCTFail("list expected")
        }
        XCTAssertEqual(blocks[5], .quote(["인용"]))
        XCTAssertEqual(blocks[6], .code(language: "swift", text: "let a = 1"))
    }

    func testInlineCode() {
        let text = MarkdownParser.inline("use `foo()` now")
        XCTAssertEqual(String(text.characters), "use foo() now")
    }
}

final class MarkdownHTMLTests: XCTestCase {
    func testCommentsAndHTML() {
        let source = """
        <!-- 템플릿 설명
        여러 줄 -->
        ## 요약
        <details open>
        <summary>펼치기</summary>
        내용<br>둘째 줄
        </details>
        ![스크린샷](https://example.com/a.png)
        <img src="https://example.com/b.png" width="300" alt="b">
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertFalse(blocks.contains { if case .paragraph(let text) = $0 { return text.contains("템플릿") } else { return false } })
        XCTAssertTrue(blocks.contains(.heading(level: 2, text: "요약")))
        XCTAssertTrue(blocks.contains(.paragraph("**펼치기**")))
        XCTAssertTrue(blocks.contains(.paragraph("내용 둘째 줄")))
        XCTAssertTrue(blocks.contains(.image(url: "https://example.com/a.png", alt: "스크린샷")))
        XCTAssertTrue(blocks.contains(.image(url: "https://example.com/b.png", alt: "b")))
    }
}


final class MarkdownBotHTMLTests: XCTestCase {
    func testNestedBotHTML() {
        let source = """
        <details>
        <summary><strong><picture><source media="(prefers-color-scheme: dark)" srcset="https://x/dark.svg"><img src="https://x/icon.svg" width="16" height="16" align="absmiddle" alt=""></picture> Commits</strong></summary>
        <dl>
        <dd>Reviewing files a < b.</dd>
        </dl>
        </details>
        <pre>let x = 1</pre>
        """
        let text = MarkdownParser.preprocess(source)
        XCTAssertFalse(text.contains("<d"), text)
        XCTAssertFalse(text.contains("picture"), text)
        let blocks = MarkdownParser.parse(source)
        XCTAssertTrue(blocks.contains(.paragraph("**** Commits****")) || blocks.contains(.paragraph("** Commits**")) || blocks.contains { if case .paragraph(let t) = $0 { return t.contains("Commits") } else { return false } })
        XCTAssertTrue(blocks.contains(.paragraph("Reviewing files a < b.")))
        XCTAssertTrue(blocks.contains(.code(language: nil, text: "let x = 1")))
        XCTAssertFalse(blocks.contains { if case .image = $0 { return true } else { return false } })
    }
}


final class WordDiffTests: XCTestCase {
    func testMarksOnlyChangedTokens() {
        let (old, new) = WordDiff.compare("let count = items.count + 1", "let count = items.count + 2")
        XCTAssertEqual(old, [26..<27])
        XCTAssertEqual(new, [26..<27])
    }

    func testMostlyDifferentLinesAreNotMarked() {
        let (old, new) = WordDiff.compare("return nil", "guard let value = map[key] else { continue }")
        XCTAssertTrue(old.isEmpty)
        XCTAssertTrue(new.isEmpty)
    }

    /// 변수 이름만 겹치고 구조가 다른 줄은 짝짓지 않는다. 지운 줄 셋에 더한 줄 하나일 때 특히.
    func testUnrelatedLinesAreNotPaired() {
        var hunk = DiffHunk(id: 1, header: "@@ -1,3 +1,1 @@", lines: [
            DiffLine(id: 1, kind: .deletion, text: "bannerImageView.layer.cornerRadius = isRegular ? 8 : 24", oldNumber: 1, newNumber: nil),
            DiffLine(id: 2, kind: .deletion, text: "bannerImageView.layer.borderWidth = isRegular ? 0 : 1", oldNumber: 2, newNumber: nil),
            DiffLine(id: 3, kind: .deletion, text: "bannerImageView.layer.borderColor = isRegular ? nil : UIColor.white.cgColor", oldNumber: 3, newNumber: nil),
            DiffLine(id: 4, kind: .addition, text: "CardMetrics.applyCornerAndBorder(to: bannerImageView.layer, isRegular: isRegular)", oldNumber: nil, newNumber: 1),
        ])
        WordDiff.annotate(&hunk)
        XCTAssertTrue(hunk.lines.allSatisfy { $0.marks.isEmpty })
        XCTAssertLessThan(WordDiff.similarity(hunk.lines[0].text, hunk.lines[3].text), 0.6)
    }

    func testAnnotatePairsDeletionsWithAdditions() {
        var hunk = DiffHunk(id: 1, header: "@@ -1,2 +1,2 @@ func load()", lines: [
            DiffLine(id: 1, kind: .deletion, text: "let a = 1", oldNumber: 1, newNumber: nil),
            DiffLine(id: 2, kind: .addition, text: "let a = 2", oldNumber: nil, newNumber: 1),
            DiffLine(id: 3, kind: .context, text: "print(a)", oldNumber: 2, newNumber: 2),
        ])
        WordDiff.annotate(&hunk)
        XCTAssertEqual(hunk.lines[0].marks, [8..<9])
        XCTAssertEqual(hunk.lines[1].marks, [8..<9])
        XCTAssertTrue(hunk.lines[2].marks.isEmpty)
        XCTAssertEqual(hunk.context, "func load()")
        XCTAssertEqual(hunk.newStart, 1)
    }

    func testChangedSymbols() {
        let file = DiffFile(id: 1, oldPath: "A.swift", newPath: "A.swift", hunks: [
            DiffHunk(id: 1, header: "@@ -10,4 +10,5 @@ final class Banner", lines: [
                DiffLine(id: 1, kind: .context, text: "    func layout() {", oldNumber: 10, newNumber: 10),
                DiffLine(id: 2, kind: .addition, text: "        apply()", oldNumber: nil, newNumber: 11),
                DiffLine(id: 3, kind: .context, text: "    }", oldNumber: 11, newNumber: 12),
                DiffLine(id: 4, kind: .context, text: "    private var height: CGFloat = 0", oldNumber: 12, newNumber: 13),
                DiffLine(id: 5, kind: .deletion, text: "    // old", oldNumber: 13, newNumber: nil),
            ]),
            DiffHunk(id: 2, header: "@@ -40,2 +41,3 @@ extension Banner", lines: [
                DiffLine(id: 6, kind: .addition, text: "    let x = 1", oldNumber: nil, newNumber: 41),
            ]),
        ], isBinary: false, headerLines: [])
        XCTAssertEqual(ChangedSymbols.symbols(in: file), ["func layout", "var height", "let x"])
    }
}


final class SkillCatalogTests: XCTestCase {
    func testFrontmatterWithBlockScalar() {
        let text = """
        ---
        name: review-file
        description: |
          GitHub PR에서 특정 파일을 중점적으로 리뷰합니다. 두 번째 문장.
          이어지는 줄.
        argument-hint: "<PR 번호> <파일 경로>"
        ---
        # 본문
        """
        let fields = SkillCatalog.frontmatter(text)
        XCTAssertEqual(fields["name"], "review-file")
        XCTAssertEqual(fields["argument-hint"], "\"<PR 번호> <파일 경로>\"")
        XCTAssertTrue(fields["description"]?.hasPrefix("GitHub PR에서") == true)
        XCTAssertTrue(fields["description"]?.contains("이어지는 줄") == true)
        XCTAssertEqual(SkillCatalog.firstSentence(fields["description"] ?? ""), "GitHub PR에서 특정 파일을 중점적으로 리뷰합니다.")
    }

    func testLoadReadsProjectSkills() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(".claude/skills/hello")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: hello\ndescription: 인사합니다. 더 길게.\nargument-hint: <이름>\n---\n".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let skills = SkillCatalog.load(projectRoot: root.path)
        let hello = try XCTUnwrap(skills.first { $0.name == "hello" })
        XCTAssertEqual(hello.summary, "인사합니다.")
        XCTAssertEqual(hello.argumentHint, "<이름>")
        XCTAssertEqual(hello.source, "프로젝트")
        XCTAssertEqual(hello.allowedTools, [])
        try? FileManager.default.removeItem(at: root)
    }

    func testAllowedToolsAreReadFromFrontmatter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(".claude/skills/generate-commit")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: generate-commit\ndescription: 커밋을 만듭니다.\nallowed-tools: Bash, Read, Grep, mcp__atlassian__getJiraIssue\ndisable-model-invocation: true\n---\n".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let skill = try XCTUnwrap(SkillCatalog.load(projectRoot: root.path).first { $0.name == "generate-commit" })
        XCTAssertEqual(skill.allowedTools, ["Bash", "Read", "Grep", "mcp__atlassian__getJiraIssue"])
        XCTAssertTrue(skill.isAboutCommit)
        try? FileManager.default.removeItem(at: root)
    }
}


final class CommandPaletteTests: XCTestCase {
    @MainActor
    func testScorePrefersEarlyAndTightMatches() {
        let exact = CommandPalette.score("feature/test-roate", "test")
        let loose = CommandPalette.score("feature/test-roate", "frte")
        XCTAssertNotNil(exact)
        XCTAssertNotNil(loose)
        XCTAssertLessThan(exact!, loose!)
        XCTAssertNil(CommandPalette.score("develop", "xyz"))
        XCTAssertLessThan(CommandPalette.score("push", "pu")!, CommandPalette.score("spun", "pu")!)
    }
}
