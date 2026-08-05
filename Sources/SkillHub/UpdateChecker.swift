import Foundation

/// Git 更新检测
enum UpdateChecker {

    struct UpdateInfo {
        let skillName: String
        let localCommit: String
        let remoteCommit: String
        let hasUpdate: Bool
    }

    /// 检查单个 skill 是否有更新（fetch + 对比 commit）
    static func check(skill: Skill) -> UpdateInfo? {
        guard let remote = skill.gitRemote, !remote.isEmpty else { return nil }
        guard let localBranch = skill.gitBranch, !localBranch.isEmpty else { return nil }
        guard let localCommit = skill.gitLastCommit else { return nil }

        let dir = skill.canonicalPath
        // 向上找 .git
        var gitRoot = dir
        let fm = FileManager.default
        while gitRoot.path != "/" {
            if fm.fileExists(atPath: gitRoot.appendingPathComponent(".git").path) { break }
            gitRoot = gitRoot.deletingLastPathComponent()
        }
        guard fm.fileExists(atPath: gitRoot.appendingPathComponent(".git").path) else { return nil }

        // fetch
        let fetchResult = runGit(["fetch", "origin", localBranch], in: gitRoot)
        guard fetchResult != nil else { return nil }

        // 获取远程 HEAD commit
        guard let remoteCommit = runGit(["rev-parse", "--short", "origin/\(localBranch)"], in: gitRoot),
              !remoteCommit.isEmpty else { return nil }

        let hasUpdate = localCommit != remoteCommit
        return UpdateInfo(
            skillName: skill.name,
            localCommit: localCommit,
            remoteCommit: remoteCommit,
            hasUpdate: hasUpdate
        )
    }

    /// 批量检查更新
    static func checkAll(skills: [Skill], progress: ((Int, Int) -> Void)? = nil) -> [String: UpdateInfo] {
        var results: [String: UpdateInfo] = [:]
        let gitSkills = skills.filter { $0.gitRemote != nil }
        for (i, skill) in gitSkills.enumerated() {
            progress?(i + 1, gitSkills.count)
            if let info = check(skill: skill) {
                results[skill.id] = info
            }
        }
        return results
    }

    /// 拉取最新代码
    static func pull(skill: Skill) throws {
        let dir = skill.canonicalPath
        let fm = FileManager.default
        var gitRoot = dir
        while gitRoot.path != "/" {
            if fm.fileExists(atPath: gitRoot.appendingPathComponent(".git").path) { break }
            gitRoot = gitRoot.deletingLastPathComponent()
        }
        guard fm.fileExists(atPath: gitRoot.appendingPathComponent(".git").path) else {
            throw UpdateError.notAGitRepo
        }
        guard let branch = skill.gitBranch else {
            throw UpdateError.noBranch
        }
        guard let result = runGit(["pull", "origin", branch], in: gitRoot) else {
            throw UpdateError.pullFailed
        }
    }

    private static func runGit(_ args: [String], in dir: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum UpdateError: LocalizedError {
        case notAGitRepo
        case noBranch
        case pullFailed
        var errorDescription: String? {
            switch self {
            case .notAGitRepo: return "不是一个 git 仓库"
            case .noBranch: return "无法确定当前分支"
            case .pullFailed: return "git pull 失败"
            }
        }
    }
}
