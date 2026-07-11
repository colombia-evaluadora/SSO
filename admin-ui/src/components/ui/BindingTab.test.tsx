import { describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { BindingTab, type BulkAction } from "./BindingTab";

/**
 * Tests for the Tier-1 scaling affordances on the shared
 * {@link BindingTab} primitive: client-side search, counter
 * chips (Todos / Vinculados / No vinculados), and bulk-action
 * buttons (Vincular visibles / Desvincular visibles).
 *
 * <p>Coverage scope:
 * <ul>
 *   <li>When no toolbar props are passed, the component renders
 *       the original flat list (back-compat).</li>
 *   <li>Search input narrows the visible rows by case-insensitive
 *       substring over {@link BindingTabProps.getRowLabel}.</li>
 *   <li>Filter chips narrow the visible rows by {@code checked}
 *       boolean; the "Todos" chip clears the filter.</li>
 *   <li>Bulk-action buttons fan out to the visible slice only —
 *       filtering first narrows the blast radius.</li>
 *   <li>The empty state copy adapts to whether a filter is
 *       active vs the underlying list being empty.</li>
 *   <li>The counter chips read whole-population counts (not the
 *       filtered view) so the admin always sees the true state.</li>
 * </ul>
 */

interface Row {
  roleId: number;
  name: string;
  checked: boolean;
}

function mkBulk(): { action: BulkAction; spy: ReturnType<typeof vi.fn> } {
  const spy = vi.fn();
  return {
    action: {
      bindLabel: "Vincular visibles",
      unbindLabel: "Desvincular visibles",
      testIdPrefix: "test-bulk",
      onApply: (ids, act) => spy({ ids, act }),
    },
    spy,
  };
}

describe("BindingTab", () => {
  describe("legacy flat list (no toolbar props)", () => {
    it("renders the original divide-y list when searchPlaceholder is not passed", () => {
      const onToggle = vi.fn();
      const data: Row[] = [
        { roleId: 1, name: "ADMIN", checked: true },
        { roleId: 2, name: "USER", checked: false },
      ];
      render(
        <BindingTab<Row>
          entityId={42}
          data={data}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={onToggle}
          renderRow={(r) => r.name}
        />,
      );

      // No toolbar — no search input, no chips, no bulk buttons.
      expect(screen.queryByTestId("role-toggle-search")).not.toBeInTheDocument();
      expect(screen.queryByTestId("role-toggle-toolbar")).not.toBeInTheDocument();
      expect(screen.queryByTestId("test-bulk-bind")).not.toBeInTheDocument();

      // Per-row toggles still work — legacy contract intact.
      expect(screen.getByTestId("role-toggle-1")).toHaveTextContent(
        "Desvincular",
      );
      expect(screen.getByTestId("role-toggle-2")).toHaveTextContent("Vincular");
    });

    it("shows the legacy empty-state copy when the underlying list is empty", () => {
      render(
        <BindingTab<Row>
          entityId={1}
          data={[]}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles creados."
          toggleIdPrefix="role-toggle"
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
        />,
      );
      expect(screen.getByTestId("role-toggle-empty")).toHaveTextContent(
        "No hay roles creados.",
      );
    });
  });

  describe("tier 1 toolbar", () => {
    const data: Row[] = [
      { roleId: 1, name: "ADMIN", checked: true },
      { roleId: 2, name: "AUDITOR", checked: false },
      { roleId: 3, name: "EDITOR", checked: true },
      { roleId: 4, name: "USER", checked: false },
    ];

    it("renders search input, counter chips, and bulk buttons when props are passed", () => {
      const { action } = mkBulk();
      render(
        <BindingTab<Row>
          entityId={1}
          data={data}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          searchPlaceholder="Buscar rol…"
          getRowLabel={(r) => r.name}
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
          bulkAction={action}
        />,
      );

      // Search input present.
      expect(screen.getByTestId("role-toggle-search")).toBeInTheDocument();
      // Counter chips show whole-population counts.
      const toolbar = screen.getByTestId("role-toggle-toolbar");
      expect(within(toolbar).getByTestId("role-toggle-all")).toHaveTextContent("Todos · 4");
      expect(within(toolbar).getByTestId("role-toggle-checked")).toHaveTextContent(
        "Vinculados · 2",
      );
      expect(within(toolbar).getByTestId("role-toggle-unchecked")).toHaveTextContent(
        "No vinculados · 2",
      );
      // Bulk buttons present.
      expect(screen.getByTestId("test-bulk-bind")).toBeInTheDocument();
      expect(screen.getByTestId("test-bulk-unbind")).toBeInTheDocument();
    });

    it("filters rows by case-insensitive substring on getRowLabel", async () => {
      render(
        <BindingTab<Row>
          entityId={1}
          data={data}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          searchPlaceholder="Buscar rol…"
          getRowLabel={(r) => r.name}
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
        />,
      );

      await userEvent.type(screen.getByTestId("role-toggle-search"), "ed");

      // Only EDITOR (id=3) contains "ed" — ADMIN/a-d-m-i-n does
      // not, AUDITOR/a-u-d-i-t-o-r does not, USER/u-s-e-r does not.
      expect(
        screen.queryByTestId("role-toggle-row-1"),
      ).not.toBeInTheDocument();
      expect(
        screen.queryByTestId("role-toggle-row-2"),
      ).not.toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-3")).toBeInTheDocument();
      expect(
        screen.queryByTestId("role-toggle-row-4"),
      ).not.toBeInTheDocument();

      // Counter chips still report whole-population counts.
      expect(screen.getByTestId("role-toggle-checked")).toHaveTextContent(
        "Vinculados · 2",
      );
      expect(screen.getByTestId("role-toggle-unchecked")).toHaveTextContent(
        "No vinculados · 2",
      );
    });

    it("clear-button (×) on the search input empties the filter", async () => {
      render(
        <BindingTab<Row>
          entityId={1}
          data={data}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          searchPlaceholder="Buscar rol…"
          getRowLabel={(r) => r.name}
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
        />,
      );

      const search = screen.getByTestId("role-toggle-search");
      await userEvent.type(search, "admin");
      expect(screen.queryByTestId("role-toggle-row-2")).not.toBeInTheDocument();

      await userEvent.click(screen.getByTestId("role-toggle-search-clear"));
      expect(search).toHaveValue("");
      // All four rows back on screen.
      expect(screen.getByTestId("role-toggle-row-1")).toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-2")).toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-3")).toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-4")).toBeInTheDocument();
    });

    it("Vinculados / No vinculados chips narrow to checked-only / unchecked-only", async () => {
      render(
        <BindingTab<Row>
          entityId={1}
          data={data}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          searchPlaceholder="Buscar rol…"
          getRowLabel={(r) => r.name}
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
        />,
      );

      await userEvent.click(screen.getByTestId("role-toggle-checked"));
      expect(screen.getByTestId("role-toggle-row-1")).toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-3")).toBeInTheDocument();
      expect(
        screen.queryByTestId("role-toggle-row-2"),
      ).not.toBeInTheDocument();
      expect(
        screen.queryByTestId("role-toggle-row-4"),
      ).not.toBeInTheDocument();

      await userEvent.click(screen.getByTestId("role-toggle-unchecked"));
      expect(
        screen.queryByTestId("role-toggle-row-1"),
      ).not.toBeInTheDocument();
      expect(
        screen.queryByTestId("role-toggle-row-3"),
      ).not.toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-2")).toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-4")).toBeInTheDocument();

      // Back to "Todos" restores the full list.
      await userEvent.click(screen.getByTestId("role-toggle-all"));
      expect(screen.getByTestId("role-toggle-row-1")).toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-2")).toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-3")).toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-4")).toBeInTheDocument();
    });

    it("search + chip compose (AND)", async () => {
      render(
        <BindingTab<Row>
          entityId={1}
          data={data}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          searchPlaceholder="Buscar rol…"
          getRowLabel={(r) => r.name}
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
        />,
      );

      // Vinculados only + "ed" → only EDITOR remains.
      await userEvent.click(screen.getByTestId("role-toggle-checked"));
      await userEvent.type(screen.getByTestId("role-toggle-search"), "ed");
      expect(
        screen.queryByTestId("role-toggle-row-1"),
      ).not.toBeInTheDocument();
      expect(screen.getByTestId("role-toggle-row-3")).toBeInTheDocument();
    });

    it("shows 'Sin coincidencias' when the filter narrows to zero rows", async () => {
      render(
        <BindingTab<Row>
          entityId={1}
          data={data}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          searchPlaceholder="Buscar rol…"
          getRowLabel={(r) => r.name}
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
        />,
      );
      await userEvent.type(screen.getByTestId("role-toggle-search"), "zzzz");
      expect(screen.getByTestId("role-toggle-empty")).toHaveTextContent(
        "Sin coincidencias con el filtro actual.",
      );
    });

    it("bulk buttons apply to the currently visible slice only", async () => {
      const { action, spy } = mkBulk();
      render(
        <BindingTab<Row>
          entityId={1}
          data={data}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          searchPlaceholder="Buscar rol…"
          getRowLabel={(r) => r.name}
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
          bulkAction={action}
        />,
      );

      // With no filter the bulk button label shows "(4)".
      const bindBtn = screen.getByTestId("test-bulk-bind");
      expect(bindBtn).toHaveTextContent("Vincular visibles (4)");

      // Filter down to unchecked-only (USER, AUDITOR = ids 4, 2).
      await userEvent.click(screen.getByTestId("role-toggle-unchecked"));
      expect(bindBtn).toHaveTextContent("Vincular visibles (2)");

      await userEvent.click(bindBtn);
      expect(spy).toHaveBeenCalledWith({ ids: [2, 4], act: "bind" });

      // Bulk unbind: same visible slice, opposite action.
      await userEvent.click(screen.getByTestId("test-bulk-unbind"));
      expect(spy).toHaveBeenCalledWith({ ids: [2, 4], act: "unbind" });
    });

    it("bulk buttons stay disabled when the visible slice is empty", async () => {
      const { action } = mkBulk();
      render(
        <BindingTab<Row>
          entityId={1}
          data={data}
          isLoading={false}
          isPending={false}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          searchPlaceholder="Buscar rol…"
          getRowLabel={(r) => r.name}
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
          bulkAction={action}
        />,
      );

      await userEvent.type(screen.getByTestId("role-toggle-search"), "zzzz");
      const bindBtn = screen.getByTestId("test-bulk-bind");
      expect(bindBtn).toHaveTextContent("Vincular visibles (0)");
      expect(bindBtn).toBeDisabled();
    });

    it("bulk buttons are disabled while a mutation is pending", () => {
      const { action } = mkBulk();
      render(
        <BindingTab<Row>
          entityId={1}
          data={data}
          isLoading={false}
          isPending={true}
          emptyText="No hay roles."
          toggleIdPrefix="role-toggle"
          searchPlaceholder="Buscar rol…"
          getRowLabel={(r) => r.name}
          getRowId={(r) => r.roleId}
          getRowChecked={(r) => r.checked}
          onToggle={vi.fn()}
          renderRow={(r) => r.name}
          bulkAction={action}
        />,
      );
      expect(screen.getByTestId("test-bulk-bind")).toBeDisabled();
      expect(screen.getByTestId("test-bulk-unbind")).toBeDisabled();
    });
  });
});