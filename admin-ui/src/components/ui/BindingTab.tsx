import { useMemo, useState, type ReactNode } from "react";
import { Button } from "@/components/ui/Button";

/**
 * Bulk-action descriptor. When the caller passes a
 * {@link BindingTabProps.bulkAction}, the toolbar renders two
 * extra buttons (bind + unbind) that apply to the currently
 * {@link filterMode}-visible rows in one shot. Used to mass-bind
 * roles on a freshly created app, or to clean up "orphaned"
 * routes an app no longer talks to.
 */
export interface BulkAction {
  /** Label of the "bind all visible" button. Example:
   *  {@code "Vincular visibles"}. */
  bindLabel: string;
  /** Label of the "unbind all visible" button. Example:
   *  {@code "Desvincular visibles"}. */
  unbindLabel: string;
  /** Called with the list of row ids currently visible AFTER
   *  the search filter is applied. The caller dispatches the
   *  bind/unbind mutations; the toolbar stays generic. */
  onApply: (
    rowIds: number[],
    action: "bind" | "unbind",
  ) => void;
  /** Test id prefix for the two bulk buttons. The bind button
   *  gets {@code ${testIdPrefix}-bind}, the unbind button
   *  {@code ${testIdPrefix}-unbind}. Lets tests target one or
   *  the other without coupling to the label string. */
  testIdPrefix: string;
}

/**
 * Generic checked-list renderer used by every binding tab
 * across the admin UI (App × 4 families + Write × 1 family).
 *
 * <p>Lives in {@code components/ui} (not {@code pages/*})
 * because the same shape is shared by Apps (4 binding tab
 * variants) and Writes (1 variant). Lift it out so future
 * entities with M:N bindings can reuse it without copy-paste.
 *
 * <p>The differences between binding families are parameterized:
 * <ul>
 *   <li>{@link getRowId} — each row has its id under a different
 *       field name (roleId / userId / routeId / microserviceId).
 *       Accepting a getter keeps this generic over the row
 *       type without forcing a common interface.</li>
 *   <li>{@link getRowChecked} — same idea; pulls the bound
 *       boolean out of the row.</li>
 *   <li>{@link renderRow} — the label the user sees per row
 *       (just {@code r.name} for roles, or
 *       {@code name + path} for routes, etc.).</li>
 *   <li>{@link onToggle} — POST vs DELETE depending on the
 *       current {@code checked} flag. The page knows the URL
 *       shape; this component just plumbs the click.</li>
 *   <li>{@link listTestIdPrefix} — defaults to {@code "bindings"}
 *       so legacy test code that hardcoded
 *       {@code app-bindings-{id}} keeps working when callers
 *       pass {@code "app-bindings"}. The Writes drawer passes
 *       {@code "write-bindings"}.</li>
 * </ul>
 *
 * <p>The prop is named {@code entityId} (not {@code appId}) so
 * the type doesn't lie about the use site — Writers pass a
 * write id, Microservices (potential future) would pass a
 * microservice id, etc.
 *
 * <p><b>Tier 1 scaling affordances</b> (all optional, the
 * component degrades to the original flat list when none of
 * them are set):
 * <ul>
 *   <li>{@link searchPlaceholder} — when set, the toolbar
 *       renders a search input. The filter is a
 *       case-insensitive substring over
 *       {@link getRowLabel} (preferred) or the text rendered
 *       by {@link renderRow}. Search and the
 *       {@code filterMode} (link-only / unlink-only chips)
 *       compose via AND.</li>
 *   <li>{@link filterMode} — initial chip selection. Defaults
 *       to {@code "all"}. The two chips (Vinculados / No
 *       vinculados) are always rendered when search is on; they
 *       narrow the visible set to checked-only / unchecked-only.</li>
 *   <li>{@link bulkAction} — when set, the toolbar renders
 *       "Vincular N visibles" / "Desvincular N visibles"
 *       buttons. {@code N} is the count of rows the current
 *       search + filterMode combination shows — bulk applies
 *       to the visible slice, not the entire population, so
 *       filtering first narrows the blast radius.</li>
 * </ul>
 * The call sites that don't pass any of these props (legacy
 * callers) render the original divide-y list unchanged.
 */
export interface BindingTabProps<TRow> {
  entityId: number;
  data: TRow[] | undefined;
  isLoading: boolean;
  isPending: boolean;
  emptyText: string;
  /** Prefix on the per-row toggle button testid
   *  (e.g. {@code "role-toggle"} → {@code role-toggle-10}). */
  toggleIdPrefix: string;
  /** Prefix on the wrapping {@code <ul>} testid (default
   *  {@code "bindings"}). The full id is
   *  {@code `${listTestIdPrefix}-${entityId}`}. */
  listTestIdPrefix?: string;
  getRowId: (row: TRow) => number;
  getRowChecked: (row: TRow) => boolean;
  onToggle: (rowId: number, currentlyBound: boolean) => void;
  renderRow: (row: TRow) => ReactNode;
  /** Plain-text label of a row, used for the client-side
   *  filter. Pass this when {@link renderRow} returns a JSX
   *  fragment (e.g. {@code name + path}); the filter would
   *  otherwise need to scrape React children, which is
   *  brittle. When omitted, the filter is disabled. */
  getRowLabel?: (row: TRow) => string;
  /** Placeholder for the search input. Presence of this prop
   *  switches the toolbar on; pass {@code undefined} to keep
   *  the legacy flat-list rendering. */
  searchPlaceholder?: string;
  /** Initial filter chip selection. Defaults to {@code "all"}
   *  when search is on. */
  filterMode?: "all" | "checked" | "unchecked";
  /** Bulk-action descriptor. Presence switches the bulk
   *  buttons on; the toolbar applies them to the
   *  search+filterMode-visible rows. */
  bulkAction?: BulkAction;
}

type FilterMode = "all" | "checked" | "unchecked";

/**
 * Counter-chip toolbar shown when {@link BindingTabProps.searchPlaceholder}
 * is set. Two pills (Vinculados / No vinculados) act as
 * single-select filters that narrow the visible set on top of
 * the search box. The active chip gets a filled style; the
 * other two stay outlined.
 */
function FilterChips({
  total,
  checkedCount,
  uncheckedCount,
  mode,
  onChange,
  testIdPrefix,
}: {
  total: number;
  checkedCount: number;
  uncheckedCount: number;
  mode: FilterMode;
  onChange: (m: FilterMode) => void;
  testIdPrefix: string;
}) {
  const chip = (label: string, count: number, target: FilterMode, suffix: string) => {
    const active = mode === target;
    return (
      <button
        type="button"
        onClick={() => onChange(target)}
        aria-pressed={active}
        data-testid={`${testIdPrefix}-${suffix}`}
        className={[
          "rounded-full px-2.5 py-0.5 text-[11px] font-medium",
          "transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-500",
          active
            ? "bg-sky-600 text-white"
            : "bg-slate-100 text-slate-700 hover:bg-slate-200",
        ].join(" ")}
      >
        {label} <span className={active ? "opacity-90" : "opacity-60"}>· {count}</span>
      </button>
    );
  };
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      {chip("Todos", total, "all", "all")}
      {chip("Vinculados", checkedCount, "checked", "checked")}
      {chip("No vinculados", uncheckedCount, "unchecked", "unchecked")}
    </div>
  );
}

export function BindingTab<TRow>({
  entityId,
  data,
  isLoading,
  isPending,
  emptyText,
  toggleIdPrefix,
  listTestIdPrefix = "bindings",
  getRowId,
  getRowChecked,
  onToggle,
  renderRow,
  getRowLabel,
  searchPlaceholder,
  filterMode: initialFilterMode = "all",
  bulkAction,
}: BindingTabProps<TRow>) {
  const [query, setQuery] = useState("");
  const [mode, setMode] = useState<FilterMode>(initialFilterMode);
  const showToolbar = searchPlaceholder != null;

  const all = data ?? [];

  // Counts are computed over the unfiltered set so the chips
  // always read "Vinculados 12 · No vinculados 138" — the
  // numbers are about the whole population, not the current
  // view. Only the visible <li> list gets narrowed by the
  // combination of search + mode.
  const counts = useMemo(() => {
    let checked = 0;
    let unchecked = 0;
    for (const r of all) {
      if (getRowChecked(r)) checked += 1;
      else unchecked += 1;
    }
    return { total: all.length, checked, unchecked };
  }, [all, getRowChecked]);

  const visible = useMemo(() => {
    if (!showToolbar) return all;
    const q = query.trim().toLowerCase();
    return all.filter((row) => {
      const isChecked = getRowChecked(row);
      if (mode === "checked" && !isChecked) return false;
      if (mode === "unchecked" && isChecked) return false;
      if (q.length === 0) return true;
      const label = getRowLabel
        ? getRowLabel(row)
        : // Fallback: if the caller didn't provide getRowLabel,
          // we don't filter — preserves the legacy contract
          // (search is opt-in, requires getRowLabel to be
          // meaningful). Returning true here keeps the row
          // visible even with text in the box.
          true;
      if (label === true) return true;
      return label.toLowerCase().includes(q);
    });
  }, [all, getRowChecked, mode, query, showToolbar, getRowLabel]);

  const visibleIds = useMemo(
    () => visible.map((r) => getRowId(r)),
    [visible, getRowId],
  );

  const toolbarTestId = `${toggleIdPrefix}-toolbar`;
  const showEmptyState =
    !isLoading &&
    data != null &&
    (showToolbar ? visible.length === 0 : data.length === 0);

  return (
    <div data-testid={`${listTestIdPrefix}-${entityId}`}>
      {showToolbar ? (
        <div className="mb-2 space-y-1.5" data-testid={toolbarTestId}>
          <div className="relative">
            <input
              type="search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder={searchPlaceholder}
              aria-label={searchPlaceholder}
              data-testid={`${toggleIdPrefix}-search`}
              className={[
                "w-full rounded border border-slate-300 bg-white px-3 py-1.5 pr-8 text-sm",
                "text-slate-900 outline-none placeholder:text-slate-400",
                "focus:border-sky-500 focus:ring-1 focus:ring-sky-500",
              ].join(" ")}
            />
            {query.length > 0 ? (
              <button
                type="button"
                onClick={() => setQuery("")}
                aria-label="Limpiar búsqueda"
                data-testid={`${toggleIdPrefix}-search-clear`}
                className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-0.5 text-slate-400 hover:text-slate-600"
              >
                ×
              </button>
            ) : null}
          </div>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <FilterChips
              total={counts.total}
              checkedCount={counts.checked}
              uncheckedCount={counts.unchecked}
              mode={mode}
              onChange={setMode}
              testIdPrefix={toggleIdPrefix}
            />
            {bulkAction ? (
              <div className="flex items-center gap-1.5">
                <Button
                  size="sm"
                  variant="primary"
                  disabled={isPending || visibleIds.length === 0}
                  onClick={() => bulkAction.onApply(visibleIds, "bind")}
                  data-testid={`${bulkAction.testIdPrefix}-bind`}
                >
                  {bulkAction.bindLabel} ({visibleIds.length})
                </Button>
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={isPending || visibleIds.length === 0}
                  onClick={() => bulkAction.onApply(visibleIds, "unbind")}
                  data-testid={`${bulkAction.testIdPrefix}-unbind`}
                >
                  {bulkAction.unbindLabel} ({visibleIds.length})
                </Button>
              </div>
            ) : null}
          </div>
        </div>
      ) : null}
      <ul
        className="divide-y divide-slate-200"
        data-testid={`${listTestIdPrefix}-${entityId}-list`}
      >
        {visible.map((row) => {
          const rowId = getRowId(row);
          const checked = getRowChecked(row);
          return (
            <li
              key={rowId}
              className="flex items-center justify-between py-2 text-sm"
              data-testid={`${toggleIdPrefix}-row-${rowId}`}
            >
              <span className="font-medium text-slate-800">{renderRow(row)}</span>
              <Button
                size="sm"
                variant={checked ? "secondary" : "primary"}
                disabled={isPending}
                loading={isPending}
                onClick={() => onToggle(rowId, checked)}
                data-testid={`${toggleIdPrefix}-${rowId}`}
              >
                {checked ? "Desvincular" : "Vincular"}
              </Button>
            </li>
          );
        })}
        {showEmptyState ? (
          <li
            className="py-2 text-sm text-slate-500"
            data-testid={`${toggleIdPrefix}-empty`}
          >
            {showToolbar && (query.length > 0 || mode !== "all")
              ? "Sin coincidencias con el filtro actual."
              : emptyText}
          </li>
        ) : null}
      </ul>
    </div>
  );
}