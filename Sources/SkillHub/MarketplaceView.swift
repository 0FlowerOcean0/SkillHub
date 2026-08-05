import SwiftUI

// MARK: - 技能市场视图（自包含模块，不依赖 AppState）
//
// 对外接口（父 agent 接线时只需知道这些）：
//   MarketplaceView(onInstall:)
//     - onInstall: (String) async -> Bool，参数为仓库源标识（"owner/repo"，如 "anthropics/skills"），
//       返回安装是否成功。可省略，省略时用 `MarketplaceView.defaultInstallAction`。
//   MarketplaceViewModel(onInstall:service:)、MarketplaceService、MarketplaceSkill 均为内部实现细节，
//   但都是 internal 可测的。
//
// 接线示例（父 agent 自行完成，本模块不改任何现有文件）：
//   MarketplaceView { source in
//       await Task.detached {
//           (try? SkillOps.install(source: "https://github.com/\(source)",
//                                  storeDir: state.storeDir,
//                                  enableTargets: state.enabledTargets)) != nil
//       }.value
//   }

// MARK: - 安装状态

enum MarketplaceInstallState {
    case idle, installing, success, failed
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

    private let service: MarketplaceService
    private let onInstall: (String) async -> Bool

    private var searchTask: Task<Void, Never>?
    private var lastMode: LoadMode = .popular
    private var attemptedDescriptions = Set<String>()

    init(service: MarketplaceService = MarketplaceService(),
         onInstall: @escaping (String) async -> Bool) {
        self.service = service
        self.onInstall = onInstall
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

    func install(_ skill: MarketplaceSkill) {
        guard installState(for: skill) != .installing else { return }
        installStates[skill.id] = .installing
        Task {
            let ok = await onInstall(skill.source)
            installStates[skill.id] = ok ? .success : .failed
        }
    }

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

    /// - Parameter onInstall: 安装闭包。参数为仓库源标识（"owner/repo"），返回是否成功。
    init(onInstall: @escaping (String) async -> Bool = MarketplaceView.defaultInstallAction) {
        _viewModel = StateObject(wrappedValue: MarketplaceViewModel(onInstall: onInstall))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { viewModel.onAppear() }
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
                    onInstall: { viewModel.install(skill) }
                )
                .task { await viewModel.loadDescriptionIfNeeded(for: skill) }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - 默认安装实现（未接线时的退路）

    /// 默认实现：把仓库源标识（"owner/repo"）拼成 GitHub 仓库 URL，调用现有
    /// `SkillOps.install(source:storeDir:enableTargets:)` 整仓安装到 canonical 本体库
    /// `~/.agents/skills`，不自动启用到任何 agent。
    ///
    /// 注意：多 skill 仓库会把仓库里所有 SKILL.md 都装上（SkillOps 的既有行为）。
    /// 父 agent 正式接线时应注入自己的闭包，带上 AppState 里的 storeDir 与启用目标。
    static func defaultInstallAction(source: String) async -> Bool {
        let storeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills")
        let repo = source.hasPrefix("http") ? source : "https://github.com/\(source)"
        return await Task.detached(priority: .userInitiated) {
            (try? SkillOps.install(source: repo, storeDir: storeDir, enableTargets: [])) != nil
        }.value
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
                    Text("多 skill 仓库将整仓安装")
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
