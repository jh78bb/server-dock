import SwiftUI

/// Terminal Git menu appears only inside a repository.
/// run=true executes read-only queries; false inserts repository-changing commands for review/manual Return.
struct GitCommandItem: Identifiable {
    let id = UUID()
    let command: String
    let detail: String
    let run: Bool
}

struct GitCommandGroup: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let items: [GitCommandItem]
}

enum GitCommands {
    static let groups: [GitCommandGroup] = [
        GitCommandGroup(title: String(localized: "Status & Changes"), symbol: "doc.text.magnifyingglass", items: [
            GitCommandItem(command: "git status -sb", detail: String(localized: "Short status with branch"), run: true),
            GitCommandItem(command: "git diff", detail: String(localized: "Unstaged changes"), run: true),
            GitCommandItem(command: "git diff --staged", detail: String(localized: "Staged changes"), run: true),
            GitCommandItem(command: "git diff --stat", detail: String(localized: "Changed files summary"), run: true),
        ]),
        GitCommandGroup(title: String(localized: "History"), symbol: "clock.arrow.circlepath", items: [
            GitCommandItem(command: "git log --oneline -20", detail: String(localized: "Last 20 commits"), run: true),
            GitCommandItem(command: "git log --graph --oneline --all -20", detail: String(localized: "Branch graph"), run: true),
            GitCommandItem(command: "git show --stat HEAD", detail: String(localized: "Latest commit"), run: true),
            GitCommandItem(command: "git shortlog -sn --all", detail: String(localized: "Commits per author"), run: true),
        ]),
        GitCommandGroup(title: String(localized: "Branches & Remotes"), symbol: "arrow.triangle.branch", items: [
            GitCommandItem(command: "git branch -vv", detail: String(localized: "Branches with upstream"), run: true),
            GitCommandItem(command: "git branch -a", detail: String(localized: "All branches"), run: true),
            GitCommandItem(command: "git remote -v", detail: String(localized: "Remotes"), run: true),
            GitCommandItem(command: "git tag --sort=-creatordate", detail: String(localized: "Tags, newest first"), run: true),
            GitCommandItem(command: "git stash list", detail: String(localized: "Stashes"), run: true),
        ]),
        GitCommandGroup(title: String(localized: "Sync"), symbol: "arrow.down.circle", items: [
            GitCommandItem(command: "git fetch --all --prune", detail: String(localized: "Download remote changes without merging"), run: true),
            GitCommandItem(command: "git pull --ff-only", detail: String(localized: "Fast-forward to the remote (fails instead of merging)"), run: true),
        ]),
        GitCommandGroup(title: String(localized: "Change (typed, not run)"), symbol: "pencil", items: [
            GitCommandItem(command: "git add -A", detail: String(localized: "Stage everything"), run: false),
            GitCommandItem(command: "git commit -m \"\"", detail: String(localized: "Commit staged changes"), run: false),
            GitCommandItem(command: "git push", detail: String(localized: "Upload commits"), run: false),
            GitCommandItem(command: "git stash", detail: String(localized: "Set aside uncommitted changes"), run: false),
            GitCommandItem(command: "git stash pop", detail: String(localized: "Bring back the latest stash"), run: false),
            GitCommandItem(command: "git switch -", detail: String(localized: "Back to the previous branch"), run: false),
        ]),
    ]

    /// Up to 30 local branches ordered by recent commit; empty for nonrepositories/failure.
    static func branches(host: Host, cwd: String) async -> [String] {
        guard let ssh = host.ssh else { return [] }
        let b64 = Data(cwd.utf8).base64EncodedString()
        let script = """
        P=$(printf %s '\(b64)' | base64 -d) || exit 1
        cd "$P" 2>/dev/null || exit 1
        T=""; command -v timeout >/dev/null 2>&1 && T="timeout 5"
        GIT_OPTIONAL_LOCKS=0 $T git -c core.fsmonitor=false for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads 2>/dev/null | head -30
        """
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let r = await RemoteFS(ssh).run("sh -c \(quoted)", timeout: 8)
        guard r.code == 0, let out = String(data: r.data, encoding: .utf8) else { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
