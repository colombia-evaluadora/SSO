import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MultiSelect } from "@/components/ui/MultiSelect";

interface Role {
  id: number;
  name: string;
}

const options = [
  { value: { id: 1, name: "ADMIN" }, label: "ADMIN" },
  { value: { id: 2, name: "USER" }, label: "USER" },
];

describe("MultiSelect", () => {
  it("renders the placeholder when nothing is selected", () => {
    render(
      <MultiSelect<Role>
        options={options}
        selectedIds={new Set()}
        onChange={() => {}}
      />,
    );
    expect(screen.getByRole("button")).toHaveTextContent(/Selecciona/i);
  });

  it("opens the listbox on click and shows options", async () => {
    render(
      <MultiSelect<Role>
        options={options}
        selectedIds={new Set()}
        onChange={() => {}}
      />,
    );
    await userEvent.click(screen.getByRole("button"));
    expect(screen.getByRole("listbox")).toBeInTheDocument();
    expect(screen.getByLabelText("ADMIN")).toBeInTheDocument();
    expect(screen.getByLabelText("USER")).toBeInTheDocument();
  });

  it("emits onChange with a new set when a checkbox is toggled", async () => {
    const onChange = vi.fn();
    render(
      <MultiSelect<Role>
        options={options}
        selectedIds={new Set([1])}
        onChange={onChange}
      />,
    );
    await userEvent.click(screen.getByRole("button"));
    await userEvent.click(screen.getByLabelText("USER"));
    const next = onChange.mock.calls[0]?.[0] as Set<number>;
    expect(next).toBeInstanceOf(Set);
    expect(next.has(1)).toBe(true);
    expect(next.has(2)).toBe(true);
  });

  it("removes from the set when an already-checked item is toggled", async () => {
    const onChange = vi.fn();
    render(
      <MultiSelect<Role>
        options={options}
        selectedIds={new Set([1, 2])}
        onChange={onChange}
      />,
    );
    await userEvent.click(screen.getByRole("button"));
    await userEvent.click(screen.getByLabelText("ADMIN"));
    const next = onChange.mock.calls[0]?.[0] as Set<number>;
    expect(next.has(1)).toBe(false);
    expect(next.has(2)).toBe(true);
  });

  it("shows the single label when exactly one is selected", () => {
    render(
      <MultiSelect<Role>
        options={options}
        selectedIds={new Set([2])}
        onChange={() => {}}
      />,
    );
    expect(screen.getByRole("button")).toHaveTextContent("USER");
  });

  it("shows a count when multiple are selected", () => {
    render(
      <MultiSelect<Role>
        options={options}
        selectedIds={new Set([1, 2])}
        onChange={() => {}}
      />,
    );
    expect(screen.getByRole("button")).toHaveTextContent(/2 seleccionados/);
  });
});
