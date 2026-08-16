import {
  Archive,
  Box,
  Check,
  CircleAlert,
  FolderOpen,
  Heart,
  Library,
  Link2,
  RefreshCw,
  Search,
  ShieldCheck,
  Unlink,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSnapshot, openInExplorer, readSkillMarkdown, setSkillEnabled } from "./api";
import { cn } from "./lib/cn";
import type { AgentTarget, AppSnapshot, PresenceKind, Skill } from "./types";

type Filter = "all" | "favorites" | "active" | "unlinked";
type Notice = { kind: "success" | "error"; message: string };

const focusRing = "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 focus-visible:ring-offset-1";

function formatBytes(value: number) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  return `${(value / 1024 / 1024).toFixed(1)} MB`;
}

function isActive(skill: Skill) {
  return skill.presence.some((item) => item.targetId !== "agents" && item.kind !== "broken");
}

function presenceFor(skill: Skill, targetId: string) {
  return skill.presence.find((item) => item.targetId === targetId);
}

function SidebarButton({
  active,
  icon,
  label,
  count,
  onClick,
}: {
  active: boolean;
  icon: React.ReactNode;
  label: string;
  count: number;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-sm",
        focusRing,
        active ? "bg-blue-50 font-medium text-blue-700" : "text-slate-600 hover:bg-slate-100 hover:text-slate-900",
      )}
    >
      {icon}
      <span className="min-w-0 flex-1 truncate">{label}</span>
      <span className="tabular-nums text-xs text-slate-400">{count}</span>
    </button>
  );
}

function Metric({ value, label, tone = "default" }: { value: number; label: string; tone?: "default" | "warning" }) {
  return (
    <div className="min-w-0">
      <div className={cn("tabular-nums text-xl font-semibold", tone === "warning" ? "text-amber-700" : "text-slate-900")}>
        {value}
      </div>
      <div className="mt-0.5 truncate text-xs text-slate-500">{label}</div>
    </div>
  );
}

function StatusDot({ kind }: { kind?: PresenceKind }) {
  return (
    <span
      className={cn(
        "size-2 rounded-full",
        kind === "junction" && "bg-emerald-500",
        kind === "real" && "bg-blue-500",
        kind === "broken" && "bg-amber-500",
        !kind && "bg-slate-300",
      )}
    />
  );
}

function LoadingView() {
  return (
    <div className="grid h-dvh grid-cols-[220px_340px_minmax(420px,1fr)] bg-slate-50" aria-label="正在扫描 skills">
      <div className="border-r border-slate-200 bg-white p-4">
        <div className="h-10 rounded-md bg-slate-100" />
        <div className="mt-8 space-y-2">
          {Array.from({ length: 5 }, (_, index) => (
            <div key={index} className="h-9 rounded-md bg-slate-100" />
          ))}
        </div>
      </div>
      <div className="border-r border-slate-200 bg-white p-4">
        <div className="h-20 rounded-md bg-slate-100" />
        <div className="mt-5 space-y-3">
          {Array.from({ length: 6 }, (_, index) => (
            <div key={index} className="h-20 rounded-md bg-slate-100" />
          ))}
        </div>
      </div>
      <div className="p-6">
        <div className="h-52 rounded-lg bg-white shadow-sm ring-1 ring-slate-200" />
      </div>
    </div>
  );
}

function NoticeBar({ notice, onClose }: { notice: Notice; onClose: () => void }) {
  return (
    <div
      role={notice.kind === "error" ? "alert" : "status"}
      className={cn(
        "flex items-center gap-2 border-b px-4 py-2.5 text-sm",
        notice.kind === "error"
          ? "border-red-200 bg-red-50 text-red-700"
          : "border-emerald-200 bg-emerald-50 text-emerald-700",
      )}
    >
      {notice.kind === "error" ? <CircleAlert className="size-4" /> : <Check className="size-4" />}
      <span className="min-w-0 flex-1 text-pretty">{notice.message}</span>
      <button type="button" onClick={onClose} aria-label="关闭提示" className={cn("rounded p-1 hover:bg-black/5", focusRing)}>
        <X className="size-4" />
      </button>
    </div>
  );
}

export function App() {
  const [snapshot, setSnapshot] = useState<AppSnapshot | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>("all");
  const [query, setQuery] = useState("");
  const [markdown, setMarkdown] = useState("");
  const [loadingMarkdown, setLoadingMarkdown] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [busyTarget, setBusyTarget] = useState<string | null>(null);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [favorites, setFavorites] = useState<Set<string>>(() => {
    try {
      return new Set(JSON.parse(localStorage.getItem("skillhub.windows.favorites") ?? "[]") as string[]);
    } catch {
      return new Set();
    }
  });

  const refresh = useCallback(async (showBusy = true) => {
    if (showBusy) setRefreshing(true);
    try {
      const next = await getSnapshot();
      setSnapshot(next);
      setSelectedId((current) => (current && next.skills.some((skill) => skill.id === current) ? current : next.skills[0]?.id ?? null));
    } catch (error) {
      setNotice({ kind: "error", message: error instanceof Error ? error.message : String(error) });
    } finally {
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    void refresh(false);
  }, [refresh]);

  useEffect(() => {
    localStorage.setItem("skillhub.windows.favorites", JSON.stringify([...favorites]));
  }, [favorites]);

  const filteredSkills = useMemo(() => {
    if (!snapshot) return [];
    const needle = query.trim().toLocaleLowerCase();
    return snapshot.skills.filter((skill) => {
      const matchesFilter =
        filter === "all" ||
        (filter === "favorites" && favorites.has(skill.id)) ||
        (filter === "active" && isActive(skill)) ||
        (filter === "unlinked" && !isActive(skill));
      if (!matchesFilter) return false;
      if (!needle) return true;
      return [skill.name, skill.description, skill.author ?? "", ...skill.tags]
        .join(" ")
        .toLocaleLowerCase()
        .includes(needle);
    });
  }, [favorites, filter, query, snapshot]);

  const selected = useMemo(
    () => snapshot?.skills.find((skill) => skill.id === selectedId) ?? null,
    [selectedId, snapshot],
  );

  useEffect(() => {
    if (!selected) {
      setMarkdown("");
      return;
    }
    let cancelled = false;
    setLoadingMarkdown(true);
    readSkillMarkdown(selected.path)
      .then((content) => {
        if (!cancelled) setMarkdown(content);
      })
      .catch((error) => {
        if (!cancelled) setMarkdown(`无法读取 SKILL.md：${error instanceof Error ? error.message : String(error)}`);
      })
      .finally(() => {
        if (!cancelled) setLoadingMarkdown(false);
      });
    return () => {
      cancelled = true;
    };
  }, [selected]);

  if (!snapshot) return <LoadingView />;

  const platformTargets = snapshot.targets.filter((target) => !target.canonical);

  const toggleFavorite = (skill: Skill) => {
    setFavorites((current) => {
      const next = new Set(current);
      if (next.has(skill.id)) next.delete(skill.id);
      else next.add(skill.id);
      return next;
    });
  };

  const changeTarget = async (skill: Skill, target: AgentTarget, enable: boolean) => {
    setBusyTarget(target.id);
    setNotice(null);
    try {
      const result = await setSkillEnabled(skill.path, target.id, enable);
      setNotice({ kind: "success", message: result.message });
      await refresh(false);
    } catch (error) {
      setNotice({ kind: "error", message: error instanceof Error ? error.message : String(error) });
    } finally {
      setBusyTarget(null);
    }
  };

  return (
    <main className="grid h-dvh min-w-[1040px] grid-cols-[220px_340px_minmax(420px,1fr)] overflow-hidden bg-slate-50">
      <aside className="flex min-h-0 flex-col border-r border-slate-200 bg-white">
        <div className="flex items-center gap-3 border-b border-slate-200 px-4 py-4">
          <img src="/skillhub-icon.png" alt="" className="size-9 rounded-lg" />
          <div className="min-w-0">
            <h1 className="truncate text-base font-semibold text-slate-900">SkillHub</h1>
            <p className="truncate text-xs text-slate-500">Windows Preview</p>
          </div>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto px-3 py-4">
          <p className="px-2.5 pb-2 text-xs font-medium text-slate-400">快速查看</p>
          <nav className="space-y-1" aria-label="技能筛选">
            <SidebarButton
              active={filter === "all"}
              icon={<Library className="size-4" />}
              label="全部 Skills"
              count={snapshot.stats.total}
              onClick={() => setFilter("all")}
            />
            <SidebarButton
              active={filter === "favorites"}
              icon={<Heart className="size-4" />}
              label="收藏"
              count={favorites.size}
              onClick={() => setFilter("favorites")}
            />
            <SidebarButton
              active={filter === "active"}
              icon={<Link2 className="size-4" />}
              label="已启用"
              count={snapshot.stats.active}
              onClick={() => setFilter("active")}
            />
            <SidebarButton
              active={filter === "unlinked"}
              icon={<Unlink className="size-4" />}
              label="仅在本体库"
              count={snapshot.stats.unlinked}
              onClick={() => setFilter("unlinked")}
            />
          </nav>

          <div className="mt-7 flex items-center justify-between px-2.5 pb-2">
            <p className="text-xs font-medium text-slate-400">Agent 平台</p>
            <span className="tabular-nums text-xs text-slate-400">{platformTargets.length}</span>
          </div>
          <div className="space-y-1">
            {platformTargets.map((target) => {
              const count = snapshot.skills.filter((skill) => presenceFor(skill, target.id)?.kind !== undefined).length;
              return (
                <div key={target.id} className="flex items-center gap-2.5 rounded-md px-2.5 py-2 text-sm text-slate-600">
                  <span className={cn("size-2 rounded-full", target.exists ? "bg-emerald-500" : "bg-slate-300")} />
                  <span className="min-w-0 flex-1 truncate">{target.displayName}</span>
                  <span className="tabular-nums text-xs text-slate-400">{count}</span>
                </div>
              );
            })}
          </div>
        </div>

        <div className="border-t border-slate-200 p-3">
          <button
            type="button"
            onClick={() => void openInExplorer(snapshot.storePath)}
            className={cn(
              "flex w-full items-center gap-2 rounded-md px-2.5 py-2 text-left text-xs text-slate-500 hover:bg-slate-100 hover:text-slate-800",
              focusRing,
            )}
          >
            <FolderOpen className="size-4" />
            <span className="min-w-0 flex-1 truncate">打开本体库</span>
          </button>
        </div>
      </aside>

      <section className="flex min-h-0 flex-col border-r border-slate-200 bg-white" aria-label="Skills 列表">
        <header className="border-b border-slate-200 px-4 pb-4 pt-4">
          <div className="grid grid-cols-4 gap-3">
            <Metric value={snapshot.stats.total} label="总数" />
            <Metric value={snapshot.stats.active} label="已启用" />
            <Metric value={snapshot.stats.unlinked} label="待同步" />
            <Metric value={snapshot.stats.broken} label="断链" tone={snapshot.stats.broken > 0 ? "warning" : "default"} />
          </div>
          <label className="relative mt-4 block">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
            <span className="sr-only">搜索 skills</span>
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="搜索名称、描述、标签或作者"
              className={cn(
                "h-9 w-full rounded-md border border-slate-200 bg-slate-50 pl-9 pr-3 text-sm text-slate-900 placeholder:text-slate-400",
                focusRing,
              )}
            />
          </label>
        </header>

        <div className="flex items-center justify-between border-b border-slate-100 px-4 py-2.5">
          <span className="text-xs text-slate-500">
            当前显示 <span className="tabular-nums font-medium text-slate-700">{filteredSkills.length}</span> 项
          </span>
          <button
            type="button"
            onClick={() => void refresh()}
            disabled={refreshing}
            className={cn(
              "inline-flex items-center gap-1.5 rounded-md px-2 py-1.5 text-xs font-medium text-slate-600 hover:bg-slate-100 disabled:opacity-50",
              focusRing,
            )}
          >
            <RefreshCw className="size-3.5" />
            {refreshing ? "扫描中" : "刷新"}
          </button>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto">
          {filteredSkills.length === 0 ? (
            <div className="flex h-full flex-col items-center justify-center px-8 text-center">
              <Archive className="size-9 text-slate-300" />
              <h2 className="mt-3 text-balance text-sm font-semibold text-slate-700">没有找到匹配的 Skill</h2>
              <p className="mt-1 text-pretty text-xs leading-5 text-slate-500">清空搜索条件，或重新扫描本体库。</p>
              <button
                type="button"
                onClick={() => {
                  setQuery("");
                  setFilter("all");
                  void refresh();
                }}
                className={cn("mt-4 rounded-md bg-blue-600 px-3 py-2 text-xs font-medium text-white hover:bg-blue-700", focusRing)}
              >
                重新扫描
              </button>
            </div>
          ) : (
            <div className="divide-y divide-slate-100">
              {filteredSkills.map((skill) => {
                const activeTargets = skill.presence.filter((item) => item.targetId !== "agents" && item.kind !== "broken").length;
                return (
                  <button
                    key={skill.id}
                    type="button"
                    onClick={() => setSelectedId(skill.id)}
                    className={cn(
                      "block w-full px-4 py-3 text-left",
                      focusRing,
                      selectedId === skill.id ? "bg-blue-50" : "bg-white hover:bg-slate-50",
                    )}
                  >
                    <div className="flex items-start gap-3">
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2">
                          <span className="truncate text-sm font-semibold text-slate-900">{skill.name}</span>
                          {favorites.has(skill.id) && <Heart className="size-3.5 shrink-0 fill-blue-600 text-blue-600" />}
                        </div>
                        <p className="mt-1 line-clamp-2 text-pretty text-xs leading-5 text-slate-500">
                          {skill.description || "暂无描述"}
                        </p>
                        <div className="mt-2 flex items-center gap-1.5 overflow-hidden">
                          {skill.tags.slice(0, 3).map((tag) => (
                            <span key={tag} className="truncate rounded bg-slate-100 px-1.5 py-0.5 text-[11px] text-slate-500">
                              {tag}
                            </span>
                          ))}
                        </div>
                      </div>
                      <div className="flex shrink-0 items-center gap-1 text-xs text-slate-400">
                        <Link2 className="size-3.5" />
                        <span className="tabular-nums">{activeTargets}</span>
                      </div>
                    </div>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </section>

      <section className="flex min-h-0 flex-col bg-slate-50" aria-label="Skill 详情">
        {notice && <NoticeBar notice={notice} onClose={() => setNotice(null)} />}
        {!selected ? (
          <div className="flex h-full flex-col items-center justify-center text-center">
            <Box className="size-10 text-slate-300" />
            <h2 className="mt-3 text-balance text-base font-semibold text-slate-700">选择一个 Skill 查看详情</h2>
          </div>
        ) : (
          <>
            <header className="border-b border-slate-200 bg-white px-6 py-5">
              <div className="flex items-start gap-4">
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <h2 className="truncate text-balance text-xl font-semibold text-slate-950">{selected.name}</h2>
                    {selected.hasFrontmatter ? (
                      <span title="frontmatter 完整"><ShieldCheck className="size-4 text-emerald-600" /></span>
                    ) : (
                      <span title="缺少 frontmatter"><CircleAlert className="size-4 text-amber-600" /></span>
                    )}
                  </div>
                  <p className="mt-2 max-w-3xl text-pretty text-sm leading-6 text-slate-600">
                    {selected.description || "这个 Skill 暂时没有 description。"}
                  </p>
                  <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-slate-500">
                    <span className="tabular-nums">{selected.fileCount} 个文件</span>
                    <span className="tabular-nums">{formatBytes(selected.sizeBytes)}</span>
                    {selected.author && <span className="truncate">作者：{selected.author}</span>}
                    {selected.version && <span className="tabular-nums">v{selected.version}</span>}
                  </div>
                </div>
                <button
                  type="button"
                  onClick={() => toggleFavorite(selected)}
                  aria-label={favorites.has(selected.id) ? "取消收藏" : "收藏"}
                  className={cn(
                    "rounded-md border border-slate-200 bg-white p-2 text-slate-500 hover:bg-slate-50 hover:text-blue-600",
                    focusRing,
                  )}
                >
                  <Heart className={cn("size-4", favorites.has(selected.id) && "fill-blue-600 text-blue-600")} />
                </button>
              </div>

              <button
                type="button"
                onClick={() => void openInExplorer(selected.path)}
                className={cn(
                  "mt-4 flex max-w-full items-center gap-2 rounded-md bg-slate-50 px-2.5 py-2 text-left text-xs text-slate-500 hover:bg-slate-100 hover:text-slate-700",
                  focusRing,
                )}
              >
                <FolderOpen className="size-4 shrink-0" />
                <span className="truncate">{selected.path}</span>
              </button>
            </header>

            <div className="min-h-0 flex-1 overflow-y-auto p-6">
              <section className="rounded-lg bg-white shadow-sm ring-1 ring-slate-200">
                <div className="flex items-center justify-between border-b border-slate-200 px-4 py-3">
                  <div>
                    <h3 className="text-sm font-semibold text-slate-900">平台状态</h3>
                    <p className="mt-0.5 text-pretty text-xs text-slate-500">Windows 使用目录 Junction，共享同一份 Skill 本体。</p>
                  </div>
                </div>
                <div className="divide-y divide-slate-100">
                  {platformTargets.map((target) => {
                    const presence = presenceFor(selected, target.id);
                    const enabled = presence?.kind === "junction" || presence?.kind === "real";
                    const protectedCopy = presence?.kind === "real";
                    return (
                      <div key={target.id} className="flex items-center gap-3 px-4 py-3">
                        <StatusDot kind={presence?.kind} />
                        <div className="min-w-0 flex-1">
                          <div className="flex items-center gap-2">
                            <span className="truncate text-sm font-medium text-slate-800">{target.displayName}</span>
                            {!target.exists && !enabled && (
                              <span className="rounded bg-slate-100 px-1.5 py-0.5 text-[11px] text-slate-500">目录未创建</span>
                            )}
                          </div>
                          <p className="mt-0.5 truncate text-xs text-slate-400">{target.path}</p>
                        </div>
                        <button
                          type="button"
                          aria-pressed={enabled}
                          disabled={busyTarget !== null || protectedCopy}
                          title={protectedCopy ? "这是独立真实目录，SkillHub 不会直接删除" : undefined}
                          onClick={() => void changeTarget(selected, target, !enabled)}
                          className={cn(
                            "min-w-20 rounded-md border px-3 py-1.5 text-xs font-medium disabled:cursor-not-allowed disabled:opacity-50",
                            focusRing,
                            enabled
                              ? "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"
                              : "border-blue-600 bg-blue-600 text-white hover:bg-blue-700",
                          )}
                        >
                          {busyTarget === target.id
                            ? "处理中"
                            : protectedCopy
                              ? "独立副本"
                              : presence?.kind === "broken"
                                ? "修复"
                                : enabled
                                  ? "停用"
                                  : "启用"}
                        </button>
                      </div>
                    );
                  })}
                </div>
              </section>

              <section className="mt-5 overflow-hidden rounded-lg bg-white shadow-sm ring-1 ring-slate-200">
                <div className="flex items-center justify-between border-b border-slate-200 px-4 py-3">
                  <h3 className="text-sm font-semibold text-slate-900">SKILL.md</h3>
                  <span className="text-xs text-slate-400">{loadingMarkdown ? "读取中" : "只读预览"}</span>
                </div>
                <pre className="max-h-[520px] overflow-auto whitespace-pre-wrap break-words px-4 py-4 font-mono text-xs leading-6 text-slate-600">
                  {loadingMarkdown ? "正在读取…" : markdown}
                </pre>
              </section>
            </div>
          </>
        )}
      </section>
    </main>
  );
}
