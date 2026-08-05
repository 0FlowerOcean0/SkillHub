# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- 统一视图：扫描本体库（`~/.agents/skills`）与各 Agent 平台（Qoder / Claude Code / Codex / Cursor / iFlow 等）的 skills 目录，按本体去重并展示每个 skill 在各平台的存在形式（真实目录 / 软链接 / 断链）。
- 体检 Doctor：检测断链、缺少 frontmatter、缺 description、重名冲突、目录名与 name 不一致、引用文件缺失、体积异常、孤儿本体、本体不在本体库，支持单条修复与一键全部修复。
- 安装：支持 Git 仓库 URL（含 tree 子目录形式）与本地目录，自动发现 SKILL.md 并安装到本体库、按勾选建软链。
- 批量操作：单 skill 同步到所有平台；按平台批量启用 / 禁用。
- 智能搜索：名称 / 描述 / 标签 / 作者加权匹配 + 模糊匹配；关键词自动分类；按作者分组。
- 收藏夹与最近使用：收藏持久化；基于文件修改时间推断使用频率（活跃 / 闲置 / 休眠）。
- 冗余检测与清理建议：同名与标签重叠分组；体积过大、长期未修改、本体不在本体库的清理建议。
- Git skill 更新检测：fetch 对比远端 commit，提示并可一键 pull 更新。
- AI 分析：调用本机 claude CLI 生成 tags 与 summary 并写回 SKILL.md frontmatter。
- 自定义 Agent 平台与自定义扫描目录；自动检测 Claude Code / Codex / Cursor / Cline / Windsurf。
- 工程化：`Scripts/make_app.sh` 一键打包 SkillHub.app（Info.plist + 资源 bundle + 可选 icns）；`.gitignore`；README。
