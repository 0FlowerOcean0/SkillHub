import XCTest
@testable import SkillHub

/// 技能清单（Manifest）导出/导入测试。
/// 文件系统用例复用 SkillScannerTests.swift 里定义的 TempSandbox 沙盒模式。
final class SkillManifestTests: XCTestCase {

    // MARK: - 辅助

    /// 构造一个内存 Skill（不进文件系统）
    private func makeSkill(
        name: String,
        presence: [String: PresenceKind] = [:],
        tags: [String] = [],
        gitRemote: String? = nil
    ) -> Skill {
        Skill(
            name: name,
            descriptionText: "",
            canonicalPath: URL(fileURLWithPath: "/tmp/store/\(name)"),
            presence: presence,
            tags: tags,
            gitRemote: gitRemote
        )
    }

    // MARK: - 编解码

    func testWriteLoadRoundTrip() throws {
        let box = try TempSandbox()
        let manifest = SkillManifest(
            entries: [
                .init(name: "alpha", source: "https://github.com/a/alpha", enabledTargetIDs: ["claude", "qoder"], tags: ["写作"]),
                .init(name: "beta", source: nil, enabledTargetIDs: [], tags: nil),
            ],
            appVersion: "1.2.3",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000) // iso8601 不带小数秒，用整秒保证往返一致
        )
        let file = box.root.appendingPathComponent("manifest.json")
        try manifest.write(to: file)

        let loaded = try SkillManifest.load(from: file)
        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(loaded.formatVersion, SkillManifest.currentFormatVersion)

        // 验证 JSON 是 prettyPrinted + sortedKeys（可读、可 diff）
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "应为多行 prettyPrinted 输出")
        XCTAssertTrue(text.contains("\"appVersion\" : \"1.2.3\""))
    }

    func testLoadRejectsUnsupportedFormatVersion() throws {
        let box = try TempSandbox()
        let file = box.root.appendingPathComponent("future.json")
        let json = """
        {"formatVersion": 99, "exportedAt": "2024-01-01T00:00:00Z", "entries": []}
        """
        try json.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SkillManifest.load(from: file)) { error in
            guard case SkillManifestError.unsupportedFormatVersion(let v) = error else {
                return XCTFail("应抛出 unsupportedFormatVersion，实际为 \(error)")
            }
            XCTAssertEqual(v, 99)
        }
    }

    // MARK: - makeManifest

    func testMakeManifestFields() {
        let lockFile = SkillLockFile(version: 1, skills: [
            // lock 里有 sourceUrl：优先用 sourceUrl
            "alpha": .init(source: "a/alpha", sourceType: "github", sourceUrl: "https://github.com/a/alpha",
                           skillPath: nil, skillFolderHash: nil, installedAt: nil, updatedAt: nil, ref: nil),
            // lock 里只有 source 没有 sourceUrl：退回 source
            "beta": .init(source: "b/beta", sourceType: "github", sourceUrl: nil,
                          skillPath: nil, skillFolderHash: nil, installedAt: nil, updatedAt: nil, ref: nil),
        ])
        let skills = [
            makeSkill(name: "alpha", presence: ["agents": .real, "qoder": .symlink, "claude": .symlink]),
            makeSkill(name: "beta", presence: ["agents": .real]),
            // lock 里没有记录，退回 gitRemote
            makeSkill(name: "gamma", presence: ["agents": .real, "claude": .broken], gitRemote: "git@github.com:c/gamma.git"),
            // 无来源的本地 skill：source 应为 nil
            makeSkill(name: "local-only", presence: ["agents": .real, "qoder": .symlink], tags: ["写作", "翻译"]),
        ]

        let manifest = SkillManifest.makeManifest(skills: skills, lockFile: lockFile, appVersion: "9.9")

        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.appVersion, "9.9")
        XCTAssertEqual(manifest.entries.count, 4)
        // 按名称排序
        XCTAssertEqual(manifest.entries.map(\.name), ["alpha", "beta", "gamma", "local-only"])

        let alpha = manifest.entries[0]
        XCTAssertEqual(alpha.source, "https://github.com/a/alpha")
        // 剔除本体库 agents，且按字母序
        XCTAssertEqual(alpha.enabledTargetIDs, ["claude", "qoder"])

        XCTAssertEqual(manifest.entries[1].source, "b/beta")
        XCTAssertEqual(manifest.entries[1].enabledTargetIDs, [])

        let gamma = manifest.entries[2]
        XCTAssertEqual(gamma.source, "git@github.com:c/gamma.git")
        // 断链（broken）不算已启用
        XCTAssertEqual(gamma.enabledTargetIDs, [])

        let local = manifest.entries[3]
        XCTAssertNil(local.source)
        XCTAssertEqual(local.enabledTargetIDs, ["qoder"])
        XCTAssertEqual(local.tags, ["写作", "翻译"])
    }

    // MARK: - planImport

    func testPlanImportThreeBranches() {
        let manifest = SkillManifest(entries: [
            // 1. 本地不存在 → toInstall
            .init(name: "newbie", source: "https://github.com/x/newbie", enabledTargetIDs: ["claude"], tags: nil),
            // 2. 已存在但少启用一个平台 → toEnable
            .init(name: "partial", source: nil, enabledTargetIDs: ["claude", "qoder"], tags: nil),
            // 3. 已存在且启用一致 → alreadyOK
            .init(name: "synced", source: nil, enabledTargetIDs: ["claude"], tags: nil),
        ])
        let existing = [
            makeSkill(name: "partial", presence: ["agents": .real, "claude": .symlink]),
            makeSkill(name: "synced", presence: ["agents": .real, "claude": .symlink, "qoder": .symlink]),
        ]

        let plan = SkillManifest.planImport(manifest: manifest, existingSkills: existing)

        XCTAssertEqual(plan.installCount, 1)
        XCTAssertEqual(plan.toInstall[0].name, "newbie")

        XCTAssertEqual(plan.enableCount, 1)
        XCTAssertEqual(plan.toEnable[0].entry.name, "partial")
        XCTAssertEqual(plan.toEnable[0].missingTargetIDs, ["qoder"])
        XCTAssertEqual(plan.toEnable[0].skill.name, "partial")

        XCTAssertEqual(plan.skipCount, 1)
        XCTAssertEqual(plan.alreadyOK[0].name, "synced")
        // synced 多启用的 qoder 不在清单里，也不影响"完全一致"的判定
    }

    // MARK: - executeImport

    func testExecuteImportInSandbox() throws {
        let box = try TempSandbox()
        let storeDir = box.root.appendingPathComponent("store", isDirectory: true)
        let claude = box.makeTarget("claude", "claude/skills")
        _ = box.makeTarget("qoder", "qoder/skills")

        // 本地来源：一个可直接安装的 skill 目录（走 install 的本地路径分支，不触发 git）
        try box.makeSkillDir("vendor/newbie", frontmatter: "---\nname: newbie\ndescription: N\n---\n")
        let localSource = box.root.appendingPathComponent("vendor/newbie").path

        // 已存在的 skill（在本体库），清单要求补启用 claude
        let existingDir = try box.makeSkillDir("store/partial", frontmatter: "---\nname: partial\ndescription: P\n---\n")
        let existingSkill = Skill(
            name: "partial",
            descriptionText: "P",
            canonicalPath: existingDir,
            presence: ["agents": .real]
        )

        let manifest = SkillManifest(entries: [
            // 有本地 source → 应安装成功并启用 claude
            .init(name: "newbie", source: localSource, enabledTargetIDs: ["claude"], tags: nil),
            // 无 source 且本地不存在 → skipped
            .init(name: "no-source", source: nil, enabledTargetIDs: ["claude"], tags: nil),
            // 假 source（不存在的本地路径）→ failed
            .init(name: "broken-src", source: box.root.appendingPathComponent("not-exist").path, enabledTargetIDs: [], tags: nil),
            // 已存在 → 补启用 claude；清单里的 qoder 在本机 targets 中不存在 → skipped
            .init(name: "partial", source: nil, enabledTargetIDs: ["claude", "qoder"], tags: nil),
        ])
        let plan = SkillManifest.planImport(manifest: manifest, existingSkills: [existingSkill])

        let result = SkillManifest.executeImport(plan: plan, storeDir: storeDir, targets: [claude])

        // 安装：newbie 成功，目录和软链都应存在
        XCTAssertEqual(result.installed, ["newbie"])
        XCTAssertTrue(box.fm.fileExists(atPath: storeDir.appendingPathComponent("newbie/SKILL.md").path))
        XCTAssertNotNil(try? box.fm.destinationOfSymbolicLink(atPath: claude.dir.appendingPathComponent("newbie").path))

        // 补启用：partial 的 claude 软链已建立
        XCTAssertEqual(result.enabled.count, 1)
        XCTAssertEqual(result.enabled[0].skill, "partial")
        XCTAssertEqual(result.enabled[0].targetID, "claude")
        XCTAssertNotNil(try? box.fm.destinationOfSymbolicLink(atPath: claude.dir.appendingPathComponent("partial").path))

        // 跳过：no-source（无来源）+ partial 的 qoder（本机无此平台）
        let skippedNames = result.skipped.map(\.name)
        XCTAssertTrue(skippedNames.contains("no-source"))
        XCTAssertTrue(result.skipped.contains { $0.name == "partial" && $0.reason.contains("qoder") })

        // 失败：假 source 应失败且不中断其他条目
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(result.failed[0].name, "broken-src")
        XCTAssertFalse(box.fm.fileExists(atPath: storeDir.appendingPathComponent("broken-src").path))
    }

    func testExecuteImportEmptyPlan() throws {
        let box = try TempSandbox()
        let plan = SkillManifest.ImportPlan()
        let result = SkillManifest.executeImport(
            plan: plan,
            storeDir: box.root.appendingPathComponent("store"),
            targets: []
        )
        XCTAssertTrue(result.installed.isEmpty)
        XCTAssertTrue(result.enabled.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.summary, "安装 0 个，启用 0 项，跳过 0 个，失败 0 个")
    }
}
