use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentTarget {
    pub id: String,
    pub display_name: String,
    pub path: String,
    pub exists: bool,
    pub canonical: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Presence {
    pub target_id: String,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Skill {
    pub id: String,
    pub name: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    pub tags: Vec<String>,
    pub path: String,
    pub file_count: u64,
    pub size_bytes: u64,
    pub has_frontmatter: bool,
    pub has_skill_markdown: bool,
    pub presence: Vec<Presence>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotStats {
    pub total: usize,
    pub active: usize,
    pub unlinked: usize,
    pub broken: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSnapshot {
    pub home: String,
    pub store_path: String,
    pub targets: Vec<AgentTarget>,
    pub skills: Vec<Skill>,
    pub stats: SnapshotStats,
}

#[derive(Debug, Clone, Serialize)]
pub struct MutationResult {
    pub message: String,
}
