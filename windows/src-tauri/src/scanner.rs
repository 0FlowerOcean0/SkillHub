use crate::models::{AgentTarget, AppSnapshot, Presence, Skill, SnapshotStats};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Default)]
struct ParsedFrontmatter {
    name: Option<String>,
    description: Option<String>,
    version: Option<String>,
    author: Option<String>,
    tags: Vec<String>,
    valid: bool,
}

pub fn user_home() -> Result<PathBuf, String> {
    env::var_os("USERPROFILE")
        .or_else(|| env::var_os("HOME"))
        .map(PathBuf::from)
        .ok_or_else(|| "无法确定当前用户目录".to_string())
}

pub fn known_targets(home: &Path) -> Vec<AgentTarget> {
    let specs = [
        ("agents", "本体库 (.agents)", ".agents/skills", true, true),
        ("claude", "Claude Code", ".claude/skills", false, true),
        ("codex", "Codex", ".codex/skills", false, true),
        ("cursor", "Cursor", ".cursor/skills", false, false),
        ("cline", "Cline", ".cline/skills", false, false),
        ("windsurf", "Windsurf", ".windsurf/skills", false, false),
        ("roo", "Roo Code", ".roo/skills", false, false),
        ("continue", "Continue", ".continue/skills", false, false),
    ];

    specs
        .into_iter()
        .filter_map(|(id, display_name, relative, canonical, always_show)| {
            let path = join_relative(home, relative);
            if always_show || path.exists() || path.parent().is_some_and(Path::exists) {
                Some(AgentTarget {
                    id: id.to_string(),
                    display_name: display_name.to_string(),
                    path: path.to_string_lossy().into_owned(),
                    exists: path.is_dir(),
                    canonical,
                })
            } else {
                None
            }
        })
        .collect()
}

pub fn scan_all() -> Result<AppSnapshot, String> {
    let home = user_home()?;
    let targets = known_targets(&home);
    let mut skills_by_path: HashMap<String, Skill> = HashMap::new();

    for target in &targets {
        let target_path = PathBuf::from(&target.path);
        let Ok(entries) = fs::read_dir(&target_path) else {
            continue;
        };

        let mut entries = entries.filter_map(Result::ok).collect::<Vec<_>>();
        entries.sort_by_key(|entry| entry.file_name().to_string_lossy().to_lowercase());

        for entry in entries {
            let entry_path = entry.path();
            let link_like = is_link_like(&entry_path);
            let resolved = fs::canonicalize(&entry_path);
            let (skill_path, presence_kind) = match resolved {
                Ok(path) if path.is_dir() => {
                    let kind = if link_like { "junction" } else { "real" };
                    (path, kind)
                }
                _ if link_like => (entry_path.clone(), "broken"),
                _ => continue,
            };

            let markdown = skill_path.join("SKILL.md");
            if presence_kind != "broken" && !markdown.is_file() {
                continue;
            }

            let key = if presence_kind == "broken" {
                format!("broken:{}", normalized_path(&entry_path))
            } else {
                normalized_path(&skill_path)
            };

            let skill = skills_by_path.entry(key).or_insert_with(|| make_skill(&skill_path));
            if !skill.presence.iter().any(|item| item.target_id == target.id) {
                skill.presence.push(Presence {
                    target_id: target.id.clone(),
                    kind: presence_kind.to_string(),
                });
            }
        }
    }

    let mut skills = skills_by_path.into_values().collect::<Vec<_>>();
    skills.sort_by(|left, right| {
        left.name
            .to_lowercase()
            .cmp(&right.name.to_lowercase())
            .then_with(|| left.path.cmp(&right.path))
    });

    let active = skills
        .iter()
        .filter(|skill| {
            skill
                .presence
                .iter()
                .any(|item| item.target_id != "agents" && item.kind != "broken")
        })
        .count();
    let unlinked = skills
        .iter()
        .filter(|skill| {
            !skill
                .presence
                .iter()
                .any(|item| item.target_id != "agents" && item.kind != "broken")
        })
        .count();
    let broken = skills
        .iter()
        .flat_map(|skill| &skill.presence)
        .filter(|item| item.kind == "broken")
        .count();
    let store_path = home.join(".agents").join("skills");

    Ok(AppSnapshot {
        home: home.to_string_lossy().into_owned(),
        store_path: store_path.to_string_lossy().into_owned(),
        stats: SnapshotStats {
            total: skills.len(),
            active,
            unlinked,
            broken,
        },
        targets,
        skills,
    })
}

pub(crate) fn is_link_like(path: &Path) -> bool {
    #[cfg(windows)]
    {
        junction::exists(path)
            || fs::symlink_metadata(path)
                .map(|metadata| metadata.file_type().is_symlink())
                .unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        fs::symlink_metadata(path)
            .map(|metadata| metadata.file_type().is_symlink())
            .unwrap_or(false)
    }
}

pub(crate) fn normalized_path(path: &Path) -> String {
    let raw = path.to_string_lossy().replace('/', "\\");
    raw.strip_prefix(r"\\?\")
        .unwrap_or(&raw)
        .trim_end_matches('\\')
        .to_lowercase()
}

fn join_relative(home: &Path, relative: &str) -> PathBuf {
    relative
        .split('/')
        .fold(home.to_path_buf(), |path, component| path.join(component))
}

fn make_skill(path: &Path) -> Skill {
    let markdown_path = path.join("SKILL.md");
    let content = fs::read_to_string(&markdown_path).unwrap_or_default();
    let parsed = parse_frontmatter(&content);
    let fallback_name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unknown-skill".to_string());
    let (file_count, size_bytes) = summarize_directory(path);

    Skill {
        id: normalized_path(path),
        name: parsed.name.unwrap_or(fallback_name),
        description: parsed.description.unwrap_or_default(),
        version: parsed.version,
        author: parsed.author,
        tags: parsed.tags,
        path: path.to_string_lossy().into_owned(),
        file_count,
        size_bytes,
        has_frontmatter: parsed.valid,
        has_skill_markdown: markdown_path.is_file(),
        presence: Vec::new(),
    }
}

fn parse_frontmatter(content: &str) -> ParsedFrontmatter {
    let lines = content.trim_start_matches('\u{feff}').lines().collect::<Vec<_>>();
    if lines.first().map(|line| line.trim()) != Some("---") {
        return ParsedFrontmatter::default();
    }

    let mut result = ParsedFrontmatter::default();
    let mut index = 1;
    while index < lines.len() {
        let line = lines[index];
        if line.trim() == "---" {
            result.valid = true;
            break;
        }
        let Some((raw_key, raw_value)) = line.split_once(':') else {
            index += 1;
            continue;
        };
        let key = raw_key.trim();
        let value = raw_value.trim();
        match key {
            "name" => result.name = clean_value(value),
            "description" | "summary" if value == "|" || value == ">" => {
                let mut parts = Vec::new();
                index += 1;
                while index < lines.len() && (lines[index].starts_with(' ') || lines[index].starts_with('\t')) {
                    let part = lines[index].trim();
                    if !part.is_empty() {
                        parts.push(part);
                    }
                    index += 1;
                }
                if !parts.is_empty() {
                    result.description = Some(parts.join(" "));
                }
                continue;
            }
            "description" | "summary" => {
                if result.description.is_none() {
                    result.description = clean_value(value);
                }
            }
            "version" => result.version = clean_value(value),
            "author" => result.author = clean_value(value),
            "tags" => result.tags = parse_tags(value),
            _ => {}
        }
        index += 1;
    }
    result
}

fn clean_value(value: &str) -> Option<String> {
    let cleaned = value
        .trim()
        .trim_matches(|character| character == '"' || character == '\'')
        .trim();
    (!cleaned.is_empty()).then(|| cleaned.to_string())
}

fn parse_tags(value: &str) -> Vec<String> {
    value
        .trim()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .split(',')
        .filter_map(clean_value)
        .collect()
}

fn summarize_directory(root: &Path) -> (u64, u64) {
    let mut stack = vec![root.to_path_buf()];
    let mut count = 0_u64;
    let mut bytes = 0_u64;

    while let Some(directory) = stack.pop() {
        let Ok(entries) = fs::read_dir(directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                continue;
            };
            if metadata.is_dir() && !is_link_like(&path) {
                stack.push(path);
            } else if metadata.is_file() {
                count = count.saturating_add(1);
                bytes = bytes.saturating_add(metadata.len());
            }
            if count >= 20_000 {
                return (count, bytes);
            }
        }
    }
    (count, bytes)
}

#[cfg(test)]
mod tests {
    use super::{parse_frontmatter, parse_tags};

    #[test]
    fn parses_frontmatter_fields() {
        let parsed = parse_frontmatter(
            "---\nname: test-skill\ndescription: \"A useful skill\"\nversion: 1.2.0\nauthor: 花海\ntags: [writing, research]\n---\n# Body",
        );
        assert!(parsed.valid);
        assert_eq!(parsed.name.as_deref(), Some("test-skill"));
        assert_eq!(parsed.description.as_deref(), Some("A useful skill"));
        assert_eq!(parsed.version.as_deref(), Some("1.2.0"));
        assert_eq!(parsed.author.as_deref(), Some("花海"));
        assert_eq!(parsed.tags, vec!["writing", "research"]);
    }

    #[test]
    fn parses_folded_description() {
        let parsed = parse_frontmatter("---\nname: test\ndescription: >\n  first line\n  second line\n---");
        assert_eq!(parsed.description.as_deref(), Some("first line second line"));
    }

    #[test]
    fn parses_empty_tags() {
        assert!(parse_tags("[]").is_empty());
    }
}
