# SkillHub 竞品对比分析

> 调研时间：2026-08-05　数据来源：各产品 GitHub README、官方文档及公开介绍（见文末）

## 一、同类型开源产品图谱

Agent Skills 生态（SKILL.md 开放标准）在 2026 年爆发，管理工具分四类：

| 类别 | 代表产品 | 形态 |
|---|---|---|
| **GUI 桌面管理器**（直接竞品） | Skills Manager（xingkongliang）、Skills Manager Client（buzhangsan） | Tauri 2 + React，跨 Win/Mac/Linux |
| **CLI 包管理器** | skills CLI（Vercel/skills.sh 官方）、skills-cli（Rust 实现）、skillfish、agent-skills-hub、ClawdHub | npm/pip/curl 安装 |
| **官方工具** | `gh skill`（GitHub CLI v2.90+） | GitHub 官方子命令 |
| **企业级注册表** | ToolHive（OCI registry）、ClawdHub registry | 服务端 + CLI |

## 二、与最接近竞品的特性对比

对标 **Skills Manager**（功能最全的直接竞品，Tauri 桌面应用）：

| 特性 | Skills Manager | SkillHub 现状 |
|---|---|---|
| 中央技能库 + 软链接同步 | ✅ 中央库 + symlink/copy 两种模式 | ✅ 本体库 + 相对软链（操作层已支持 copy 副本模式，2026-08-05） |
| 多平台支持 | ✅ 15+ agent | ✅ 内置 6 + 自定义 + 自动检测 |
| 场景/预设（Preset） | ✅ **按场景成组，一键激活/停用整组** | ✅ 已实现（2026-08-05，侧栏场景管理 + 一键激活/停用） |
| 项目级 skills 管理 | ✅ 项目工作区，双向同步 | ✅ 已实现（2026-08-05，管家「项目」页，双向复制同步） |
| Git 备份/多机同步 | ✅ 自动 pull/commit/push + 快照标签回滚 | ❌ 无 |
| 技能市场浏览 | ✅ 内置 skills.sh 市场 + AI 语义搜索 | ✅ 已实现（2026-08-05，接入 skills.sh 热门/搜索/一键安装） |
| 体检/健康检查 | ⚠️ 基础 | ✅ **Doctor 九项检查 + 一键修复**（GUI 独有） |
| 安全扫描 | ❌（Skills Manager Client 有） | ✅ 已实现（2026-08-05，体检第 9 项，0-100 评分） |
| 使用频率/冗余/清理建议 | ❌ | ✅ **智能管家**（独有） |
| AI 分析标注 | ❌ | ✅ 调用 claude CLI（独有） |
| 原生体验 | Tauri Web 套壳 | ✅ **macOS 原生 SwiftUI**（独有） |
| 更新检测 | ✅ git 上游检测 | ✅ 已有 |
| 锁文件 | ✅ skills-lock.json（含 tree SHA） | ⚠️ 有 .skill-lock.json，精度待核 |
| 跨平台 OS | ✅ Win/Mac/Linux | ❌ 仅 macOS |

## 三、结论：人无我有 / 人有我优

### 人无我有（应强化为卖点，写入 README）
1. **Doctor 体检 + 一键修复**：断链、frontmatter 缺失、重名、引用缺失、体积异常、安全扫描等九项检查——GUI 竞品里没有等价物（仅 Rust 版 skills-cli 有 `skills doctor` 命令，但无修复能力）
2. **智能管家**：使用频率推断、冗余检测、清理建议——所有竞品均无
3. **AI 分析**：用 LLM 给 skill 打标签/写摘要——所有竞品均无
4. **macOS 原生**：Tauri 应用内存占用和体验无法相比

### 人有我无（按价值排序的改进建议）

| 优先级 | 特性 | 来源 | 落地思路 |
|---|---|---|---|
| ⭐⭐⭐ | **场景/预设（Presets）** ✅ 已实现（2026-08-05） | Skills Manager | 命名一组 skill，一键将整组启用/停用到指定平台。与现有"收藏夹"机制互补，复用 batchEnable/batchDisable |
| ⭐⭐⭐ | **技能市场浏览** ✅ 已实现（2026-08-05） | Skills Manager / skillfish | 内置 skills.sh 目录浏览与搜索，一键安装。安装管线已具备，只差发现层 |
| ⭐⭐ | **Manifest 导出/导入** ✅ 已实现（2026-08-05） | skillfish bundle | 把当前 skills 清单导出为 JSON，换机/团队共享时一键装回。与 lock 文件天然契合 |
| ⭐⭐ | **安全扫描** ✅ 已实现（2026-08-05） | Skills Manager Client | 扩展 Doctor：扫描危险 shell 模式、网络请求、凭据读取，给安全评分 |
| ⭐⭐ | **项目级 skills** ✅ 已实现（2026-08-05，基础模块） | Skills Manager 项目工作区 | 扫描 `<project>/.claude/skills` 等，支持项目级启用 |
| ⭐ | **Git 备份/多机同步** | Skills Manager | 本体库本身就是目录，可一键 git init + 推送到私有仓库 |
| ⭐ | **copy 同步模式** ✅ 已实现（2026-08-05，操作层） | Skills Manager / skills CLI `--copy` | SkillOps.enable 增加复制选项，适配不支持软链的场景 |
| ⭐ | **版本固定安装 @tag/@SHA** ✅ 已实现（2026-08-05） | gh skill | install 支持 `repo@tag` 语法 |
| 观望 | 跨平台（Win/Linux） | 所有 Tauri 竞品 | 战略取舍；若做，Swift 跨平台成本高，不建议近期投入 |

### 人有我优（已有功能的差异化打磨）
- **更新检测**：skills.sh 用 tree SHA 精确比对，SkillHub 目前基于 git remote——可对齐 SHA 精度
- **作者/分类分组长尾归并**（已实现）：竞品的列表均无此智能归并

## 四、数据来源
- Skills Manager：GitHub `xingkongliang/skills-manager`，腾讯云/博客园体验文（2026-05）
- Skills Manager Client：GitHub `buzhangsan/skills-manager-client`，vibesparking 介绍（2026-01）
- skills CLI / skills.sh：Vercel 官方 registry，itecsonline 安装指南（2026-07）
- skills-cli（Rust）：lib.rs/crates/skills-cli（含 `skills doctor`、`--dry-run`）
- skillfish：GitHub `knoxgraeme/skillfish`（bundle manifest 团队同步）
- agent-skills-hub：GitHub `youzaiAGI/agent-skills-hub`（中央仓库 + skill sync，18+ agent）
- gh skill：GitHub Changelog（2026-04-16）
- ToolHive：docs.stacklok.com（OCI registry、生命周期管理）
