import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Tabs, type TabItem } from "@/components/ui/Tabs";

const TABS: TabItem[] = [
  { key: "general", label: "General", content: <div>General content</div> },
  { key: "roles", label: "Roles", content: <div>Roles content</div> },
  { key: "users", label: "Usuarios", content: <div>Users content</div> },
];

describe("Tabs", () => {
  it("renders all tab labels under a tablist and shows the first panel by default", () => {
    render(<Tabs tabs={TABS} ariaLabel="Secciones" />);
    const list = screen.getByRole("tablist", { name: /Secciones/i });
    expect(list).toBeInTheDocument();
    // Tab labels
    expect(screen.getByRole("tab", { name: /General/i })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /Roles/i })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /Usuarios/i })).toBeInTheDocument();
    // First panel content visible
    expect(screen.getByText("General content")).toBeInTheDocument();
    // Other panels are mounted only as their tab — the panel
    // container has the right id linkage but the content is
    // rendered for the active tab only.
    expect(screen.queryByText("Roles content")).not.toBeInTheDocument();
  });

  it("marks aria-selected on the active tab", () => {
    render(<Tabs tabs={TABS} />);
    expect(screen.getByRole("tab", { name: /General/i })).toHaveAttribute(
      "aria-selected",
      "true",
    );
    expect(screen.getByRole("tab", { name: /Roles/i })).toHaveAttribute(
      "aria-selected",
      "false",
    );
  });

  it("switches panel content when a tab is clicked", async () => {
    render(<Tabs tabs={TABS} />);
    await userEvent.click(screen.getByRole("tab", { name: /Roles/i }));
    expect(screen.getByText("Roles content")).toBeInTheDocument();
    expect(screen.queryByText("General content")).not.toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /Roles/i })).toHaveAttribute(
      "aria-selected",
      "true",
    );
  });

  it("honors initial to set the starting tab", () => {
    render(<Tabs tabs={TABS} initial="users" />);
    expect(screen.getByText("Users content")).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /Usuarios/i })).toHaveAttribute(
      "aria-selected",
      "true",
    );
  });

  it("calls onChange in controlled mode and stays on parent's tab", async () => {
    const onChange = vi.fn();
    render(<Tabs tabs={TABS} activeKey="general" onChange={onChange} />);
    await userEvent.click(screen.getByRole("tab", { name: /Roles/i }));
    expect(onChange).toHaveBeenCalledWith("roles");
    // Active tab remains "general" because parent didn't update.
    expect(screen.getByText("General content")).toBeInTheDocument();
  });

  it("renders nothing for an empty tabs array", () => {
    const { container } = render(<Tabs tabs={[]} />);
    expect(container).toBeEmptyDOMElement();
  });
});