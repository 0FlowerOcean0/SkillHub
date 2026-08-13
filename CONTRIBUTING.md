# 参与贡献

感谢你帮助改进 SkillHub。提交改动前，请先确认没有覆盖他人的未提交工作，并保持改动范围聚焦。

## 本地验证

项目需要 macOS 14、Swift 5.9 或 Xcode 15 及以上版本。

```bash
swift test
swift build -c release
UNIVERSAL=1 Scripts/make_app.sh
codesign --verify --deep --strict .build/app/SkillHub.app
```

涉及界面的改动还应实际启动应用，验证窄窗口、空数据、错误状态和危险操作确认流程。

## Pull Request

- 一个 PR 只解决一个清晰的问题。
- 新行为需要测试；缺陷修复需要能复现缺陷的回归测试。
- 不要提交真实 skill 内容、个人目录、令牌、证书、`.build` 或本地编辑器配置。
- 涉及文件写入、软链接、Git 下载或废纸篓的改动，应说明失败回滚和数据安全边界。
