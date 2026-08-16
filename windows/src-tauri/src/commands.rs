use crate::models::{AppSnapshot, MutationResult};
use crate::{operations, scanner};
use std::fs::File;
use std::io::Read;
use std::path::PathBuf;

const MAX_MARKDOWN_BYTES: u64 = 256 * 1024;

#[tauri::command]
pub fn get_snapshot() -> Result<AppSnapshot, String> {
    scanner::scan_all()
}

#[tauri::command]
pub fn read_skill_markdown(path: String) -> Result<String, String> {
    let markdown = PathBuf::from(path).join("SKILL.md");
    let file = File::open(&markdown).map_err(|error| format!("无法读取 SKILL.md：{error}"))?;
    let mut content = String::new();
    file.take(MAX_MARKDOWN_BYTES)
        .read_to_string(&mut content)
        .map_err(|error| format!("SKILL.md 不是有效的 UTF-8 文本：{error}"))?;
    Ok(content)
}

#[tauri::command]
pub fn set_skill_enabled(
    skill_path: String,
    target_id: String,
    enabled: bool,
) -> Result<MutationResult, String> {
    operations::set_enabled(&skill_path, &target_id, enabled)
}

#[tauri::command]
pub fn open_in_explorer(path: String) -> Result<(), String> {
    operations::reveal(&path)
}
