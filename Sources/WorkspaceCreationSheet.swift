import SwiftUI

/// Sheet dialog for creating a new workspace via Cmd+N or the sidebar "+" button.
@MainActor
struct WorkspaceCreationSheet: View {

    enum Mode: String, CaseIterable, Identifiable {
        case newBranch
        case existingBranch
        case emptyWorkspace

        var id: String { rawValue }

        var label: String {
            switch self {
            case .newBranch:
                return String(localized: "workspace.creation.mode.newBranch", defaultValue: "New branch")
            case .existingBranch:
                return String(localized: "workspace.creation.mode.existingBranch", defaultValue: "Existing branch")
            case .emptyWorkspace:
                return String(localized: "workspace.creation.mode.emptyWorkspace", defaultValue: "Empty workspace")
            }
        }
    }

    // MARK: - State

    @State private var mode: Mode = .newBranch
    @State private var branchName: String = ""
    @State private var baseBranch: String = "main"
    @State private var selectedBranch: String = ""
    @State private var branchSearch: String = ""
    @State private var availableBranches: [String] = []
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    // MARK: - Callbacks

    let repoPath: String?
    let onCreateNewBranch: (String, String) -> Void
    let onExistingBranch: (String) -> Void
    let onEmptyWorkspace: () -> Void
    let onCancel: () -> Void

    // MARK: - Computed

    private var hasGitRepo: Bool { repoPath != nil }

    private var filteredBranches: [String] {
        let query = branchSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return availableBranches }
        return availableBranches.filter { $0.lowercased().contains(query) }
    }

    private var isCreateDisabled: Bool {
        if isCreating { return true }
        switch mode {
        case .newBranch:
            return branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .existingBranch:
            return selectedBranch.isEmpty
        case .emptyWorkspace:
            return false
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "workspace.creation.title", defaultValue: "New Workspace"))
                .font(.headline)

            modeRadioGroup

            Divider()

            modeContent

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .lineLimit(3)
            }

            Spacer(minLength: 4)

            HStack {
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "common.create", defaultValue: "Create")) {
                    handleCreate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreateDisabled)
            }
        }
        .padding(20)
        .frame(width: 400, height: 350)
        .task {
            await loadBranchData()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var modeRadioGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Mode.allCases) { modeCase in
                HStack(spacing: 6) {
                    Image(systemName: mode == modeCase ? "circle.inset.filled" : "circle")
                        .font(.system(size: 12))
                        .foregroundColor(
                            gitModeDisabled(modeCase) ? .secondary.opacity(0.5) : .accentColor
                        )
                    Text(modeCase.label)
                        .foregroundColor(
                            gitModeDisabled(modeCase) ? .secondary.opacity(0.5) : .primary
                        )
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !gitModeDisabled(modeCase) else { return }
                    mode = modeCase
                    errorMessage = nil
                }
            }

            if !hasGitRepo {
                Text(String(
                    localized: "workspace.creation.noGitRepo",
                    defaultValue: "No git repository detected"
                ))
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .newBranch:
            newBranchContent
        case .existingBranch:
            existingBranchContent
        case .emptyWorkspace:
            emptyWorkspaceContent
        }
    }

    @ViewBuilder
    private var newBranchContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "workspace.creation.branchName", defaultValue: "Branch name"))
                .font(.subheadline)
            TextField(
                String(localized: "workspace.creation.branchNamePlaceholder", defaultValue: "feature/my-branch"),
                text: $branchName
            )
            .textFieldStyle(.roundedBorder)

            Text(String(localized: "workspace.creation.baseBranch", defaultValue: "Base branch"))
                .font(.subheadline)
            Picker("", selection: $baseBranch) {
                ForEach(availableBranches, id: \.self) { branch in
                    Text(branch).tag(branch)
                }
            }
            .labelsHidden()
        }
        .disabled(!hasGitRepo)
    }

    @ViewBuilder
    private var existingBranchContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "workspace.creation.searchBranch", defaultValue: "Search branches"))
                .font(.subheadline)
            TextField(
                String(localized: "workspace.creation.searchPlaceholder", defaultValue: "Type to filter..."),
                text: $branchSearch
            )
            .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredBranches, id: \.self) { branch in
                        branchRow(branch)
                    }
                }
            }
            .frame(maxHeight: 120)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
        }
        .disabled(!hasGitRepo)
    }

    @ViewBuilder
    private var emptyWorkspaceContent: some View {
        Text(String(
            localized: "workspace.creation.emptyDescription",
            defaultValue: "Create a workspace without a git worktree."
        ))
        .font(.subheadline)
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func branchRow(_ branch: String) -> some View {
        let isSelected = selectedBranch == branch
        Text(branch)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            .cornerRadius(3)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedBranch = branch
            }
    }

    // MARK: - Helpers

    private func gitModeDisabled(_ modeCase: Mode) -> Bool {
        !hasGitRepo && modeCase != .emptyWorkspace
    }

    private func loadBranchData() async {
        guard let repoPath else {
            mode = .emptyWorkspace
            return
        }
        let manager = WorktreeManager()
        let branches = await manager.listBranches(repoPath: repoPath)
        let defaultBase = await manager.defaultBaseBranch(repoPath: repoPath)
        availableBranches = branches
        baseBranch = defaultBase
        if !branches.contains(defaultBase) && !branches.isEmpty {
            baseBranch = branches[0]
        }
    }

    private func handleCreate() {
        isCreating = true
        errorMessage = nil
        switch mode {
        case .newBranch:
            let name = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            onCreateNewBranch(name, baseBranch)
        case .existingBranch:
            onExistingBranch(selectedBranch)
        case .emptyWorkspace:
            onEmptyWorkspace()
        }
    }
}
