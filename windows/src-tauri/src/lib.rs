mod commands;
mod models;
mod operations;
mod scanner;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            commands::get_snapshot,
            commands::read_skill_markdown,
            commands::set_skill_enabled,
            commands::open_in_explorer,
        ])
        .run(tauri::generate_context!())
        .expect("failed to run SkillHub");
}
