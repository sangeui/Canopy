import SwiftUI
import XCTest
@testable import Canopy

/// diff 화면을 창 없이 이미지로 그려 본다. `GROVE_RENDER_DIR`이 있으면 PNG로 남긴다.
@MainActor
final class RenderTests: XCTestCase {
    private let sampleDiff = """
    diff --git a/App.swift b/App.swift
    index 1111..2222 100644
    --- a/App.swift
    +++ b/App.swift
    @@ -1,5 +1,6 @@
     import Foundation

     struct App {
         let name = "Grove"
    -    let version = "0.1"
    +    let version = "0.2"
    +    let author = "sangeui"
     }
    diff --git a/Old.swift b/Renamed.swift
    similarity index 100%
    rename from Old.swift
    rename to Renamed.swift

    """

    private func save(_ image: CGImage?, as name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["GROVE_RENDER_DIR"], let image else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func testDiffViewRenders() throws {
        let files = DiffParser.parse(sampleDiff)
        // ScrollView 안의 LazyVStack은 ImageRenderer가 그리지 않으므로 카드만 바로 그린다.
        let change = FileChange(path: "App.swift", originalPath: nil, kind: .modified, area: .unstaged)
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(files) { DiffFileCard(file: $0, showsHeader: true, change: change) }
        }
        .padding(14)
        .frame(width: 720)
        .background(Theme.surface)
        .environment(RepositoryStore())
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        XCTAssertNotNil(renderer.cgImage)
        try save(renderer.cgImage, as: "diff-view.png")
    }

    func testCommitDetailRenders() throws {
        let files = DiffParser.parse(sampleDiff)
        let commit = Commit(
            hash: "e888065c0d1b7d0a9e3c2f1a4b5c6d7e8f901234",
            shortHash: "e888065",
            authorName: "Demo",
            authorEmail: "demo@example.com",
            date: Date(timeIntervalSince1970: 1_761_500_000),
            parents: ["abc"],
            refs: ["HEAD -> main", "tag: v0.1"],
            subject: "Add version",
            body: "Bump to 0.2 and record the author."
        )
        let view = CommitDetailContent(commit: commit, files: files, isLoading: false)
            .frame(width: 720)
            .background(Theme.surface)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        XCTAssertNotNil(renderer.cgImage)
        try save(renderer.cgImage, as: "commit-detail.png")
    }
}

