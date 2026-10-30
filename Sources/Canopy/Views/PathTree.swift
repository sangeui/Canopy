import SwiftUI

/// `feature/login`처럼 슬래시로 나뉜 이름을 폴더 트리로 묶는다.
struct PathNode<Leaf>: Identifiable {
    let name: String
    /// 루트부터의 경로. 폴더 접힘 상태의 열쇠로 쓴다.
    let path: String
    var children: [PathNode<Leaf>]
    var leaf: Leaf?

    var id: String { path }
    var isFolder: Bool { leaf == nil }

    /// 아래에 있는 잎의 수
    var leafCount: Int {
        leaf != nil ? 1 : children.reduce(0) { $0 + $1.leafCount }
    }
}

enum PathTree {
    /// 이름을 "/"로 잘라 트리를 만든다. 폴더가 먼저, 그다음 잎, 각각 이름순.
    static func build<Leaf>(_ items: [(name: String, leaf: Leaf)]) -> [PathNode<Leaf>] {
        var roots: [PathNode<Leaf>] = []
        for item in items {
            let parts = item.name.split(separator: "/").map(String.init)
            insert(parts[...], prefix: "", leaf: item.leaf, into: &roots)
        }
        sort(&roots)
        return roots
    }

    private static func insert<Leaf>(_ parts: ArraySlice<String>, prefix: String, leaf: Leaf, into nodes: inout [PathNode<Leaf>]) {
        guard let first = parts.first else { return }
        let path = prefix.isEmpty ? first : prefix + "/" + first
        if parts.count == 1 {
            nodes.append(PathNode(name: first, path: path, children: [], leaf: leaf))
            return
        }
        if let index = nodes.firstIndex(where: { $0.path == path && $0.isFolder }) {
            insert(parts.dropFirst(), prefix: path, leaf: leaf, into: &nodes[index].children)
        } else {
            var folder = PathNode<Leaf>(name: first, path: path, children: [], leaf: nil)
            insert(parts.dropFirst(), prefix: path, leaf: leaf, into: &folder.children)
            nodes.append(folder)
        }
    }

    private static func sort<Leaf>(_ nodes: inout [PathNode<Leaf>]) {
        nodes.sort { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for index in nodes.indices { sort(&nodes[index].children) }
    }
}

/// 폴더는 접고 펼 수 있고, 잎은 넘겨받은 뷰로 그린다.
struct PathTreeView<Leaf, Row: View>: View {
    let nodes: [PathNode<Leaf>]
    var depth = 0
    @Binding var collapsedFolders: Set<String>
    @ViewBuilder let row: (PathNode<Leaf>) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                FolderRow(node: node, depth: depth, isCollapsed: collapsedFolders.contains(node.path)) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if collapsedFolders.contains(node.path) {
                            collapsedFolders.remove(node.path)
                        } else {
                            collapsedFolders.insert(node.path)
                        }
                    }
                }
                if !collapsedFolders.contains(node.path) {
                    PathTreeView(nodes: node.children, depth: depth + 1, collapsedFolders: $collapsedFolders, row: row)
                }
            } else {
                row(node)
                    .padding(.leading, CGFloat(depth) * 16)
            }
        }
    }
}

private struct FolderRow<Leaf>: View {
    let node: PathNode<Leaf>
    let depth: Int
    let isCollapsed: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10)
                Text(node.name + "/")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(node.leafCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 16)
        .onHover { hovering = $0 }
    }
}
