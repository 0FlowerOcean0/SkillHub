use crate::models::MutationResult;
use crate::scanner::{is_link_like, known_targets, normalized_path, user_home};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn set_enabled(skill_path: &str, target_id: &str, enabled: bool) -> Result<MutationResult, String> {
    let home = user_home()?;
    let target = known_targets(&home)
        .into_iter()
        .find(|target| target.id == target_id)
        .ok_or_else(|| format!("未知平台：{target_id}"))?;
    if target.canonical {
        return Err("本体库不能作为启用目标".to_string());
    }

    let skill = fs::canonicalize(skill_path).map_err(|error| format!("Skill 路径无效：{error}"))?;
    if !skill.join("SKILL.md").is_file() {
        return Err("目标目录不包含 SKILL.md".to_string());
    }
    let name = skill
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty() && *value != "." && *value != "..")
        .ok_or_else(|| "无法识别 Skill 目录名".to_string())?;

    let target_directory = PathBuf::from(&target.path);
    let entry = target_directory.join(name);

    if enabled {
        fs::create_dir_all(&target_directory).map_err(|error| format!("无法创建平台目录：{error}"))?;
        if entry.exists() || is_link_like(&entry) {
            if is_link_like(&entry) {
                if let Ok(existing_target) = fs::canonicalize(&entry) {
                    if normalized_path(&existing_target) == normalized_path(&skill) {
                        return Ok(MutationResult {
                            message: format!("{name} 已在 {} 启用", target.display_name),
                        });
                    }
                }
                remove_directory_link(&entry)?;
            } else {
                return Err(format!(
                    "{} 已存在同名真实目录，SkillHub 不会覆盖它",
                    target.display_name
                ));
            }
        }
        create_directory_link(&skill, &entry)?;
        Ok(MutationResult {
            message: format!("已将 {name} 启用到 {}", target.display_name),
        })
    } else {
        if !entry.exists() && !is_link_like(&entry) {
            return Ok(MutationResult {
                message: format!("{name} 已处于停用状态"),
            });
        }
        if !is_link_like(&entry) {
            return Err(format!(
                "{} 中的是独立真实目录，SkillHub 不会直接删除",
                target.display_name
            ));
        }
        remove_directory_link(&entry)?;
        Ok(MutationResult {
            message: format!("已从 {} 停用 {name}，本体未被删除", target.display_name),
        })
    }
}

pub fn reveal(path: &str) -> Result<(), String> {
    let target = PathBuf::from(path);
    if !target.exists() {
        return Err("目录不存在".to_string());
    }
    open_directory(&target)
}

#[cfg(windows)]
fn create_directory_link(target: &Path, link: &Path) -> Result<(), String> {
    junction::create(target, link).map_err(|error| format!("创建 Junction 失败：{error}"))
}

#[cfg(not(windows))]
fn create_directory_link(target: &Path, link: &Path) -> Result<(), String> {
    std::os::unix::fs::symlink(target, link).map_err(|error| format!("创建软链接失败：{error}"))
}

#[cfg(windows)]
fn remove_directory_link(link: &Path) -> Result<(), String> {
    let is_junction = junction::exists(link)
        .map_err(|error| format!("无法检查 Junction：{error}"))?;
    if is_junction {
        junction::delete(link).map_err(|error| format!("删除 Junction 失败：{error}"))
    } else {
        fs::remove_dir(link).map_err(|error| format!("删除目录链接失败：{error}"))
    }
}

#[cfg(not(windows))]
fn remove_directory_link(link: &Path) -> Result<(), String> {
    fs::remove_file(link).map_err(|error| format!("删除软链接失败：{error}"))
}

#[cfg(windows)]
fn open_directory(path: &Path) -> Result<(), String> {
    Command::new("explorer")
        .arg(path)
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("无法打开资源管理器：{error}"))
}

#[cfg(target_os = "macos")]
fn open_directory(path: &Path) -> Result<(), String> {
    Command::new("open")
        .arg(path)
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("无法打开 Finder：{error}"))
}

#[cfg(all(not(windows), not(target_os = "macos")))]
fn open_directory(path: &Path) -> Result<(), String> {
    Command::new("xdg-open")
        .arg(path)
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("无法打开文件管理器：{error}"))
}
