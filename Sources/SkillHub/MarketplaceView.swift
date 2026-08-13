import SwiftUI

// MARK: - 技能市场视图（自包含模块，不依赖 AppState）
//
// 安装分为 prepare / commit 两步：prepare 只下载并检查，用户在预览页确认后才 commit。

// MARK: - 安装状态

enum MarketplaceInstallState {
    case idle, preparing, ready, installing, success, failed
}

// MARK: - ViewModel

@MainActor
final class MarketplaceViewModel: ObservableObject {

    private enum LoadMode {
        case popular
        case search(query: String)
    }

    @Published var query = ""
    @Published private(set) var results: [MarketplaceSkill] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var installStates: [String: MarketplaceInstallState] = [:]
    @Published private(set) var descriptions: [String: String] = [:]
    @Published private(set) var preparedInstall: PreparedSkillInstall?
    @Published private(set) var preparationError: String?
    @Published private(set) var preparingSkillID: String?

    private let service: MarketplaceService
    private let onPrepare: (MarketplaceSkill) async throws -> PreparedSkillInstall
    private let onCommit: (PreparedSkillInstall) async -> Bool

    private var searchTask: Task<Void, Never>?
    private var lastMode: LoadMode = .popular
    private var attemptedDescriptions = Set<String>()
    private var preparedSkillID: String?

    init(
        service: MarketplaceService = MarketplaceService(),
        onPrepare: @escaping (MarketplaceSkill) async throws -> PreparedSkillInstall,
        onCommit: @escaping (PreparedSkillInstall) async -> Bool
    ) {
        self.service = service
        self.onPrepare = onPrepare
        self.onCommit = onCommit
    }

    /// 首次出现时装载热门榜单
    func onAppear() {
        guard results.isEmpty, !isLoading else { return }
        Task { await reload() }
    }

    /// 重试（按上一次的模式重新加载）
    func retry() {
        Task { await reload() }
    }

    /// 提交搜索；空查询回退到热门榜单
    func submitSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastMode = q.isEmpty ? .popular : .search(query: q)
        Task { await reload() }
    }

    /// 输入变化时做轻量防抖搜索（空查询自动回到热门榜单）
    func queryChanged() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.lastMode = q.isEmpty ? .popular : .search(query: q)
            await self.reload()
        }
    }

    private func reload() async {
        // 搜索词不足 2 个字符时不发请求（服务端也会拒绝）
        if case .search(let q) = lastMode, q.count < 2 { return }
        isLoading = true
        errorMessage = nil
        do {
            switch lastMode {
            case .popular:
                results = try await service.fetchPopular()
            case .search(let q):
                results = try await service.search(query: q)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: 安装

    func installState(for skill: MarketplaceSkill) -> MarketplaceInstallState {
        installStates[skill.id] ?? .idle
    }

    func prepare(_ skill: MarketplaceSkill) {
        guard preparingSkillID == nil else { return }
        preparationError = nil
        preparingSkillID = skill.id
        installStates[skill.id] = .preparing
        Task {
            do {
                let prepared = try await onPrepare(skill)
                preparedInstall = prepared
                preparedSkillID = skill.id
                installStates[skill.id] = .ready
            } catch {
                preparationError = error.localizedDescription
                installStates[skill.id] = .failed
            }
            preparingSkillID = nil
        }
    }

    func commitPreparedInstall() async -> Bool {
        guard let preparedInstall else { return false }
        let skillID = preparedSkillID
        if let skillID { installStates[skillID] = .installing }
        let ok = await onCommit(preparedInstall)
        if let skillID { installStates[skillID] = ok ? .success : .failed }
        if ok {
            self.preparedInstall = nil
            preparedSkillID = nil
        }
        return ok
    }

    func cancelPreparedInstall() {
        guard let preparedInstall else { return }
        SkillOps.discardPreparedInstall(preparedInstall)
        self.preparedInstall = nil
        if let preparedSkillID { installStates[preparedSkillID] = .idle }
        preparedSkillID = nil
    }

    func clearPreparationError() { preparationError = nil }

    // MARK: 描述补取

    func loadDescriptionIfNeeded(for skill: MarketplaceSkill) async {
        guard skill.description == nil,
              descriptions[skill.id] == nil,
              !attemptedDescriptions.contains(skill.id) else { return }
        attemptedDescriptions.insert(skill.id)
        if let d = await service.fetchDescription(for: skill), !d.isEmpty {
            descriptions[skill.id] = d
        }
    }
}

// MARK: - 视图

struct MarketplaceView: View {
    @StateObject private var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        onPrepare: @escaping (MarketplaceSkill) async throws -> PreparedSkillInstall,
        onCommit: @escaping (PreparedSkillInstall) async -> Bool
    ) {
        _viewModel = StateObject(wrappedValue: MarketplaceViewModel(
            onPrepare: onPrepare,
            onCommit: onCommit
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear {
            if viewModel.preparedInstall != nil { viewModel.cancelPreparedInstall() }
        }
        .sheet(
            item: Binding(
                get: { viewModel.preparedInstall },
                set: { if $0 == nil { viewModel.cancelPreparedInstall() } }
            )
        ) { prepared in
            InstallReviewSheet(
                prepared: prepared,
                destinationText: "安装到本体库，安装后再选择启用平台",
                onCancel: { viewModel.cancelPreparedInstall() },
                onConfirm: { await viewModel.commitPreparedInstall() }
            )
        }
        .alert(
            "无法准备安装",
            isPresented: Binding(
                get: { viewModel.preparationError != nil },
                set: { if !$0 { viewModel.clearPreparationError() } }
            )
        ) {
            Button("知道了") { viewModel.clearPreparationError() }
        } message: {
            Text(viewModel.preparationError ?? "未知错误")
        }
    }

    // MARK: 头部（标题 + 搜索框）

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("技能市场")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer()
                Text("skills.sh 生态")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
                .help("关闭")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索技能，如 pdf / webapp / testing…", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .onSubmit { viewModel.submitSearch() }
                    .onChange(of: viewModel.query) { viewModel.queryChanged() }
                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.results.isEmpty {
            Spacer()
            ProgressView("加载中…")
            Spacer()
        } else if let error = viewModel.errorMessage, viewModel.results.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { viewModel.retry() }
            }
            .padding()
            Spacer()
        } else if viewModel.results.isEmpty {
            Spacer()
            Text("没有找到相关技能")
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            List(viewModel.results) { skill in
                MarketplaceRow(
                    skill: skill,
                    description: viewModel.descriptions[skill.id] ?? skill.description,
                    installState: viewModel.installState(for: skill),
                    onInstall: { viewModel.prepare(skill) }
                )
                .task { await viewModel.loadDescriptionIfNeeded(for: skill) }
            }
            .listStyle(.inset)
        }
    }

}

// MARK: - 行视图

private struct MarketplaceRow: View {
    let skill: MarketplaceSkill
    let description: String?
    let installState: MarketplaceInstallState
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(skill.name)
                        .font(.headline)
                    Text(skill.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    if !skill.installsText.isEmpty {
                        Label(skill.installsText, systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Link("详情", destination: skill.skillPageURL)
                        .font(.caption)
                    Text("仅安装此 Skill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            installButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var installButton: some View {
        switch installState {
        case .idle:
            Button("安装") { onInstall() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .preparing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 52)
                .help("正在下载并检查")
        case .ready:
            Label("待确认", systemImage: "doc.text.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 52)
        case .success:
            Label("已安装", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Button("重试") { onInstall() }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
        }
    }
}

// MARK: - 安装确认

struct InstallReviewSheet: View {
    let prepared: PreparedSkillInstall
    let destinationText: String
    let onCancel: () -> Void
    let onConfirm: () async -> Bool

    @State private var isInstalling = false
    @State private var hasReviewedRisk = false
    @State private var localError: String?

    private var hasHighRisk: Bool {
        prepared.items.contains { $0.securityReport.highCount > 0 }
    }

    private var canInstall: Bool {
        !isInstalling && (!hasHighRisk || hasReviewedRisk)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("确认安装")
                        .font(.title2.bold())
                    Text("内容已下载到临时目录，确认前不会修改你的 Skills。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceSection
                    ForEach(prepared.items) { item in
                        itemSection(item)
                    }
                    if !prepared.skippedSkillNames.isEmpty {
                        Label(
                            "仓库中另外发现 \(prepared.skippedSkillNames.count) 个 Skills，本次不会安装。",
                            systemImage: "checkmark.shield"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    if hasHighRisk {
                        Toggle("我已查看高危命中，仍要安装", isOn: $hasReviewedRisk)
                            .toggleStyle(.checkbox)
                    }
                    if let localError {
                        Label(localError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Label(destinationText, systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isInstalling { ProgressView().controlSize(.small) }
                Button(hasHighRisk ? "仍要安装" : "安装") {
                    isInstalling = true
                    localError = nil
                    Task {
                        let ok = await onConfirm()
                        if !ok {
                            localError = "安装没有完成，原有 Skills 未被修改。请查看主窗口中的错误详情。"
                            isInstalling = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canInstall)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 620)
        .interactiveDismissDisabled(isInstalling)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("来源")
                .font(.headline)
            Text(prepared.sourceURL ?? prepared.source)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            if let commit = prepared.resolvedCommit {
                Text("Commit \(String(commit.prefix(12)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func itemSection(_ item: PreparedSkillInstall.Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.headline)
                    if !item.descriptionText.isEmpty {
                        Text(item.descriptionText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer()
                securityBadge(item.securityReport)
            }

            HStack(spacing: 16) {
                Label("\(item.fileCount) 个文件", systemImage: "doc.on.doc")
                Label(item.sizeDisplay, systemImage: "externaldrive")
                Text(item.skillPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !item.validationWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(item.validationWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !item.securityReport.findings.isEmpty {
                DisclosureGroup("查看安全命中（\(item.securityReport.findings.count)）") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(item.securityReport.findings.prefix(20).enumerated()), id: \.offset) { _, finding in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(finding.severity.displayName) · \(finding.message)")
                                    .font(.caption.bold())
                                Text("\(finding.file)\(finding.line.map { ":\($0)" } ?? "") · \(finding.snippet)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }

            DisclosureGroup("查看文件清单") {
                Text(item.files.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .font(.callout)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func securityBadge(_ report: SecurityReport) -> some View {
        let color: Color = report.highCount > 0 ? .red : (report.mediumCount > 0 ? .orange : .green)
        return Label("\(report.score) · \(report.grade.rawValue)", systemImage: "shield.checkered")
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }
}
