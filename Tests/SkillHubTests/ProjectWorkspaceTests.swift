import XCTest
@testable import SkillHub

final class ProjectWorkspaceTests: XCTestCase {

    // MARK: - 持久化辅助

    /// 独立 UserDefaults suite，避免污染 standard
    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let suite = "skillhub-test-\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - 注册 / 查重 / 持久化

    func testStoreAddRemoveAndDedup() throws {
        let box = try TempSandbox()
        let projectA = box.root.appendingPathComponent("projA", isDirectory: true)
        let projectB = box.root.appendingPathComponent("projB", isDirectory: true)
        try box.fm.createDirectory(at: projectA, withIntermediateDirectories: true)
        try box.fm.createDirectory(at: projectB, withIntermediateDirectories: true)

        let store = ProjectWorkspaceStore(defaults: makeDefaults())
        XCTAssertTrue(store.workspaces.isEmpty)

        let wsA = try store.add(path: projectA)
        _ = try store.add(path: projectB)
        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(wsA.name, "projA", "默认名应取项目目录名")

        // 同名路径带尾斜杠 / 相对组件应判重
        XCTAssertThrowsError(try store.add(path: projectA.appendingPathComponent("."))) { error in
            guard case ProjectWorkspaceError.alreadyRegistered = error else {
                return XCTFail("应报 alreadyRegistered，实为 \(error)")
            }
        }
        XCTAssertTrue(store.contains(path: URL(fileURLWithPath: projectA.path + "/")))
        XCTAssertEqual(store.workspaces.count, 2)

        store.remove(id: wsA.id)
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertFalse(store.contains(path: projectA))
    }

    func testStorePersistenceRoundTrip() throws {
        let box = try TempSandbox()
        let project = box.root.appendingPathComponent("my-proj", isDirectory: true)
        try box.fm.createDirectory(at: project, withIntermediateDirectories: true)

        let suite = "skillhub-test-\(UUID().uuidString)"
        let defaults1 = UserDefaults(suiteName: suite)!
        defaults1.removePersistentDomain(forName: suite)

        let store1 = ProjectWorkspaceStore(defaults: defaults1)
        let ws = try store1.add(path: project, name: "自定义名")

        // 用同一 suite 新建 store，应从 UserDefaults 读回
        let defaults2 = UserDefaults(suiteName: suite)!
        let store2 = ProjectWorkspaceStore(defaults: defaults2)
        XCTAssertEqual(store2.workspaces.count, 1)
        let loaded = store2.workspaces[0]
        XCTAssertEqual(loaded.id, ws.id)
        XCTAssertEqual(loaded.name, "自定义名")
        XCTAssertEqual(loaded.path, project)
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, ws.createdAt.timeIntervalSince1970, accuracy: 0.001)

        defaults1.removePersistentDomain(forName: suite)
    }

    // MARK: - 扫描

    func testScanFindsMultipleKnownDirs() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("proj/.claude/skills/alpha",
                                 frontmatter: "---\nname: alpha\ndescription: A skill\n---\n")
        _ = try box.makeSkillDir("proj/.agents/skills/beta")
        _ = try box.makeSkillDir("proj/.codex/skills/gamma")

        let ws = ProjectWorkspace(path: box.root.appendingPathComponent("proj", isDirectory: true))
        let entries = try ProjectScanner.scan(workspace: ws)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(Set(entries.map(\.source)), [".agents/skills", ".claude/skills", ".codex/skills"])
        let alpha = entries.first { $0.directoryName == "alpha" }
        XCTAssertEqual(alpha?.skillName, "alpha")
        XCTAssertEqual(alpha?.descriptionText, "A skill")
        XCTAssertEqual(alpha?.hasFrontmatter, true)
        XCTAssertEqual(alpha?.fileCount, 1)
        XCTAssertGreaterThan(alpha?.sizeBytes ?? 0, 0)
        // 无 frontmatter 的条目以目录名为 skillName
        let beta = entries.first { $0.directoryName == "beta" }
        XCTAssertEqual(beta?.skillName, "beta")
        XCTAssertEqual(beta?.hasFrontmatter, false)
    }

    func testScanIgnoresDirsWithoutSkillMarkdown() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("proj/.claude/skills/real-skill")
        let notSkill = box.root.appendingPathComponent("proj/.claude/skills/not-a-skill", isDirectory: true)
        try box.fm.createDirectory(at: notSkill, withIntermediateDirectories: true)
        try "readme".write(to: notSkill.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let ws = ProjectWorkspace(path: box.root.appendingPathComponent("proj", isDirectory: true))
        let entries = try ProjectScanner.scan(workspace: ws)
        XCTAssertEqual(entries.map(\.directoryName), ["real-skill"])
    }

    func testScanResolvesSymlinkedSkillDir() throws {
        let box = try TempSandbox()
        let real = try box.makeSkillDir("elsewhere/linked-skill",
                                        frontmatter: "---\nname: linked\n---\n")
        let skillsDir = box.root.appendingPathComponent("proj/.claude/skills", isDirectory: true)
        try box.fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try box.fm.createSymbolicLink(at: skillsDir.appendingPathComponent("linked-skill"),
                                      withDestinationURL: real)

        let ws = ProjectWorkspace(path: box.root.appendingPathComponent("proj", isDirectory: true))
        let entries = try ProjectScanner.scan(workspace: ws)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].skillName, "linked")
        XCTAssertEqual(entries[0].directory.standardizedFileURL.path, real.standardizedFileURL.path)
    }

    func testScanThrowsForMissingProject() throws {
        let box = try TempSandbox()
        let ws = ProjectWorkspace(path: box.root.appendingPathComponent("no/such/project", isDirectory: true))
        XCTAssertThrowsError(try ProjectScanner.scan(workspace: ws)) { error in
            guard case ProjectWorkspaceError.projectNotFound = error else {
                return XCTFail("应报 projectNotFound，实为 \(error)")
            }
        }
    }

    func testScanReturnsEmptyWhenNoKnownDirs() throws {
        let box = try TempSandbox()
        let proj = box.root.appendingPathComponent("proj", isDirectory: true)
        try box.fm.createDirectory(at: proj, withIntermediateDirectories: true)
        try "code".write(to: proj.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let ws = ProjectWorkspace(path: proj)
        let entries = try ProjectScanner.scan(workspace: ws)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - 导入 / 导出

    func testImportToStoreCopiesAndKeepsSource() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("proj/.claude/skills/alpha",
                                 frontmatter: "---\nname: alpha\n---\n",
                                 extraBody: "# Alpha\n")
        let ws = ProjectWorkspace(path: box.root.appendingPathComponent("proj", isDirectory: true))
        let entry = try XCTUnwrap(ProjectScanner.scan(workspace: ws).first)
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)

        let dest = try ProjectSync.importToStore(entry: entry, workspace: ws, storeDir: storeDir)

        // 目标有内容
        XCTAssertTrue(box.fm.fileExists(atPath: dest.appendingPathComponent("SKILL.md").path))
        // 源不动
        XCTAssertTrue(box.fm.fileExists(atPath: entry.directory.appendingPathComponent("SKILL.md").path))
        XCTAssertEqual(dest.lastPathComponent, "alpha")
    }

    func testImportToStoreConflictThrows() throws {
        let box = try TempSandbox()
        _ = try box.makeSkillDir("proj/.claude/skills/alpha")
        _ = try box.makeSkillDir("store/skills/alpha") // 本体库已有同名

        let ws = ProjectWorkspace(path: box.root.appendingPathComponent("proj", isDirectory: true))
        let entry = try XCTUnwrap(ProjectScanner.scan(workspace: ws).first)
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)

        XCTAssertThrowsError(try ProjectSync.importToStore(entry: entry, workspace: ws, storeDir: storeDir)) { error in
            guard case ProjectWorkspaceError.nameConflict(let name, _) = error else {
                return XCTFail("应报 nameConflict，实为 \(error)")
            }
            XCTAssertEqual(name, "alpha")
        }
    }

    func testExportToProjectCopiesAndKeepsSource() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/beta",
                                             frontmatter: "---\nname: beta\n---\n")
        let proj = box.root.appendingPathComponent("proj", isDirectory: true)
        try box.fm.createDirectory(at: proj, withIntermediateDirectories: true)
        let ws = ProjectWorkspace(path: proj)

        // 默认子目录
        let dest = try ProjectSync.exportToProject(skillCanonicalPath: canonical, workspace: ws)
        XCTAssertEqual(dest.deletingLastPathComponent().lastPathComponent, "skills")
        XCTAssertTrue(box.fm.fileExists(atPath: proj.appendingPathComponent(".claude/skills/beta/SKILL.md").path))
        // 源不动
        XCTAssertTrue(box.fm.fileExists(atPath: canonical.appendingPathComponent("SKILL.md").path))

        // 指定子目录
        let dest2 = try ProjectSync.exportToProject(skillCanonicalPath: canonical, workspace: ws, subdir: ".agents/skills")
        XCTAssertTrue(box.fm.fileExists(atPath: proj.appendingPathComponent(".agents/skills/beta/SKILL.md").path))
        XCTAssertEqual(dest2.lastPathComponent, "beta")
    }

    func testExportToProjectConflictThrows() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/beta")
        _ = try box.makeSkillDir("proj/.claude/skills/beta") // 项目已有同名
        let ws = ProjectWorkspace(path: box.root.appendingPathComponent("proj", isDirectory: true))

        XCTAssertThrowsError(try ProjectSync.exportToProject(skillCanonicalPath: canonical, workspace: ws)) { error in
            guard case ProjectWorkspaceError.nameConflict(let name, _) = error else {
                return XCTFail("应报 nameConflict，实为 \(error)")
            }
            XCTAssertEqual(name, "beta")
        }
    }

    func testExportToProjectMissingProjectThrows() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/beta")
        let ws = ProjectWorkspace(path: box.root.appendingPathComponent("ghost", isDirectory: true))

        XCTAssertThrowsError(try ProjectSync.exportToProject(skillCanonicalPath: canonical, workspace: ws)) { error in
            guard case ProjectWorkspaceError.projectNotFound = error else {
                return XCTFail("应报 projectNotFound，实为 \(error)")
            }
        }
    }

    func testImportFromSymlinkedEntryCopiesRealContent() throws {
        let box = try TempSandbox()
        let real = try box.makeSkillDir("elsewhere/gamma", frontmatter: "---\nname: gamma\n---\n")
        let skillsDir = box.root.appendingPathComponent("proj/.claude/skills", isDirectory: true)
        try box.fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try box.fm.createSymbolicLink(at: skillsDir.appendingPathComponent("gamma"),
                                      withDestinationURL: real)

        let ws = ProjectWorkspace(path: box.root.appendingPathComponent("proj", isDirectory: true))
        let entry = try XCTUnwrap(ProjectScanner.scan(workspace: ws).first)
        let storeDir = box.root.appendingPathComponent("store", isDirectory: true)

        let dest = try ProjectSync.importToStore(entry: entry, workspace: ws, storeDir: storeDir)
        // 导入后本体库是真实目录而非软链
        let values = try dest.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, false)
        XCTAssertTrue(box.fm.fileExists(atPath: dest.appendingPathComponent("SKILL.md").path))
        // 源（真实目录与软链）都不动
        XCTAssertTrue(box.fm.fileExists(atPath: real.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(box.fm.fileExists(atPath: skillsDir.appendingPathComponent("gamma").path))
    }
}
