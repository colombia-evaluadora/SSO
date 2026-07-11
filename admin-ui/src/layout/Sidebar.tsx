import { useMemo, type ComponentType } from "react";
import { NavLink } from "react-router-dom";
import {
  Box,
  Circle,
  Database,
  FileText,
  FolderTree,
  Layers,
  Network,
  Settings,
  Shield,
  ShieldCheck,
  TriangleAlert,
  Users,
} from "lucide-react";
import { useMyMenu } from "@/hooks/useMyMenu";
import { buildTree, type TreeNode } from "@/lib/buildTree";
import type { RouteResponse } from "@/api/types";

/**
 * Sidebar: navigation for the {@code /admin/**} surface.
 *
 * <p>Previously a hardcoded 12-item list. Now driven by
 * {@code GET /sso-admin/myMenu}, which the backend filters
 * per-caller via
 * {@code RouteRepository.findVisibleForRoles(roleIds)}:
 * non-admin users with route bindings get only the routes
 * they can see; users with no route bindings get an empty
 * list. The SPA renders whatever the backend returns — it
 * does NOT re-implement authorization (which would be a
 * footer-gun).
 *
 * <p>Tree shape is built by
 * {@link buildTree} from {@code idParent}. Today's seed
 * data is a flat structure (every Route has
 * {@code idParent === null}); nested rendering is in place
 * for the day admins group routes under parent entries.
 *
 * <p>Icons: prefer {@code route.icon} (a lucide-react
 * symbol name stored on the Route entity); fall back to a
 * name-keyword heuristic against the current Spanish label
 * so the seed-data sidebar still looks like the previous
 * 12-item design; fall back to a neutral {@code Circle} if
 * nothing matches.
 */
export function Sidebar() {
  const { data, isLoading, isError } = useMyMenu();

  const tree = useMemo<TreeNode<RouteResponse>[]>(() => {
    if (!data) return [];
    return buildTree<RouteResponse>(data, {
      getId: (r) => r.id,
      getParentId: (r) => r.idParent,
      compare: (a, b) =>
        a.menuOrder - b.menuOrder || a.id - b.id,
    });
  }, [data]);

  return (
    <nav
      aria-label="Navegación principal"
      className="w-56 shrink-0 border-r border-slate-200 bg-white"
    >
      {isLoading ? <LoadingSkeleton /> : null}
      {isError ? <ErrorState /> : null}
      {!isLoading && !isError && data && data.length === 0 ? (
        <EmptyState />
      ) : null}
      {!isLoading && !isError && tree.length > 0 ? (
        <ul role="tree" className="p-2">
          {tree.map((node) => (
            <SidebarRow
              key={node.data.id}
              node={node}
              depth={0}
            />
          ))}
        </ul>
      ) : null}
    </nav>
  );
}

/* ============================ rendering ============================ */

interface SidebarRowProps {
  node: TreeNode<RouteResponse>;
  depth: number;
}

function SidebarRow({ node, depth }: SidebarRowProps) {
  const { data, children } = node;
  const Icon = resolveIcon(data.icon, data.name);
  const hasChildren = children.length > 0;

  // Each level adds 12px of left indent — small enough
  // that deep trees stay readable, large enough that the
  // hierarchy is obvious. The NavLink's left padding
  // pushes the icon + label inward to match.
  const indentPx = 8 + depth * 12;

  return (
    <li role="treeitem" aria-expanded={hasChildren ? true : undefined}>
      <NavLink
        to={data.path}
        end={!hasChildren}
        className={({ isActive }) =>
          [
            "flex items-center gap-2 rounded py-2 pr-3 text-sm",
            isActive
              ? "bg-sky-50 font-medium text-sky-700"
              : "text-slate-700 hover:bg-slate-50",
          ].join(" ")
        }
        style={{ paddingLeft: indentPx }}
        aria-label={data.name}
      >
        <Icon className="h-4 w-4 shrink-0" aria-hidden="true" />
        <span className="truncate">{data.name}</span>
      </NavLink>
      {hasChildren ? (
        <ul role="group" className="mt-0.5">
          {children.map((child) => (
            <SidebarRow
              key={child.data.id}
              node={child}
              depth={depth + 1}
            />
          ))}
        </ul>
      ) : null}
    </li>
  );
}

function LoadingSkeleton() {
  // Three pulsing bars — enough to indicate a sidebar is
  // incoming without having to lock in any specific heights.
  return (
    <ul
      role="status"
      aria-label="Cargando menú"
      className="space-y-2 p-2"
    >
      {[0, 1, 2].map((i) => (
        <li
          key={i}
          className="h-7 animate-pulse rounded bg-slate-100"
        />
      ))}
    </ul>
  );
}

function EmptyState() {
  return (
    <div
      role="status"
      aria-label="Sin rutas"
      className="m-2 rounded border border-dashed border-slate-200 p-4 text-center text-xs text-slate-500"
    >
      No tienes rutas asignadas.
    </div>
  );
}

function ErrorState() {
  return (
    <div
      role="alert"
      className="m-2 flex items-start gap-2 rounded border border-red-200 bg-red-50 p-3 text-xs text-red-700"
    >
      <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
      <span>No se pudo cargar el menú.</span>
    </div>
  );
}

/* ============================ icon mapping ============================ */

/**
 * Curated mapping. Two layers:
 *   1. {@code route.icon} (the column on the Route
 *      entity) is the source of truth. Admins populate
 *      it via the RoutesListPage form; whatever value
 *      they store is treated as a lucide-react symbol
 *      name and lowercased before lookup.
 *   2. Spanish-label keyword fallback for the current
 *      seed data (which hasn't been populated with icon
 *      names yet). When the RoutesListPage gets its icon
 *      picker, this fallback becomes redundant and can
 *      be deleted.
 *
 * Unknown names / no keyword match → neutral {@code Circle}
 * so the sidebar always renders a glyph (better than a
 * dead empty cell, which is what a missing svg would look
 * like).
 */
type IconProps = { className?: string };

const ICON_MAP: Record<string, ComponentType<IconProps>> = {
  users: Users,
  shield: Shield,
  shieldcheck: ShieldCheck,
  settings: Settings,
  box: Box,
  network: Network,
  foldertree: FolderTree,
  database: Database,
  filetext: FileText,
  layers: Layers,
  circle: Circle,
};

function resolveIcon(
  iconField: string | null,
  routeName: string,
): ComponentType<IconProps> {
  // Layer 1: explicit icon column.
  if (iconField) {
    const fromColumn = ICON_MAP[iconField.toLowerCase()];
    if (fromColumn) return fromColumn;
  }
  // Layer 2: Spanish-label fallback for seed data.
  const label = routeName.toLowerCase();
  if (label.includes("usuario")) return Users;
  if (label.includes("role") || label.includes("rol")) return ShieldCheck;
  if (label.includes("grupo")) return Users;
  if (label.includes("microservicio") || label.includes("micro")) return Box;
  if (label.includes("query service")) return Database;
  if (label.includes("queries catalog")) return Layers;
  if (label.includes("queries") && label.includes("admin")) return Settings;
  if (label.includes("dynamic")) return FolderTree;
  if (label.includes("endpoint")) return Network;
  if (label.includes("ruta")) return Network;
  if (label.includes("app")) return Layers;
  if (label.includes("write")) return FileText;
  return Circle;
}
