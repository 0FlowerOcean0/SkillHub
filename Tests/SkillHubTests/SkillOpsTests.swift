import XCTest
@testable import SkillHub

final class SkillOpsTests: XCTestCase {

    // MARK: - relativePath

    func testRelativePathSiblingDirs() {
        let from = URL(fileURLWithPath: "/Users/x/.claude/skills")
        let to = URL(fileURLWithPath: "/Users/x/.agents/skills/foo")
        XCTAssertEqual(SkillOps.relativePath(from: from, to: to), "../../.agents/skills/foo")
    }

    func testRelativePathChildAndSelf() {
        let base = URL(fileURLWithPath: "/a/b")
        XCTAssertEqual(SkillOps.relativePath(from: base, to: URL(fileURLWithPath: "/a/b/c")), "c")
        XCTAssertEqual(SkillOps.relativePath(from: base, to: base), ".")
    }

    func testRelativePathNoCommonPrefix() {
        let from = URL(fileURLWithPath: "/x/y")
        let to = URL(fileURLWithPath: "/p/q/r")
        XCTAssertEqual(SkillOps.relativePath(from: from, to: to), "../../p/q/r")
    }

    // MARK: - enable / disable（临时目录 fixture）

    func testEnableCreatesWorkingSymlinkAndDisableRemovesIt() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/gamma", frontmatter: "---\nname: gamma\n---\n")
        let target = box.makeTarget("agentA", "a/skills")

        var skill = Skill(name: "gamma", descriptionText: "", version: nil, canonicalPath: canonical)

        try SkillOps.enable(skill: skill, in: target)
        let link = target.dir.appendingPathComponent("gamma")
        // 软链接应解析回本体
        XCTAssertEqual(link.resolvingSymlinksInPath().standardizedFileURL.path,
                       canonical.standardizedFileURL.path)

        // 重复 enable 应报错
        XCTAssertThrowsError(try SkillOps.enable(skill: skill, in: target))

        skill.presence["agentA"] = .symlink
        try SkillOps.disable(skill: skill, in: target)
        XCTAssertFalse(box.fm.fileExists(atPath: link.path))
        // 本体仍在
        XCTAssertTrue(box.fm.fileExists(atPath: canonical.appendingPathComponent("SKILL.md").path))
    }

    func testDisableRefusesRealDirectory() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("a/skills/real", frontmatter: "---\nname: real\n---\n")
        let target = box.makeTarget("agentA", "a/skills")
        let skill = Skill(name: "real", descriptionText: "", version: nil, canonicalPath: canonical)

        XCTAssertThrowsError(try SkillOps.disable(skill: skill, in: target)) { error in
            XCTAssertTrue(error.localizedDescription.contains("本体"))
        }
        // 真实目录必须还在
        XCTAssertTrue(box.fm.fileExists(atPath: canonical.path))
    }

    // MARK: - addFrontmatter / addDescription

    func testAddFrontmatterPrependsBlock() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/plain", extraBody: "# plain\nbody text\n")
        let md = dir.appendingPathComponent("SKILL.md")

        try SkillOps.addFrontmatter(to: md)
        let parsed = FrontmatterParser.parse(fileURL: md)
        XCTAssertTrue(parsed.hasFrontmatter)
        XCTAssertEqual(parsed.name, "plain")

        let text = try String(contentsOf: md, encoding: .utf8)
        XCTAssertTrue(text.contains("# plain"), "正文必须保留")
    }

    func testAddDescriptionInsertsAfterName() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/d", frontmatter: "---\nname: d\n---\n")
        let md = dir.appendingPathComponent("SKILL.md")

        try SkillOps.addDescription(to: md, description: "新描述")
        let parsed = FrontmatterParser.parse(fileURL: md)
        XCTAssertEqual(parsed.descriptionText, "新描述")
        XCTAssertEqual(parsed.name, "d")
    }

    // MARK: - renameDirectory

    func testRenameDirectoryUpdatesQuotedName() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/old", frontmatter: "---\nname: \"old\"\ndescription: d\n---\n")
        try SkillOps.renameDirectory(from: dir, to: "new")

        let newDir = box.root.appendingPathComponent("store/skills/new")
        XCTAssertTrue(box.fm.fileExists(atPath: newDir.path))
        XCTAssertFalse(box.fm.fileExists(atPath: dir.path))
        let parsed = FrontmatterParser.parse(fileURL: newDir.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(parsed.name, "new")
    }

    func testRenameDirectoryUpdatesUnquotedNameAndKeepsBody() throws {
        let body = "正文里提到 name: something 不应被改动\n"
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/old2",
                                       frontmatter: "---\nname: old2\ndescription: d\n---\n",
                                       extraBody: body)
        try SkillOps.renameDirectory(from: dir, to: "new2")

        let md = box.root.appendingPathComponent("store/skills/new2/SKILL.md")
        let parsed = FrontmatterParser.parse(fileURL: md)
        XCTAssertEqual(parsed.name, "new2", "无引号的 name 也要更新")
        let text = try String(contentsOf: md, encoding: .utf8)
        XCTAssertTrue(text.contains("name: something"), "正文中的 name: 不应被修改")
    }

    func testRenameDirectoryFailsIfTargetExists() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("store/skills/a1")
        _ = try box.makeSkillDir("store/skills/a2")
        XCTAssertThrowsError(try SkillOps.renameDirectory(from: dir, to: "a2"))
        XCTAssertTrue(box.fm.fileExists(atPath: dir.path), "失败后源目录应保持不变")
    }

    // MARK: - removeReference

    func testRemoveReferenceDropsOnlyMatchingLines() throws {
        let box = try TempSandbox()
        let dir = try box.makeSkillDir(
            "store/skills/r",
            frontmatter: "---\nname: r\ndescription: d\n---\n",
            extraBody: "看 references/gone.md 这个文件\n另一行 references/kept.md 保留\n"
        )
        let md = dir.appendingPathComponent("SKILL.md")
        try SkillOps.removeReference(from: md, reference: "references/gone.md")

        let text = try String(contentsOf: md, encoding: .utf8)
        XCTAssertFalse(text.contains("references/gone.md"))
        XCTAssertTrue(text.contains("references/kept.md"))
        XCTAssertTrue(FrontmatterParser.parse(fileURL: md).hasFrontmatter)
    }

    // MARK: - migrateToStore（一键收编）

    func testMigrateToStoreWithCustomTargetRelinks() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("customAgent/skills/omega", frontmatter: "---\nname: omega\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let customTarget = box.makeTarget("custom_x", "customAgent/skills")

        try SkillOps.migrateToStore(skillPath: stray, target: customTarget, storeDir: storeDir)

        let dest = storeDir.appendingPathComponent("omega")
        XCTAssertTrue(box.fm.fileExists(atPath: dest.path), "本体应移动到本体库")
        // 原位置的本体目录应被替换为软链（路径仍在，但已是指回本体的链接）
        let link = customTarget.dir.appendingPathComponent("omega")
        XCTAssertEqual((try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink, true,
                       "原位置应留下软链而非真实目录")
        // 软链应解析回本体
        XCTAssertEqual(link.resolvingSymlinksInPath().standardizedFileURL.path,
                       dest.standardizedFileURL.path)
    }

    func testMigrateToStoreWithoutTargetOnlyMoves() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("elsewhere/delta", frontmatter: "---\nname: delta\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)

        try SkillOps.migrateToStore(skillPath: stray, target: nil, storeDir: storeDir)

        XCTAssertTrue(box.fm.fileExists(atPath: storeDir.appendingPathComponent("delta").path))
        XCTAssertFalse(box.fm.fileExists(atPath: stray.path))
    }

    func testMigrateToStoreFailsOnNameConflict() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("agentB/skills/dup", frontmatter: "---\nname: dup\n---\n")
        _ = try box.makeSkillDir("store/skills/dup", frontmatter: "---\nname: dup\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)

        XCTAssertThrowsError(try SkillOps.migrateToStore(skillPath: stray, target: nil, storeDir: storeDir))
        XCTAssertTrue(box.fm.fileExists(atPath: stray.path), "冲突时源目录应保持不变")
    }

    // MARK: - relinkToStore（同名冲突的链接化处理）

    func testRelinkToStoreTrashesStrayAndCreatesSymlink() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("agentC/skills/echo", frontmatter: "---\nname: echo\n---\n")
        let stored = try box.makeSkillDir("store/skills/echo", frontmatter: "---\nname: echo\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let target = box.makeTarget("agentC", "agentC/skills")

        try SkillOps.relinkToStore(skillPath: stray, target: target, storeDir: storeDir)

        // 原位置变成指向本体库版本的软链（用新 URL 实例判断，避免 resourceValues 缓存）
        let freshStray = URL(fileURLWithPath: stray.path)
        XCTAssertEqual((try? freshStray.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink, true)
        XCTAssertEqual(freshStray.resolvingSymlinksInPath().standardizedFileURL.path,
                       stored.standardizedFileURL.path)
        // 本体库版本不受影响
        XCTAssertTrue(box.fm.fileExists(atPath: stored.appendingPathComponent("SKILL.md").path))
    }

    func testRelinkToStoreRequiresStoreVersion() throws {
        let box = try TempSandbox()
        let stray = try box.makeSkillDir("agentC/skills/lonely", frontmatter: "---\nname: lonely\n---\n")
        let storeDir = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let target = box.makeTarget("agentC", "agentC/skills")

        XCTAssertThrowsError(try SkillOps.relinkToStore(skillPath: stray, target: target, storeDir: storeDir))
        XCTAssertTrue(box.fm.fileExists(atPath: stray.appendingPathComponent("SKILL.md").path),
                      "失败时散落目录应保持不变")
    }

    // MARK: - copy 启用模式

    func testEnableCopyModeCopiesContentAndMarker() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/cp",
                                             frontmatter: "---\nname: cp\n---\n",
                                             extraBody: "copy-body\n")
        let target = box.makeTarget("agentA", "a/skills")
        let skill = Skill(name: "cp", descriptionText: "", version: nil, canonicalPath: canonical)

        try SkillOps.enable(skill: skill, in: target, mode: .copy)

        let copy = target.dir.appendingPathComponent("cp")
        // 是真实目录而不是软链
        XCTAssertNil(try? box.fm.destinationOfSymbolicLink(atPath: copy.path))
        // 内容与本体一致
        let src = try String(contentsOf: canonical.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let dst = try String(contentsOf: copy.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertEqual(src, dst)
        XCTAssertTrue(dst.contains("copy-body"))
        // 含副本标记文件
        XCTAssertTrue(box.fm.fileExists(atPath: copy.appendingPathComponent(SkillOps.copyMarkerName).path))
    }

    func testEnableCopyModeConflictThrowsLikeSymlink() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/cp2", frontmatter: "---\nname: cp2\n---\n")
        let target = box.makeTarget("agentA", "a/skills")
        let skill = Skill(name: "cp2", descriptionText: "", version: nil, canonicalPath: canonical)

        try SkillOps.enable(skill: skill, in: target, mode: .copy)
        // 目标已存在时与软链模式一样报错
        XCTAssertThrowsError(try SkillOps.enable(skill: skill, in: target, mode: .copy)) { error in
            XCTAssertTrue(error.localizedDescription.contains("已存在同名条目"))
        }
    }

    func testDisableRemovesCopyWithMarker() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/cpd", frontmatter: "---\nname: cpd\n---\n")
        let target = box.makeTarget("agentA", "a/skills")
        let skill = Skill(name: "cpd", descriptionText: "", version: nil, canonicalPath: canonical)

        try SkillOps.enable(skill: skill, in: target, mode: .copy)
        let copy = target.dir.appendingPathComponent("cpd")
        XCTAssertTrue(box.fm.fileExists(atPath: copy.path))

        try SkillOps.disable(skill: skill, in: target)
        // 副本被删除，本体不动
        XCTAssertFalse(box.fm.fileExists(atPath: copy.path))
        XCTAssertTrue(box.fm.fileExists(atPath: canonical.appendingPathComponent("SKILL.md").path))
    }

    func testDisableStillRefusesRealDirectoryWithoutMarker() throws {
        // 手工放进平台目录的真实目录（无 .skillhub-copy 标记）按本体保护，disable 仍拒绝
        let box = try TempSandbox()
        let real = try box.makeSkillDir("a/skills/real2", frontmatter: "---\nname: real2\n---\n")
        let target = box.makeTarget("agentA", "a/skills")
        let skill = Skill(name: "real2", descriptionText: "", version: nil, canonicalPath: real)

        XCTAssertThrowsError(try SkillOps.disable(skill: skill, in: target)) { error in
            XCTAssertTrue(error.localizedDescription.contains("本体"))
        }
        XCTAssertTrue(box.fm.fileExists(atPath: real.appendingPathComponent("SKILL.md").path))
    }

    // MARK: - install @ref（git tag / commit SHA）

    /// 在沙盒里现场 git init 一个仓库：v1 打 tag，HEAD 再前进一个 commit
    private func makeGitFixtureRepo(_ box: TempSandbox) throws -> URL {
        let repo = box.root.appendingPathComponent("repo", isDirectory: true)
        try box.fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try runTestGit(["init", "-b", "main"], in: repo)
        let skillDir = repo.appendingPathComponent("myskill", isDirectory: true)
        try box.fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "v1 content\n".write(to: skillDir.appendingPathComponent("SKILL.md"),
                                 atomically: true, encoding: .utf8)
        try runTestGit(["add", "."], in: repo)
        try runTestGit(["-c", "user.email=test@example.com", "-c", "user.name=test",
                        "commit", "-m", "v1"], in: repo)
        try runTestGit(["tag", "v1.0"], in: repo)
        // HEAD 前进到 v2，验证 @v1.0 装的是 tag 版本而不是 HEAD
        try "v2 content\n".write(to: skillDir.appendingPathComponent("SKILL.md"),
                                 atomically: true, encoding: .utf8)
        try runTestGit(["add", "."], in: repo)
        try runTestGit(["-c", "user.email=test@example.com", "-c", "user.name=test",
                        "commit", "-m", "v2"], in: repo)
        return repo
    }

    private func runTestGit(_ args: [String], in dir: URL, timeout: TimeInterval = 60) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            XCTFail("git \(args.first ?? "") 超时（\(timeout)s）")
            return
        }
        if p.terminationStatus != 0 {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("git \(args.joined(separator: " ")) 失败：\(msg)")
        }
    }

    func testInstallWithTagRefChecksOutTaggedVersion() throws {
        let box = try TempSandbox()
        let repo = try makeGitFixtureRepo(box)
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let lockURL = box.root.appendingPathComponent("store/.skill-lock.json")

        let result = try SkillOps.installWithRef(source: "file://\(repo.path)@v1.0",
                                                 storeDir: store, enableTargets: [],
                                                 lockFileURL: lockURL)
        XCTAssertEqual(result.installed, ["myskill"])
        XCTAssertEqual(result.resolvedRef, "v1.0")
        XCTAssertEqual(result.resolvedCommit?.count, 40)
        let lock = SkillLockFile.load(from: lockURL)
        XCTAssertEqual(lock?.skills["myskill"]?.ref, "v1.0")
        XCTAssertEqual(lock?.skills["myskill"]?.resolvedCommit, result.resolvedCommit)
        let md = try String(contentsOf: store.appendingPathComponent("myskill/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("v1 content"), "应 checkout 到 tag 版本而不是 HEAD 的 v2")
    }

    func testInstallWithCommitSHARef() throws {
        let box = try TempSandbox()
        let repo = try makeGitFixtureRepo(box)
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)

        // 取 v1.0 的完整 SHA 做 ref
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["rev-parse", "v1.0"]
        p.currentDirectoryURL = repo
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let sha = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(sha.count, 40)

        let result = try SkillOps.installWithRef(source: "file://\(repo.path)@\(sha)",
                                                 storeDir: store, enableTargets: [])
        XCTAssertEqual(result.resolvedRef, sha)
        let md = try String(contentsOf: store.appendingPathComponent("myskill/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("v1 content"))
    }

    func testInstallWithBadRefThrowsCheckoutError() throws {
        let box = try TempSandbox()
        let repo = try makeGitFixtureRepo(box)
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)

        XCTAssertThrowsError(try SkillOps.install(source: "file://\(repo.path)@nope-9.9",
                                                  storeDir: store, enableTargets: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("checkout"),
                          "坏 ref 应抛明确的 checkout 错误，实际：\(error.localizedDescription)")
        }
        XCTAssertFalse(box.fm.fileExists(atPath: store.appendingPathComponent("myskill").path),
                       "失败后不应留下安装产物")
    }

    func testInstallLocalPathContainingAtSignIsNotParsedAsRef() throws {
        // 本地路径里含 @ 很常见，不能当成 @ref 拆
        let box = try TempSandbox()
        let dir = try box.makeSkillDir("weird@dir/myskill", frontmatter: "---\nname: myskill\n---\n")
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)

        let result = try SkillOps.installWithRef(source: dir.path, storeDir: store, enableTargets: [])
        XCTAssertEqual(result.installed, ["myskill"])
        XCTAssertNil(result.resolvedRef)
        XCTAssertTrue(box.fm.fileExists(atPath: store.appendingPathComponent("myskill/SKILL.md").path))
    }

    func testInstallGitSourceWithoutRefKeepsShallowHead() throws {
        // 无 @ 时行为不变：装到 HEAD（v2），resolvedRef 为 nil
        let box = try TempSandbox()
        let repo = try makeGitFixtureRepo(box)
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)

        let result = try SkillOps.installWithRef(source: "file://\(repo.path)",
                                                 storeDir: store, enableTargets: [])
        XCTAssertNil(result.resolvedRef)
        let md = try String(contentsOf: store.appendingPathComponent("myskill/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("v2 content"))
    }

    func testParseGitInstallSourcePreservesTreeRefAndSubdirectory() throws {
        let parsed = try SkillOps.parseGitInstallSource(
            "https://github.com/example/catalog/tree/release-1/skills/pdf"
        )

        XCTAssertEqual(parsed.repository, "https://github.com/example/catalog")
        XCTAssertEqual(parsed.ref, "release-1")
        XCTAssertEqual(parsed.subPath, "skills/pdf")
    }

    func testPrepareInstallTreeURLChecksOutRequestedBranchBeforeSelectingSubdirectory() throws {
        let box = try TempSandbox()
        let repo = try makeGitFixtureRepo(box)
        try runTestGit(["checkout", "-b", "preview"], in: repo)
        let branchSkill = repo.appendingPathComponent("catalog/branch-only", isDirectory: true)
        try box.fm.createDirectory(at: branchSkill, withIntermediateDirectories: true)
        try "---\nname: branch-only\ndescription: Only on preview\n---\n".write(
            to: branchSkill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try runTestGit(["add", "."], in: repo)
        try runTestGit([
            "-c", "user.email=test@example.com", "-c", "user.name=test",
            "commit", "-m", "preview skill",
        ], in: repo)
        try runTestGit(["checkout", "main"], in: repo)

        let source = "file://\(repo.path)/tree/preview/catalog/branch-only"
        let prepared = try SkillOps.prepareInstall(source: source)
        defer { SkillOps.discardPreparedInstall(prepared) }

        XCTAssertEqual(prepared.requestedRef, "preview")
        XCTAssertEqual(prepared.resolvedCommit?.count, 40)
        XCTAssertEqual(prepared.items.map(\.name), ["branch-only"])
        XCTAssertEqual(prepared.items.map(\.skillPath), ["."])
    }

    func testParseGitInstallSourceRejectsTreeURLWithoutRef() {
        XCTAssertThrowsError(
            try SkillOps.parseGitInstallSource("https://github.com/example/catalog/tree/")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("缺少分支"))
        }
    }

    func testPrepareInstallSelectsOnlyRequestedSkillAndReportsSkipped() throws {
        let box = try TempSandbox()
        let repo = box.root.appendingPathComponent("catalog", isDirectory: true)
        _ = try box.makeSkillDir(
            "catalog/skills/pdf",
            frontmatter: "---\nname: pdf\ndescription: PDF tools\n---\n"
        )
        _ = try box.makeSkillDir(
            "catalog/skills/slides",
            frontmatter: "---\nname: slides\ndescription: Slide tools\n---\n"
        )

        let prepared = try SkillOps.prepareInstall(source: repo.path, selectedSkillID: "pdf")
        defer { SkillOps.discardPreparedInstall(prepared) }

        XCTAssertEqual(prepared.items.map(\.name), ["pdf"])
        XCTAssertEqual(prepared.skippedSkillNames, ["slides"])
        XCTAssertEqual(prepared.items.first?.validationWarnings, [])
        XCTAssertEqual(prepared.items.first?.securityReport.score, 100)
        XCTAssertFalse(box.fm.fileExists(atPath: box.root.appendingPathComponent("store/skills/pdf").path),
                       "prepare 阶段不能写入本体库")
    }

    func testCommitPreparedInstallWritesLockAndEnablesAtomically() throws {
        let box = try TempSandbox()
        let source = try box.makeSkillDir(
            "source/precise",
            frontmatter: "---\nname: precise\ndescription: Precise install\n---\n"
        )
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let lockURL = box.root.appendingPathComponent("store/.skill-lock.json")
        let target = box.makeTarget("agentA", "agent/skills")
        let prepared = try SkillOps.prepareInstall(source: source.path, selectedSkillID: "precise")

        let result = try SkillOps.commitPreparedInstall(
            prepared,
            storeDir: store,
            enableTargets: [target],
            lockFileURL: lockURL
        )

        XCTAssertEqual(result.installed, ["precise"])
        let installed = store.appendingPathComponent("precise")
        XCTAssertTrue(box.fm.fileExists(atPath: installed.appendingPathComponent("SKILL.md").path))
        XCTAssertEqual(
            target.dir.appendingPathComponent("precise").resolvingSymlinksInPath().standardizedFileURL.path,
            installed.standardizedFileURL.path
        )
        let lock = SkillLockFile.load(from: lockURL)
        XCTAssertEqual(lock?.skills["precise"]?.sourceType, "local")
        XCTAssertEqual(lock?.skills["precise"]?.skillFolderHash, result.records.first?.folderHash)
    }

    func testCommitPreparedInstallRollsBackNewTargetDirectoryWhenLockWriteFails() throws {
        let box = try TempSandbox()
        let source = try box.makeSkillDir(
            "source/rollback",
            frontmatter: "---\nname: rollback\ndescription: Rollback target directory\n---\n"
        )
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let target = AgentTarget(
            id: "new-agent",
            displayName: "New Agent",
            dir: box.root.appendingPathComponent("new-agent/skills", isDirectory: true)
        )
        let invalidLockURL = box.root.appendingPathComponent("locked-as-directory", isDirectory: true)
        try box.fm.createDirectory(at: invalidLockURL, withIntermediateDirectories: true)
        let prepared = try SkillOps.prepareInstall(source: source.path)
        defer { SkillOps.discardPreparedInstall(prepared) }

        XCTAssertThrowsError(try SkillOps.commitPreparedInstall(
            prepared,
            storeDir: store,
            enableTargets: [target],
            lockFileURL: invalidLockURL
        ))
        XCTAssertFalse(box.fm.fileExists(atPath: store.appendingPathComponent("rollback").path))
        XCTAssertFalse(box.fm.fileExists(atPath: target.dir.path),
                       "失败回滚不能留下本次新建的空 Agent 目录")
    }

    func testCommitPreparedInstallPreflightLeavesNoPartialInstallOnConflict() throws {
        let box = try TempSandbox()
        let source = try box.makeSkillDir(
            "source/conflict",
            frontmatter: "---\nname: conflict\ndescription: Conflict test\n---\n"
        )
        let store = box.root.appendingPathComponent("store/skills", isDirectory: true)
        let target = box.makeTarget("agentA", "agent/skills")
        _ = try box.makeSkillDir(
            "agent/skills/conflict",
            frontmatter: "---\nname: conflict\ndescription: Existing\n---\n"
        )
        let prepared = try SkillOps.prepareInstall(source: source.path, selectedSkillID: "conflict")

        XCTAssertThrowsError(try SkillOps.commitPreparedInstall(
            prepared,
            storeDir: store,
            enableTargets: [target]
        ))
        XCTAssertTrue(box.fm.fileExists(atPath: prepared.stagingRoot.path),
                      "提交失败后应保留冻结内容，以便用户直接重试")
        XCTAssertFalse(box.fm.fileExists(atPath: store.appendingPathComponent("conflict").path),
                       "预检冲突后本体库不能留下半成品")
        XCTAssertTrue(box.fm.fileExists(atPath: target.dir.appendingPathComponent("conflict/SKILL.md").path),
                      "已有目标不能被修改")

        // 用户解决冲突后，同一份已审查内容应能直接重试，不重新下载。
        try box.fm.removeItem(at: target.dir.appendingPathComponent("conflict"))
        let retry = try SkillOps.commitPreparedInstall(
            prepared,
            storeDir: store,
            enableTargets: [target]
        )
        XCTAssertEqual(retry.installed, ["conflict"])
        XCTAssertFalse(box.fm.fileExists(atPath: prepared.stagingRoot.path),
                       "提交成功后应清理冻结内容")
    }

    func testPrepareInstallRejectsSymlinkEscapingSkillDirectory() throws {
        let box = try TempSandbox()
        let source = try box.makeSkillDir(
            "source/unsafe",
            frontmatter: "---\nname: unsafe\ndescription: Unsafe link\n---\n"
        )
        let outside = box.root.appendingPathComponent("secret.txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try box.fm.createSymbolicLink(
            atPath: source.appendingPathComponent("secret-link").path,
            withDestinationPath: outside.path
        )

        XCTAssertThrowsError(try SkillOps.prepareInstall(source: source.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("目录外的软链接"))
        }
    }

    // MARK: - trash 联动清理 copy 副本

    func testTrashRemovesSymlinksAndCopyCopiesButProtectsRealDirs() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/x", frontmatter: "---\nname: x\n---\n")
        let targetLink = box.makeTarget("agentA", "a/skills")
        let targetCopy = box.makeTarget("agentB", "b/skills")
        let targetReal = box.makeTarget("agentC", "c/skills")
        let skill = Skill(name: "x", descriptionText: "", version: nil, canonicalPath: canonical)

        // 软链启用 + copy 启用
        try SkillOps.enable(skill: skill, in: targetLink)
        try SkillOps.enable(skill: skill, in: targetCopy, mode: .copy)
        // 手工放进平台目录的同名真实目录（无标记，按本体保护）
        let realDir = try box.makeSkillDir("c/skills/x", frontmatter: "---\nname: x\n---\n")

        try SkillOps.trash(skill: skill, targets: [targetLink, targetCopy, targetReal])

        XCTAssertFalse(box.fm.fileExists(atPath: targetLink.dir.appendingPathComponent("x").path),
                       "解析回本体的软链应被删除")
        XCTAssertFalse(box.fm.fileExists(atPath: targetCopy.dir.appendingPathComponent("x").path),
                       "copy 副本应被联动清理")
        XCTAssertTrue(box.fm.fileExists(atPath: realDir.appendingPathComponent("SKILL.md").path),
                      "无标记的真实目录必须保留")
        XCTAssertFalse(box.fm.fileExists(atPath: canonical.path), "本体应已移入废纸篓")
    }

    func testTrashKeepsSymlinkPointingElsewhere() throws {
        let box = try TempSandbox()
        let canonical = try box.makeSkillDir("store/skills/y", frontmatter: "---\nname: y\n---\n")
        let other = try box.makeSkillDir("elsewhere/y", frontmatter: "---\nname: y\n---\n")
        let target = box.makeTarget("agentA", "a/skills")
        let skill = Skill(name: "y", descriptionText: "", version: nil, canonicalPath: canonical)

        // 平台目录里放一个指向别处的同名软链，trash 不应误删
        try box.fm.createDirectory(at: target.dir, withIntermediateDirectories: true)
        let link = target.dir.appendingPathComponent("y")
        try box.fm.createSymbolicLink(atPath: link.path, withDestinationPath: other.path)

        try SkillOps.trash(skill: skill, targets: [target])

        XCTAssertNotNil(try? box.fm.destinationOfSymbolicLink(atPath: link.path),
                        "指向别处的同名软链必须保留")
        XCTAssertTrue(box.fm.fileExists(atPath: other.appendingPathComponent("SKILL.md").path))
        XCTAssertFalse(box.fm.fileExists(atPath: canonical.path), "本体应已移入废纸篓")
    }
}
