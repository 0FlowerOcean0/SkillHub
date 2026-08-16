import { invoke } from "@tauri-apps/api/core";
import type { AppSnapshot, MutationResult } from "./types";

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown;
  }
}

const demoSnapshot: AppSnapshot = {
  home: "C:\\Users\\FlowerOcean",
  storePath: "C:\\Users\\FlowerOcean\\.agents\\skills",
  targets: [
    { id: "agents", displayName: "本体库 (.agents)", path: "C:\\Users\\FlowerOcean\\.agents\\skills", exists: true, canonical: true },
    { id: "claude", displayName: "Claude Code", path: "C:\\Users\\FlowerOcean\\.claude\\skills", exists: true, canonical: false },
    { id: "codex", displayName: "Codex", path: "C:\\Users\\FlowerOcean\\.codex\\skills", exists: true, canonical: false },
    { id: "cursor", displayName: "Cursor", path: "C:\\Users\\FlowerOcean\\.cursor\\skills", exists: false, canonical: false },
  ],
  skills: [
    {
      id: "demo-1",
      name: "frontend-design",
      description: "为产品界面提供克制、清晰且可落地的视觉设计规范。",
      author: "anthropics",
      tags: ["design", "frontend"],
      path: "C:\\Users\\FlowerOcean\\.agents\\skills\\frontend-design",
      fileCount: 5,
      sizeBytes: 18432,
      hasFrontmatter: true,
      hasSkillMarkdown: true,
      presence: [{ targetId: "agents", kind: "real" }, { targetId: "claude", kind: "junction" }, { targetId: "codex", kind: "junction" }],
    },
    {
      id: "demo-2",
      name: "skill-creator",
      description: "创建、审查并迭代高质量 Agent Skill。",
      author: "OpenAI",
      tags: ["skills", "workflow"],
      path: "C:\\Users\\FlowerOcean\\.agents\\skills\\skill-creator",
      fileCount: 9,
      sizeBytes: 46120,
      hasFrontmatter: true,
      hasSkillMarkdown: true,
      presence: [{ targetId: "agents", kind: "real" }, { targetId: "codex", kind: "junction" }],
    },
    {
      id: "demo-3",
      name: "research-notes",
      description: "把分散资料整理为有来源、可追踪的研究笔记。",
      author: "花海",
      tags: ["research", "writing"],
      path: "C:\\Users\\FlowerOcean\\.agents\\skills\\research-notes",
      fileCount: 3,
      sizeBytes: 9240,
      hasFrontmatter: true,
      hasSkillMarkdown: true,
      presence: [{ targetId: "agents", kind: "real" }],
    },
  ],
  stats: { total: 3, active: 2, unlinked: 1, broken: 0 },
};

const inTauri = () => typeof window !== "undefined" && Boolean(window.__TAURI_INTERNALS__);

export async function getSnapshot(): Promise<AppSnapshot> {
  return inTauri() ? invoke<AppSnapshot>("get_snapshot") : demoSnapshot;
}

export async function readSkillMarkdown(path: string): Promise<string> {
  if (!inTauri()) {
    return `---\nname: frontend-design\ndescription: 为产品界面提供克制、清晰且可落地的视觉设计规范。\ntags: [design, frontend]\n---\n\n# 使用说明\n\n保持清楚的层级、可靠的交互和可验证的结果。`;
  }
  return invoke<string>("read_skill_markdown", { path });
}

export async function setSkillEnabled(skillPath: string, targetId: string, enabled: boolean): Promise<MutationResult> {
  if (!inTauri()) {
    return { message: enabled ? "已启用（界面预览）" : "已停用（界面预览）" };
  }
  return invoke<MutationResult>("set_skill_enabled", { skillPath, targetId, enabled });
}

export async function openInExplorer(path: string): Promise<void> {
  if (inTauri()) {
    await invoke("open_in_explorer", { path });
  }
}
