import { useState, type ReactNode } from "react";

/**
 * Headless tab strip + panel. Built to host the AppFormDrawer's
 * five sections (General + 4 binding families); also reusable
 * for any future drawer or page that needs tabbed content.
 *
 * <p>Two modes:
 * <ul>
 *   <li><b>Uncontrolled</b> (default): the component tracks the
 *       active tab internally. Use {@code initial} to pick a
 *       starting tab.</li>
 *   <li><b>Controlled</b>: pass {@code activeKey} + {@code onChange}
 *       and the parent owns the state. Useful when the rest of
 *       the drawer needs to react (e.g. force the General tab
 *       after a successful create).</li>
 * </ul>
 *
 * <p>Keyboard navigation (arrow keys) is intentionally omitted
 * in v1 — the pattern in this module doesn't use it, and most
 * tabs sit behind a drawer where arrow keys already navigate
 * the surrounding form fields.
 */
export interface TabItem {
  key: string;
  label: string;
  content: ReactNode;
}

export interface TabsProps {
  tabs: TabItem[];
  initial?: string;
  activeKey?: string;
  onChange?: (key: string) => void;
  ariaLabel?: string;
}

export function Tabs({
  tabs,
  initial,
  activeKey,
  onChange,
  ariaLabel = "Tabs",
}: TabsProps) {
  const [internal, setInternal] = useState(initial ?? tabs[0]?.key ?? "");
  const current = activeKey ?? internal;

  function set(k: string) {
    if (activeKey === undefined) setInternal(k);
    onChange?.(k);
  }

  if (tabs.length === 0) return null;
  const active = tabs.find((t) => t.key === current) ?? tabs[0]!;

  return (
    <div>
      <div
        role="tablist"
        aria-label={ariaLabel}
        className="flex border-b border-slate-200"
      >
        {tabs.map((t) => (
          <button
            key={t.key}
            role="tab"
            id={`tab-${t.key}`}
            aria-selected={t.key === active.key}
            aria-controls={`panel-${t.key}`}
            type="button"
            onClick={() => set(t.key)}
            className={[
              "px-4 py-2 text-sm font-medium",
              t.key === active.key
                ? "border-b-2 border-sky-600 text-sky-700"
                : "text-slate-600 hover:text-slate-800",
            ].join(" ")}
          >
            {t.label}
          </button>
        ))}
      </div>
      <div
        role="tabpanel"
        id={`panel-${active.key}`}
        aria-labelledby={`tab-${active.key}`}
        className="py-4"
      >
        {active.content}
      </div>
    </div>
  );
}