export type PresenceKind = "real" | "junction" | "broken";

export interface Presence {
  targetId: string;
  kind: PresenceKind;
}

export interface AgentTarget {
  id: string;
  displayName: string;
  path: string;
  exists: boolean;
  canonical: boolean;
}

export interface Skill {
  id: string;
  name: string;
  description: string;
  version?: string;
  author?: string;
  tags: string[];
  path: string;
  fileCount: number;
  sizeBytes: number;
  hasFrontmatter: boolean;
  hasSkillMarkdown: boolean;
  presence: Presence[];
}

export interface SnapshotStats {
  total: number;
  active: number;
  unlinked: number;
  broken: number;
}

export interface AppSnapshot {
  home: string;
  storePath: string;
  targets: AgentTarget[];
  skills: Skill[];
  stats: SnapshotStats;
}

export interface MutationResult {
  message: string;
}
