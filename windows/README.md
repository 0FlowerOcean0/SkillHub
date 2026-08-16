# SkillHub for Windows

SkillHub Windows 是与现有 macOS 客户端并行维护的原生桌面版本，使用 Tauri 2、React 和 Rust 构建。

当前预览版专注于一条最重要的闭环：**看清 Skills，安全地启用或停用它们。**

## 当前能力

- 扫描 `~/.agents/skills`、Claude Code、Codex、Cursor、Cline、Windsurf、Roo Code 与 Continue。
- 按真实本体路径去重，识别真实目录、Junction 和断链。
- 搜索名称、描述、标签与作者，查看 `SKILL.md` 只读预览。
- 通过 NTFS Junction 启用和停用 Skill；停用只删除 Junction，不删除本体。
- 遇到平台内同名真实目录时拒绝覆盖，避免误删用户数据。
- 在资源管理器中打开本体库或具体 Skill。

市场、Doctor、Preset、Manifest 和项目工作区仍由功能更完整的 macOS 版提供；Windows 端会在核心闭环稳定后逐步跟进。

## 本地开发

需要 Windows 10/11、WebView2、Node.js 22、pnpm 11 和 Rust stable。按照 [Tauri Windows 前置要求](https://v2.tauri.app/start/prerequisites/) 安装 Microsoft C++ Build Tools。

```powershell
cd windows
pnpm install --frozen-lockfile
pnpm tauri dev
```

只检查前端：

```powershell
pnpm build
```

运行 Rust 测试并生成 NSIS 安装包：

```powershell
cargo test --manifest-path src-tauri/Cargo.toml
pnpm tauri build --bundles nsis
```

安装包输出在 `windows/src-tauri/target/release/bundle/nsis/`。

## 数据与安全边界

Windows 版把 `C:\Users\<你>\.agents\skills` 作为唯一真实本体库。平台目录中的启用项使用 NTFS Junction 指向本体，因此更新一次即可同步到多个 Agent。

- 启用前会确认本体目录存在 `SKILL.md`。
- 已指向同一本体的 Junction 会直接跳过。
- 同名 Junction 可安全重建；同名真实目录绝不覆盖。
- 停用只移除由目录链接表达的启用项，不触碰本体库。

GitHub Actions 会在真实 `windows-latest` 环境中执行前端构建、Rust 测试和 NSIS 打包，并上传 `.exe` 产物。

