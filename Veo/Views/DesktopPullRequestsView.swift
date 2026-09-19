import SwiftUI

struct DesktopPullRequestsView: View {
    let threadID: String
    let repository: DesktopGitRepositorySnapshot
    @Environment(\.dismiss) private var dismiss
    @AppStorage("VeoDesktop.linkedPullRequests") private var linksJSON = "{}"
    @State private var requests: [DesktopPullRequest] = []
    @State private var reference = ""
    @State private var error: String?
    @State private var isBusy = false
    @State private var showsCreate = false
    @State private var title = ""
    @State private var description = ""
    @State private var base = "main"
    private let github = DesktopGitHubService()
    private var directory: URL { URL(fileURLWithPath: repository.rootPath) }
    private var links: [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self, from: Data(linksJSON.utf8))) ?? [:]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Pull requests").font(.headline)
                Spacer()
                Button("Refresh") { Task { await refresh() } }.disabled(isBusy)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("PR URL or number", text: $reference)
                Button("Link") { link() }.disabled(isBusy || reference.isEmpty)
                Button("Create draft PR…") { showsCreate.toggle() }.disabled(isBusy || repository.branchName == nil)
            }
            if showsCreate {
                GroupBox("Create draft pull request") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pushes committed changes on \(repository.branchName ?? "this branch") to origin. Uncommitted changes are not included.").font(.caption).foregroundStyle(.secondary)
                        TextField("Title", text: $title)
                        TextField("Base branch", text: $base)
                        TextField("Description", text: $description, axis: .vertical).lineLimit(3...8)
                        Button("Push & create draft PR") { create() }
                            .disabled(isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || base.isEmpty)
                    }.padding(8)
                }
            }
            if isBusy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(requests) { pr in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("#\(pr.number) · \(pr.title)").fontWeight(.semibold)
                                    Spacer()
                                    if let url = URL(string: pr.url) { Link("Open", destination: url) }
                                    Button("Unlink") { unlink(pr) }.controlSize(.small)
                                }
                                Text("\(pr.isDraft ? "Draft · " : "")\(pr.state.capitalized) · \(pr.headRefName) → \(pr.baseRefName)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let decision = pr.reviewDecision, !decision.isEmpty { Text(decision.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption) }
                                ForEach(Array((pr.statusCheckRollup ?? []).enumerated()), id: \.offset) { _, check in
                                    Text("\(check.name ?? check.context ?? "Check"): \(check.conclusion?.isEmpty == false ? check.conclusion! : check.state ?? check.status ?? "Pending")")
                                        .font(.caption).textSelection(.enabled)
                                }
                                if !pr.body.isEmpty { Text(pr.body).font(.callout).textSelection(.enabled) }
                                ForEach(Array(pr.comments.enumerated()), id: \.offset) { _, comment in
                                    Divider()
                                    Text(comment.author?.login ?? "Comment").font(.caption).foregroundStyle(.secondary)
                                    Text(comment.body).font(.callout).textSelection(.enabled)
                                }
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if requests.isEmpty, !isBusy {
                        Text("Link a pull request to keep its checks, comments, and merge status with this chat.").foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(22).frame(width: 680, height: 600)
        .task { await refresh() }
    }

    private func remember(_ pr: DesktopPullRequest) {
        var saved = links
        var urls = saved[threadID] ?? []
        if !urls.contains(pr.url) { urls.append(pr.url) }
        saved[threadID] = urls
        if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) { linksJSON = text }
        requests.removeAll { $0.url == pr.url }; requests.append(pr)
    }
    private func unlink(_ pr: DesktopPullRequest) {
        var saved = links; saved[threadID]?.removeAll { $0 == pr.url }
        if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) { linksJSON = text }
        requests.removeAll { $0.url == pr.url }
    }
    private func refresh() async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        var loaded: [DesktopPullRequest] = []
        for url in links[threadID] ?? [] {
            do { loaded.append(try await github.read(url, in: directory)) }
            catch { self.error = error.localizedDescription }
        }
        requests = loaded
    }
    private func link() {
        let captured = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true; error = nil
        Task {
            defer { isBusy = false }
            do { remember(try await github.read(captured, in: directory)); reference = "" }
            catch { self.error = error.localizedDescription }
        }
    }
    private func create() {
        guard let branch = repository.branchName, let head = repository.headObjectID else { return }
        let capturedTitle = title, capturedBody = description, capturedBase = base
        isBusy = true; error = nil
        Task {
            defer { isBusy = false }
            do {
                remember(try await github.create(title: capturedTitle, body: capturedBody, base: capturedBase, branch: branch, head: head, in: directory))
                showsCreate = false
            } catch { self.error = error.localizedDescription + " If the push or creation already succeeded, link the existing PR before retrying." }
        }
    }
}
