# SkillHub

一站式管理多个 AI Agent 的 skills 目录的 macOS 原生应用。

现在各种 AI Agent（Claude Code、Codex、Cursor、Qoder、iFlow……）都在用户主目录下维护各自的 `skills` 目录，同一个 skill 装得到处都是、版本不一、断链满天飞。SkillHub 的思路是：**所有 skill 本体统一放在 `~/.agents/skills`（本体库），各平台目录里只放软链接**，然后用一个原生界面把所有 skill 管起来。

## 功能列表

### 统一管理

- **统一视图**：扫描所有平台的 skills 目录，把软链接解析到本体后按本体去重，一眼看到每个 skill 在哪些平台生效（真实目录 / 软链接 / 断链）。
- **场景（Preset）**：把一组 skill 命名为一个场景（如"前端开发"），一键激活 / 停用整组到目标平台；在侧栏「场景」区新建、重命名、删除，skill 详情里可「加入场景」。已启用 / 未启用的项自动跳过，本体目录绝不因停用而删除。
- **一键收编到本体库**：管家「同步」「清理」页顶部横幅，把散落在各平台目录里的真实本体批量迁移进本体库、原地补软链；遇到同名冲突时自动"链接化"（散落目录移入废纸篓可恢复，原地改建指向本体库已有版本的软链），散落的版本更新时则跳过并提示手动合并；软链登记到外部本体（如 iCloud 目录）的视为已收纳，不参与收编。
- **批量操作**：单个 skill 一键同步到所有平台；按平台批量启用 / 批量禁用。
- **冗余检测与清理建议**：同名 skill、标签高度重叠的相似 skill 分组提示；对体积过大、90 天以上未修改、本体不在本体库的 skill 给出清理 / 迁移建议。
- **自定义平台**：自动检测 Claude Code / Codex / Cursor / Cline / Windsurf 等已知平台目录，也可以手动添加任意 Agent 平台或额外扫描目录；平台按实际目录去重（同一目录不会出现 `auto_*` 重复项）。

### 发现与安装

- **技能市场**：工具栏「市场」接入 skills.sh 生态，浏览热门榜单、关键词搜索（与 `npx skills find` 同源 API，显示安装量，描述按需补取），一键安装——多 skill 仓库会整仓安装到本体库。
- **安装**：支持 Git 仓库 URL（含 `https://github.com/owner/repo/tree/branch/subdir` 子目录形式，浅克隆）、`仓库地址@tag`（或 commit SHA）指定版本安装，或本地目录；自动查找其中的所有 `SKILL.md`，拷入本体库并按勾选建软链。
- **技能清单（Manifest）**：工具栏「清单」菜单导出当前 skills 为 JSON 清单（含名称、安装来源、启用平台、标签），换机 / 团队共享时导入一键装回；导入前预览"将安装 X 个、补启用 Y 项、跳过 Z 个"，单个失败不中断整体流程。
- **Git skill 更新检测**：对本体位于 git 仓库内的 skill，fetch 后对比本地与远端 commit，提示更新并可一键 `git pull`。
- **项目工作区**：在管家「项目」页注册项目目录后扫描项目级 skills（`.claude/skills`、`.agents/skills` 等约定位置），支持与本体库双向复制同步（「收进本体库」/「从本体库导入 skill…」）；同名冲突不覆盖、报错提示。

### 健康与安全

- **体检 Doctor**：检测断链、缺少 frontmatter、缺 description、重名冲突、目录名与 name 不一致、SKILL.md 引用文件缺失、体积异常（>50MB）、孤儿本体（未被任何平台启用）、本体不在本体库等问题，支持单条修复或一键全部修复（删断链、补 frontmatter、重命名、迁移到本体库、启用到平台等）。
- **安全扫描**（体检第 9 项）：规则表驱动扫描 skill 目录下的脚本与文档，覆盖危险删除（`rm -rf` / `format`）、远程执行（`curl | bash` / `eval` / base64 解码执行）、凭据访问（`.ssh` / AWS 凭据 / 钥匙串）、网络外发（带知名域名白名单降噪）、权限提升（`sudo` / `chmod 777`）五大类；按严重度扣分给出 0–100 评分与「安全 / 注意 / 风险」三档等级，高危 / 中危命中转为体检问题。

### 效率工具

- **智能搜索与分类**：名称 / 描述 / 标签 / 作者多字段加权搜索 + 模糊匹配；按写作、编码、数据、沟通、创意等关键词自动分类；按作者分组（≥3 个 skill 的作者单独成组，长尾归并进「其他」组）。
- **收藏夹与最近使用**：收藏（持久化到 UserDefaults）；基于文件修改时间推断使用频率（活跃 / 闲置 / 休眠）。
- **AI 分析**：调用本机 `claude` CLI 批量分析 SKILL.md，自动生成 tags 和一句话 summary 并写回 frontmatter。
- **辅助操作**：复制调用提示词到剪贴板、复制 SKILL.md 全文、在 Finder 中显示、在 Terminal 拉起 agent CLI、命令面板（⌘K）。

## 界面概览

原生 macOS 三栏布局（`NavigationSplitView`）：

- **侧栏**：快速操作（收藏夹、最近使用）、场景（新建 / 重命名 / 删除）、分类、作者、Agent 平台（含"添加平台"）。
- **中间列表**：当前筛选下的 skill 列表（选中项高亮），支持工具栏搜索框搜索；选中场景时显示组内 skill 与「激活 / 停用」操作。
- **右侧详情**：选中的 skill 详情与各平台启用开关，含「加入场景」菜单。

工具栏按钮（中文标签）：**命令面板** / **市场** / **安装** / **刷新** / **清单**（导出 / 导入技能清单）/ **更新**（git 更新检测）/ **AI 分析** / **管家**。市场、体检、安装、AI 分析等以 Sheet 形式弹出；管家面板分「总览 / 来源 / 同步 / 清理」四页，「同步」「清理」页顶部有一键收编横幅。标签与胶囊采用流式换行布局，窗口再窄也不挤压。

## 系统要求

- macOS 14.0（Sonoma）或更高
- Swift 5.9+ / Xcode 15+（仅构建时需要）
- 系统自带 `git`（`/usr/bin/git`，用于安装与更新检测）
- 可选：`claude` CLI（`npm i -g @anthropic-ai/claude-code`），仅"AI 分析"功能需要
- 技能市场、清单导入安装、更新检测需要网络访问

无第三方 Swift 依赖。

## 构建与运行

```bash
# Debug 构建
swift build

# 直接运行（GUI 应用）
swift run

# Release 构建
swift build -c release
```

### 运行测试

```bash
swift test   # 130+ 单元测试，覆盖解析、扫描、安装、体检、市场、场景、清单、安全扫描、项目工作区等纯逻辑层
```

### 打包成 SkillHub.app

仓库自带打包脚本，把 release 产物组装成标准 macOS app bundle（含 Info.plist、可执行文件、SwiftPM 资源 bundle，并尽可能用 iconutil 从 `Assets.xcassets` 生成 AppIcon.icns）：

```bash
Scripts/make_app.sh
# 输出：.build/app/SkillHub.app
open .build/app/SkillHub.app
```

可选项：

```bash
SKIP_BUILD=1 Scripts/make_app.sh   # 跳过构建，直接用已有 release 产物
VERSION=1.0.0 Scripts/make_app.sh  # 指定 CFBundleShortVersionString
```

产物在 `.build/app/` 下，已被 `.gitignore` 忽略。如需分发，可自行对 .app 做 `codesign` 签名与公证，脚本不包含这一步。

### 一键安装 / 升级

打包、安装到「应用程序」并重启，一条命令搞定：

```bash
Scripts/install_app.sh              # 构建 + 打包 + 安装到 /Applications + 重启
VERSION=1.1.0 Scripts/install_app.sh
NO_LAUNCH=1 Scripts/install_app.sh  # 只安装不启动
```

## 目录结构

```
SkillHub/
├── Package.swift                  # SwiftPM 清单（swift-tools 5.9，macOS 14+）
├── Sources/SkillHub/
│   ├── App.swift                  # @main 入口、AppDelegate（Dock 图标、窗口策略）
│   ├── NewUI.swift                # 主界面：三栏布局、侧栏（含场景区）、列表、详情、命令面板
│   ├── Views.swift                # 安装 / 体检 / AI 分析 / 智能管家（含一键收编横幅）等 Sheet 视图
│   ├── MarketplaceView.swift      # 技能市场界面（热门 / 搜索 / 一键安装）
│   ├── MarketplaceService.swift   # skills.sh 搜索 API 与热门榜单解析（纯解析层可单测）
│   ├── AppState.swift             # 状态层：@Published 状态、操作封装、刷新流程
│   ├── Models.swift               # Skill / AgentTarget / 体检问题 / lock file 模型
│   ├── Preset.swift               # 场景（Preset）模型、持久化与激活 / 停用编排
│   ├── SkillManifest.swift        # 技能清单导出 / 导入（含 dry-run 预览计划）
│   ├── SecurityScanner.swift      # 安全扫描：表驱动规则、评分与等级
│   ├── ProjectWorkspace.swift     # 项目工作区：注册、扫描项目级 skills、双向复制同步
│   ├── SkillScanner.swift         # 扫描各平台目录，解析软链、按本体去重
│   ├── SkillOps.swift             # 启用（软链 / 副本）/ 禁用 / 删除 / 安装（含 @版本）/ 收编 / 体检修复
│   ├── SkillManager.swift         # 来源分组、覆盖率、使用频率、冗余、清理、搜索、分类、收藏、作者分组
│   ├── Doctor.swift               # 体检规则与问题生成（含安全扫描项）
│   ├── FrontmatterParser.swift    # 轻量 YAML frontmatter 解析器
│   ├── UpdateChecker.swift        # git skill 更新检测与 pull
│   ├── AIAnalysis.swift           # 调用 claude CLI 生成 tags / summary 并写回 frontmatter
│   └── Assets.xcassets/           # 应用图标资源
├── Tests/SkillHubTests/           # 单元测试（130+ 用例）
├── Scripts/
│   └── make_app.sh                # 打包 SkillHub.app
│   └── install_app.sh             # 一键安装/升级到 /Applications
├── docs/
│   └── competitive-analysis.md    # 竞品对比分析
├── CHANGELOG.md
└── README.md
```

## Skills 目录约定

```
~/.agents/skills/        # 本体库（canonical store）：所有 skill 的真实目录都放这里
~/.claude/skills/        # Claude Code：软链接
~/.codex/skills/         # Codex：软链接
~/.cursor/skills/        # Cursor：软链接
~/.qoder/skills/         # Qoder：软链接
~/.iflow/skills/         # iFlow：软链接
<project>/.claude/skills/ 等  # 项目级 skills（项目工作区扫描的约定位置）
```

- 一个目录被识别为 skill 的条件：包含 `SKILL.md`。
- "启用" = 在平台目录创建一个指向本体的**相对路径软链接**（与手工 `ln -s` 的习惯一致）；"禁用" = 只删除软链接，**绝不**通过禁用删除本体。也可在 skill 详情页「平台状态」区选择「以副本方式启用到…」（`LinkMode.copy`，副本内写入 `.skillhub-copy` 标记以区别于本体，副本可被禁用/移入废纸篓安全清理）。
- 推荐 `SKILL.md` 带 YAML frontmatter，SkillHub 会读取 `name`、`description`、`version`、`tags`、`summary`、`author`（含 `metadata.version` / `metadata.author`）字段。
- 安装来源记录在 `~/.agents/.skill-lock.json`（skill-lock 文件），用于按来源分组；安装源可写成 `仓库地址@tag` 固定版本（指定版本时做完整克隆后 checkout，不用浅克隆）。
- 技能清单导出为 JSON（`formatVersion: 1`），条目含 `name`、`source`、`enabledTargetIDs`、`tags`；无来源可追溯的本地 skill 导入时会跳过安装并说明原因。
- 收藏、场景、自定义平台、自定义扫描目录、项目工作区等偏好存在 UserDefaults（`@AppStorage` / JSON 编码）。

## 免责声明

- 本应用会**直接读写**你主目录下的 `~/.agents/skills`、`~/.claude/skills`、`~/.codex/skills`、`~/.cursor/skills`、`~/.qoder/skills`、`~/.iflow/skills` 以及你自行添加的目录。请确认你了解每个操作的含义。
- "删除 skill"会把本体移入**废纸篓**，可以从废纸篓恢复；"一键收编"遇到同名冲突时也会把散落目录移入废纸篓（可恢复）。但"删除断链"、"移除引用"、"补 frontmatter"、"重命名目录"、"AI 分析写回 frontmatter"等操作是**原地修改且不可撤销**，重要数据请先自行备份。
- "更新"功能会在 skill 所在 git 仓库执行 `git fetch` / `git pull`；如果你的 skill 仓库有本地未提交改动，请先自行处理。
- 技能市场、清单导入、@ 版本安装会从网络下载并安装第三方 skills，请自行审查来源；安装前可先用"体检 → 安全扫描"排查。**安全扫描是启发式规则匹配，可能有误报和漏报，不构成安全保证。**
- "AI 分析"会把你的 SKILL.md 内容（截取前 8000 字符）发送给本机 `claude` CLI，请确保你接受其数据去向。
- 本应用按"现状"提供，作者不对数据丢失负责。
