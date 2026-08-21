import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SqlEditor } from "./SqlEditor";

describe("SqlEditor", () => {
  it("renders the value in the (accessible) textarea and calls onChange on typing", async () => {
    const onChange = vi.fn();
    render(<SqlEditor value="select 1" onChange={onChange} ariaLabel="SQL" />);

    const textarea = screen.getByLabelText("SQL") as HTMLTextAreaElement;
    expect(textarea.value).toBe("select 1");

    await userEvent.type(textarea, "!");
    expect(onChange).toHaveBeenLastCalledWith("select 1!");
  });

  it("paints highlighted spans for keywords and placeholders behind the textarea", () => {
    render(
      <SqlEditor
        value="SELECT id FROM t WHERE x = :PARAM.ID"
        onChange={() => {}}
        ariaLabel="SQL"
      />,
    );
    // El <pre> es aria-hidden; buscamos el texto pintado directamente.
    expect(screen.getByText("SELECT")).toBeInTheDocument();
    expect(screen.getByText(":PARAM.ID")).toBeInTheDocument();
  });

  it("shows the placeholder text when the value is empty", () => {
    render(<SqlEditor value="" onChange={() => {}} placeholder="escribe SQL…" ariaLabel="SQL" />);
    expect(screen.getByText("escribe SQL…")).toBeInTheDocument();
  });

  it("marks the field invalid via aria-invalid when requested", () => {
    render(<SqlEditor value="select 1" onChange={() => {}} invalid ariaLabel="SQL" />);
    expect(screen.getByLabelText("SQL")).toHaveAttribute("aria-invalid", "true");
  });
});
