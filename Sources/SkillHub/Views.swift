import SwiftUI

// MARK: - 仪表盘（未选中 skill 时）

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let s = state.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 标题
                HStack(alignment: .firstTextBaseline) {
                    Text("Skills 总览")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(s.total) 个 skill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // 统计卡片
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    StatCard(title: "总数", value: "\(s.total)", icon: "square.grid.2x2", tint: .blue)
                    StatCard(title: "占用空间", value: ByteCountFormatter.string(fromByteCount: s.totalSize, countStyle: .file), icon: "internaldrive", tint: .purple)
                    StatCard(title: "孤儿", value: "\(s.orphan)", icon: "link.badge.plus", tint: .orange, subtitle: "未启用")
                    StatCard(title: "错误", value: "\(s.errors)", icon: "xmark.octagon", tint: .red)
                    StatCard(title: "警告", value: "\(s.warnings)", icon: "exclamationmark.triangle", tint: .yellow)
                    StatCard(title: "AI 已分析", value: "\(s.analyzed)", icon: "brain", tint: .purple)
                    StatCard(title: "可更新", value: "\(s.updatable)", icon: "arrow.triangle.2.circlepath", tint: .green)
                }

                // Agent 覆盖
                VStack(alignment: .leading, spacing: 12) {
                    dashboardSectionHeader("各 Agent 覆盖情况", icon: "square.stack.3d.up")

                    VStack(spacing: 10) {
                        ForEach(state.targets.filter(\.exists)) { t in
                            let count = state.skills.filter { $0.presence[t.id] != nil }.count
                            let pct = s.total == 0 ? 0.0 : CGFloat(count) / CGFloat(max(s.total, 1))
                            HStack(spacing: 12) {
                                HStack(spacing: 6) {
                                    Image(systemName: iconForAgent(t.id))
                                        .foregroundStyle(Color.secondary)
                                        .frame(width: 16)
                                    Text(t.displayName)
                                        .font(.callout)
                                        .frame(width: 100, alignment: .leading)
                                }

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.secondary.opacity(0.06))
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [agentColor(t.id).opacity(0.5), agentColor(t.id).opacity(0.8)],
                                                    startPoint: .leading, endPoint: .trailing
                                                )
                                            )
                                            .frame(width: max(0, pct * geo.size.width))
                                    }
                                }
                                .frame(height: 8)

                                Text("\(Int(pct * 100))%")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(pct > 0.7 ? .green : pct > 0.3 ? .orange : .secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Top 10
                VStack(alignment: .leading, spacing: 12) {
                    dashboardSectionHeader("体积 Top 10", icon: "chart.bar.horizontal")

                    VStack(spacing: 0) {
                        let sorted = state.skills.sorted { $0.sizeBytes > $1.sizeBytes }
                        let maxSize = sorted.first?.sizeBytes ?? 1
                        ForEach(Array(sorted.prefix(10).enumerated()), id: \.element.id) { idx, skill in
                            Top10Row(rank: idx + 1, skill: skill, maxSize: maxSize)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        state.selectedSkillID = skill.id
                                    }
                                }
                            if idx < 9 {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // 底部提示
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("从左侧选择 agent 过滤，从中间列表选择 skill 查看详情。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func iconForAgent(_ id: String) -> String {
        switch id {
        case "agents": return "shippingbox"
        case "qoder": return "q.circle"
        case "claude": return "c.circle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "cursor": return "cursorarrow"
        case "iflow": return "arrow.triangle.branch"
        default: return "folder"
        }
    }

    private func agentColor(_ id: String) -> Color {
        switch id {
        case "qoder": return .blue
        case "claude": return .purple
        case "codex": return .orange
        case "cursor": return .cyan
        case "iflow": return .green
        case "agents": return .accentColor
        default: return .gray
        }
    }

    private func dashboardSectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor.opacity(0.7))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    var subtitle: String? = nil
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            isHovering ? tint.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.4),
                            isHovering ? tint.opacity(0.04) : Color(nsColor: .controlBackgroundColor).opacity(0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    tint.opacity(isHovering ? 0.4 : 0.15),
                                    tint.opacity(isHovering ? 0.2 : 0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: tint.opacity(isHovering ? 0.1 : 0), radius: isHovering ? 8 : 0, x: 0, y: 2)
        )
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovering = h } }
    }
}

struct Top10Row: View {
    let rank: Int
    let skill: Skill
    let maxSize: Int64
    @State private var isHovering = false

    private var sizePct: CGFloat {
        guard maxSize > 0 else { return 0 }
        return CGFloat(skill.sizeBytes) / CGFloat(maxSize)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(rank <= 3 ? Color.accentColor : Color.secondary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 13, weight: rank <= 3 ? .semibold : .regular))
                        .lineLimit(1)
                    if let firstTag = skill.tags.first {
                        Text(firstTag)
                            .font(.system(size: 9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.1))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.06))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.7)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, sizePct * geo.size.width))
                    }
                }
                .frame(height: 4)
            }
            Text(skill.sizeDisplay)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isHovering ? Color.accentColor.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovering = h } }
    }
}

// MARK: - 安装面板

struct InstallSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var selectedTargets: Set<String> = ["qoder"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("安装 Skill").font(.title2.bold())
            Text("支持：GitHub 仓库 / tree 子目录 URL，或本地目录路径。整仓多个 skills 会全部安装。")
                .font(.caption).foregroundStyle(.secondary)

            TextField("https://github.com/owner/repo 或 ~/path/to/skill", text: $source)
                .textFieldStyle(.roundedBorder)
            Text("支持 `仓库地址@tag` 指定版本，如 https://github.com/owner/repo@v1.0")
                .font(.caption).foregroundStyle(.secondary)

            Text("安装到本体库 \(state.storeDir.path)，并软链到：").font(.callout)
            HStack {
                ForEach(state.targets.filter { $0.id != AgentTarget.canonicalID }) { t in
                    Toggle(t.displayName, isOn: Binding(
                        get: { selectedTargets.contains(t.id) },
                        set: { on in
                            if on { selectedTargets.insert(t.id) } else { selectedTargets.remove(t.id) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("安装") {
                    let enable = state.targets.filter { selectedTargets.contains($0.id) }
                    state.install(source: source, enableIn: enable) { ok in
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || state.isBusy)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - 体检面板

struct DoctorSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmFixAll = false
    @State private var confirmDestructive: DoctorIssue? = nil

    private var fixableCount: Int { state.issues.filter { $0.fixAction != .none }.count }
    private var destructiveCount: Int { state.issues.filter { $0.fixAction.isDestructive }.count }

    var body: some View {
        VStack(spacing: 0) {
            // 固定标题栏
            HStack {
                Text("体检报告").font(.title2.bold())
                Spacer()
                if fixableCount > 0 {
                    Button {
                        if destructiveCount > 0 {
                            confirmFixAll = true
                        } else {
                            state.fixAllIssues()
                        }
                    } label: {
                        Label("一键修复 \(fixableCount) 个", systemImage: "wand.and.stars")
                    }
                    .controlSize(.small)
                }
                Button("重新体检") { state.refresh() }
                Button("关闭") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // 内容
            if state.issues.isEmpty {
                ContentUnavailableView("一切正常", systemImage: "checkmark.seal.fill", description: Text("没有发现断链、格式或引用问题。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.issues) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: issue.severity.symbol)
                            .foregroundStyle(color(issue.severity))
                            .font(.system(size: 14))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.title).font(.callout.bold())
                            Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if !issue.hintActions.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(issue.hintActions) { hint in
                                        Button {
                                            switch hint {
                                            case .revealInFinder(let url):
                                                SkillOps.revealInFinder(url)
                                            case .copyPath(let path):
                                                let pb = NSPasteboard.general
                                                pb.clearContents()
                                                pb.setString(path, forType: .string)
                                            }
                                        } label: {
                                            Label(hint.label, systemImage: hint.icon)
                                        }
                                        .controlSize(.small)
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                        Spacer()
                        if issue.fixAction != .none {
                            Button(issue.fixAction.label) {
                                if issue.fixAction.isDestructive {
                                    confirmDestructive = issue
                                } else {
                                    state.fixIssue(issue)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(width: 640, height: 480)
        .confirmationDialog("确定修复所有问题？", isPresented: $confirmFixAll) {
            Button("修复全部", role: .destructive) { state.fixAllIssues() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包含 \(destructiveCount) 个不可逆操作（删除断链、移除引用）。")
        }
        .confirmationDialog(
            confirmDestructive.map { "确定\($0.fixAction.label)？" } ?? "",
            isPresented: Binding(
                get: { confirmDestructive != nil },
                set: { if !$0 { confirmDestructive = nil } }
            )
        ) {
            Button("确认", role: .destructive) {
                if let issue = confirmDestructive {
                    state.fixIssue(issue)
                    confirmDestructive = nil
                }
            }
            Button("取消", role: .cancel) { confirmDestructive = nil }
        } message: {
            Text("此操作不可撤销。")
        }
    }

    private func color(_ s: IssueSeverity) -> Color {
        switch s {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}

// MARK: - AI 分析面板

struct AIAnalysisSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 固定标题栏
            HStack {
                Text("AI 分析").font(.title2.bold())
                Spacer()
                if let err = state.aiError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                if !state.aiAnalyzing {
                    Button("完成") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("关闭") { dismiss() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // 可滚动内容
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 进度
                    if state.aiAnalyzing {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "brain")
                                    .foregroundStyle(.purple)
                                Text("正在分析 \(state.aiCurrentSkillName)…")
                                    .font(.callout)
                            }
                            ProgressView(value: Double(state.aiProgressDone), total: Double(max(state.aiProgressTotal, 1)))
                                .tint(.purple)
                            HStack {
                                Text("\(state.aiProgressDone) / \(state.aiProgressTotal)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer()
                                let pct = state.aiProgressTotal > 0 ? Int(Double(state.aiProgressDone) / Double(state.aiProgressTotal) * 100) : 0
                                Text("\(pct)%")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.purple.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // 统计
                    let analyzed = state.skills.filter(\.hasAnalysis).count
                    HStack(spacing: 16) {
                        StatCard(title: "已分析", value: "\(analyzed)", icon: "brain", tint: .purple)
                        StatCard(title: "未分析", value: "\(state.skills.count - analyzed)", icon: "questionmark.circle", tint: .gray)
                        StatCard(title: "总 Skill", value: "\(state.skills.count)", icon: "square.grid.2x2", tint: .blue)
                    }

                    // 标签分布
                    let allTags = Dictionary(grouping: state.skills.filter(\.hasAnalysis).flatMap(\.tags), by: { $0 })
                    if !allTags.isEmpty {
                        GroupBox("标签分布") {
                            let sorted = allTags.sorted { $0.value.count > $1.value.count }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                                ForEach(sorted, id: \.key) { tag, skills in
                                    HStack {
                                        Text(tag).font(.caption)
                                        Spacer()
                                        Text("\(skills.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            .padding(6)
                        }
                    }

                    // 操作
                    GroupBox("操作") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Button {
                                    state.runAIAnalysis(mode: .all)
                                } label: {
                                    Label("分析全部", systemImage: "brain")
                                }
                                .disabled(state.aiAnalyzing)

                                Button {
                                    state.runAIAnalysis(mode: .unanalyzed)
                                } label: {
                                    Label("分析未分类", systemImage: "brain.head.profile")
                                }
                                .disabled(state.aiAnalyzing)

                                if let skill = state.selectedSkill {
                                    Button {
                                        state.runAIAnalysis(mode: .single(skill))
                                    } label: {
                                        Label("分析 \(skill.name)", systemImage: "wand.and.stars")
                                    }
                                    .disabled(state.aiAnalyzing)
                                }
                            }

                            if AIAnalysis.findCLI() == nil {
                                Label("未找到 claude CLI，请先安装", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                        .padding(6)
                    }

                    // 已分析列表
                    let analyzedSkills = state.skills.filter(\.hasAnalysis).sorted { $0.name < $1.name }
                    if !analyzedSkills.isEmpty {
                        GroupBox("已分析结果") {
                            VStack(spacing: 0) {
                                ForEach(analyzedSkills) { skill in
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(skill.name).font(.callout.bold())
                                            if !skill.summary.isEmpty {
                                                Text(skill.summary).font(.caption).foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        HStack(spacing: 4) {
                                            ForEach(skill.tags.prefix(3), id: \.self) { tag in
                                                Text(tag).font(.system(size: 10))
                                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Color.purple.opacity(0.1))
                                                    .foregroundStyle(.purple)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    Divider().opacity(0.5)
                                }
                            }
                            .padding(4)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: - 智能管家面板

struct ManagerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: ManagerTab = .overview

    enum ManagerTab: String, CaseIterable {
        case overview = "总览"
        case sources = "来源"
        case sync = "同步"
        case cleanup = "清理"
        case projects = "项目"
    }

    /// 「项目」tab 里当前选中查看的项目
    @State private var selectedProjectID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("智能管家").font(.title2.bold())
                Spacer()
                Button("刷新") { state.refresh() }
                Button("关闭") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Tab 选择器
            Picker("", selection: $selectedTab) {
                ForEach(ManagerTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Divider()

            // 内容
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .overview:
                        overviewContent
                    case .sources:
                        sourcesContent
                    case .sync:
                        syncContent
                    case .cleanup:
                        cleanupContent
                    case .projects:
                        projectsContent
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 700, height: 560)
    }

    // MARK: - 总览

    private var overviewContent: some View {
        let skillCount = state.skills.count
        let sourceCount = state.sourceGroups.count
        let activeCount = state.usageInfo.filter { $0.category == .active }.count
        let idleCount = state.usageInfo.filter { $0.category == .idle }.count
        let dormantCount = state.usageInfo.filter { $0.category == .dormant }.count
        let redundancyCount = state.redundancyGroups.count
        let coverageList = state.platformCoverage

        return VStack(alignment: .leading, spacing: 16) {
            // 快速统计
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                StatCard(title: "总数", value: "\(skillCount)", icon: "square.grid.2x2", tint: .blue)
                StatCard(title: "来源仓库", value: "\(sourceCount)", icon: "shippingbox", tint: .purple)
                StatCard(title: "活跃", value: "\(activeCount)", icon: "bolt.fill", tint: .green)
                StatCard(title: "闲置", value: "\(idleCount)", icon: "clock", tint: .orange)
                StatCard(title: "休眠", value: "\(dormantCount)", icon: "moon.zzz", tint: .red)
                StatCard(title: "冗余", value: "\(redundancyCount)", icon: "arrow.triangle.2.circlepath", tint: .yellow)
            }

            // 平台覆盖率
            VStack(alignment: .leading, spacing: 10) {
                Text("平台覆盖率").font(.system(size: 13, weight: .semibold))
                ForEach(coverageList) { coverage in
                    HStack(spacing: 12) {
                        Text(coverage.agentName)
                            .font(.callout)
                            .frame(width: 100, alignment: .leading)
                        ProgressView(value: coverage.percentage)
                            .frame(height: 6)
                        Text("\(coverage.enabled)/\(coverage.total)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                        Button("同步缺失") {
                            // 批量启用到该平台，只刷新一次（原来逐个 syncToAll 会触发 N 次全量扫描，
                            // 且静默只处理前 10 个）
                            if let target = state.targets.first(where: { $0.id == coverage.agentId }) {
                                state.batchEnable(skills: coverage.missing, to: target)
                            }
                        }
                        .controlSize(.small)
                        .disabled(coverage.missing.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - 来源分组

    private var sourcesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            let groups = state.sourceGroups
            ForEach(groups) { group in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                if let url = group.sourceUrl {
                                    Text(url)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text("\(group.skills.count) 个 skills")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let date = group.installedAt {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        // Skills 列表
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(group.skills.prefix(8)) { skill in
                                    Text(skill.name)
                                        .font(.system(size: 11))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.08))
                                        .clipShape(Capsule())
                                }
                                if group.skills.count > 8 {
                                    Text("+\(group.skills.count - 8)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // 批量操作
                        HStack(spacing: 8) {
                            Button("全部启用到 Claude") {
                                if let target = groups.first(where: { $0.id == group.id }),
                                   let claude = state.targets.first(where: { $0.id == "claude" }) {
                                    state.batchEnable(skills: target.skills, to: claude)
                                }
                            }
                            .controlSize(.small)
                            Button("全部启用到 Qoder") {
                                if let target = groups.first(where: { $0.id == group.id }),
                                   let qoder = state.targets.first(where: { $0.id == "qoder" }) {
                                    state.batchEnable(skills: target.skills, to: qoder)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - 同步

    /// 一键收编横幅：散落各平台目录、本体不在本体库的 skills（同步/清理页共用）
    @ViewBuilder
    private var migrateAllBanner: some View {
        let strays = state.straySkills
        if !strays.isEmpty {
            GroupBox {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(strays.count) 个 skills 不在本体库")
                            .font(.callout.bold())
                        Text("收编后统一存放于本体库，原平台目录保留软链，不影响使用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("一键收编到本体库") { state.migrateAllToStore() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(state.isBusy)
                }
                .padding(4)
            }
        }
    }

    private var syncContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("跨平台同步").font(.system(size: 13, weight: .semibold))

            migrateAllBanner

            let coverageList = state.platformCoverage
            ForEach(coverageList) { coverage in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(coverage.agentName)
                                .font(.callout.bold())
                            Spacer()
                            Text("\(coverage.enabled)/\(coverage.total) 已启用")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        if !coverage.missing.isEmpty {
                            Text("缺失 \(coverage.missing.count) 个：")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(coverage.missing.prefix(10)) { skill in
                                        Text(skill.name)
                                            .font(.system(size: 10))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                    if coverage.missing.count > 10 {
                                        Text("+\(coverage.missing.count - 10)")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Button {
                                // 批量启用到该平台，只刷新一次
                                if let target = state.targets.first(where: { $0.id == coverage.agentId }) {
                                    state.batchEnable(skills: coverage.missing, to: target)
                                }
                            } label: {
                                Label("一键同步全部缺失", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        } else {
                            Label("已全覆盖", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - 清理


    private var cleanupContent: some View {
        let suggestions = state.cleanupSuggestions
        let redundancyGroups = state.redundancyGroups
        let issues = state.issues

        return VStack(alignment: .leading, spacing: 12) {
            migrateAllBanner

            if suggestions.isEmpty {
                ContentUnavailableView("无需清理", systemImage: "checkmark.seal.fill", description: Text("所有 skills 状态良好"))
            } else {
                Text("清理建议").font(.system(size: 13, weight: .semibold))

                ForEach(suggestions) { suggestion in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.skill.name).font(.callout.bold())
                            Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch suggestion.action {
                        case .delete:
                            Button("删除") { state.trash(skill: suggestion.skill) }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .tint(.red)
                        case .disable(let agentId):
                            Button("禁用") {
                                if let target = state.targets.first(where: { $0.id == agentId }) {
                                    state.batchDisable(skills: [suggestion.skill], from: target)
                                }
                            }
                            .controlSize(.small)
                        case .migrate:
                            Button("迁移") {
                                if let issue = issues.first(where: { $0.skillName == suggestion.skill.name }) {
                                    state.fixIssue(issue)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }

            // 冗余检测
            if !redundancyGroups.isEmpty {
                Text("冗余检测").font(.system(size: 13, weight: .semibold))
                ForEach(redundancyGroups) { group in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.reason).font(.callout.bold())
                            Text(group.suggestion).font(.caption).foregroundStyle(.secondary)
                            WrappingHStack(spacing: 4, lineSpacing: 4) {
                                ForEach(group.skills) { skill in
                                    Text(skill.name)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.1))
                                        .clipShape(Capsule())
                                        .fixedSize()
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
        }
    }
    // MARK: - 项目工作区

    private var projectsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目工作区").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    chooseProjectDirectory()
                } label: {
                    Label("添加项目…", systemImage: "plus")
                }
                .controlSize(.small)
            }
            Text("注册含有 .claude/skills 等约定目录的项目，在项目与本体库之间双向同步 skills。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.projectWorkspaces.isEmpty {
                ContentUnavailableView(
                    "还没有注册项目",
                    systemImage: "folder.badge.plus",
                    description: Text("点击「添加项目…」选择项目目录，SkillHub 会扫描项目里的项目级 skills，可以把它们收进本体库，或把本体库的 skills 导入项目")
                )
            } else {
                ForEach(state.projectWorkspaces) { ws in
                    projectRow(ws)
                }

                if let selected = state.projectWorkspaces.first(where: { $0.id == selectedProjectID }) {
                    Divider()
                    projectDetail(selected)
                } else {
                    Text("点击上方项目查看扫描结果")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func projectRow(_ ws: ProjectWorkspace) -> some View {
        let isSelected = selectedProjectID == ws.id
        return HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name)
                    .font(.callout.bold())
                Text(ws.path.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let entries = state.projectScanResults[ws.id] {
                Text("\(entries.count) 个 skills")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                state.removeProject(id: ws.id)
                if selectedProjectID == ws.id { selectedProjectID = nil }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("移除项目（只取消注册，不删除文件）")
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedProjectID = ws.id
            if state.projectScanResults[ws.id] == nil {
                state.scanProject(ws)
            }
        }
    }

    private func projectDetail(_ ws: ProjectWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("「\(ws.name)」里的 skills")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if state.scanningProjectID == ws.id {
                    ProgressView()
                        .controlSize(.small)
                }
                // 从本体库导入 skill 到项目（默认 .claude/skills）
                Menu {
                    if state.skills.isEmpty {
                        Text("本体库还没有 skills")
                    } else {
                        ForEach(state.skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { skill in
                            Button(skill.name) {
                                state.exportSkillToProject(skill, to: ws)
                            }
                        }
                    }
                } label: {
                    Label("从本体库导入 skill…", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .disabled(state.skills.isEmpty)

                Button {
                    state.scanProject(ws)
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state.scanningProjectID != nil)
            }

            let entries = state.projectScanResults[ws.id] ?? []
            if state.scanningProjectID == ws.id && entries.isEmpty {
                Text("正在扫描…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entries.isEmpty {
                Text("项目里没有发现 skills（查找 .claude/skills、.agents/skills 等约定目录）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.skillName)
                                .font(.callout.bold())
                            HStack(spacing: 8) {
                                Text(entry.source)
                                    .font(.system(size: 10, design: .monospaced))
                                Text("\(entry.fileCount) 个文件")
                                Text(entry.sizeDisplay)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if !entry.descriptionText.isEmpty {
                                Text(entry.descriptionText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Button {
                            state.importProjectSkill(entry, from: ws)
                        } label: {
                            Label("收进本体库", systemImage: "tray.and.arrow.down")
                        }
                        .controlSize(.small)
                        .disabled(state.isBusy)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加项目"
        panel.message = "选择含有 skills 目录的项目根目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.addProject(path: url)
        if let added = state.projectWorkspaces.first(where: { $0.normalizedPath == ProjectWorkspace.normalize(url) }) {
            selectedProjectID = added.id
        }
    }
}

// MARK: - 自动换行横向布局

/// 子视图按自然宽度排列，放不下就整体换行，
/// 避免胶囊在 HStack 里被挤压到竖向断词
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var size = CGSize.zero
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let sub = subview.sizeThatFits(.unspecified)
            if lineWidth > 0 && lineWidth + spacing + sub.width > maxWidth {
                size.width = max(size.width, lineWidth)
                size.height += lineHeight + lineSpacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth == 0 ? 0 : spacing) + sub.width
            lineHeight = max(lineHeight, sub.height)
        }
        size.width = max(size.width, lineWidth)
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let sub = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sub.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: sub.width, height: sub.height))
            x += sub.width + spacing
            lineHeight = max(lineHeight, sub.height)
        }
    }
}
