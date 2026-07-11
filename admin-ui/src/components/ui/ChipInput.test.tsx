import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { ChipInput } from "@/components/ui/ChipInput";

/**
 * Wrapper because ChipInput is controlled — tests start with a
 * {@code useState} array and {@code setValue} so they can
 * exercise the same add/remove cycle the form will hit.
 */
function ControlledChipInput(
  props: Omit<React.ComponentProps<typeof ChipInput>, "value" | "onChange"> & {
    initial: string[];
  },
) {
  const [value, setValue] = useState<string[]>(props.initial);
  return <ChipInput {...props} value={value} onChange={setValue} />;
}

describe("ChipInput", () => {
  it("renders label + input + empty state when no chips", () => {
    render(
      <ControlledChipInput
        label="Columnas"
        initial={[]}
        dataTestId="cols"
      />,
    );
    expect(screen.getByText("Columnas")).toBeInTheDocument();
    expect(screen.getByTestId("cols-input")).toBeInTheDocument();
    expect(
      screen.getByPlaceholderText("Añadir y pulsar Enter"),
    ).toBeInTheDocument();
    // no chip testids when array is empty
    expect(screen.queryByTestId("cols-chip-0")).not.toBeInTheDocument();
  });

  it("commits a chip on Enter and clears the input", async () => {
    render(
      <ControlledChipInput
        label="Columnas"
        initial={[]}
        dataTestId="cols"
      />,
    );
    const input = screen.getByTestId("cols-input");
    await userEvent.type(input, "ID{Enter}");
    expect(screen.getByTestId("cols-chip-0")).toHaveTextContent("ID");
    expect(input).toHaveValue("");
  });

  it("commits a chip when typing a comma (default addOn)", async () => {
    render(
      <ControlledChipInput
        label="Columnas"
        initial={[]}
        dataTestId="cols"
      />,
    );
    // userEvent.type with comma + Enter after forces the
    // commit on comma; we then verify two chips after the
    // second value is Enter-committed too.
    const input = screen.getByTestId("cols-input");
    await userEvent.type(input, "NAME,");
    expect(screen.getByTestId("cols-chip-0")).toHaveTextContent("NAME");
    // the comma was committed -> input is empty
    expect(input).toHaveValue("");
    await userEvent.type(input, "EMAIL{Enter}");
    expect(screen.getByTestId("cols-chip-1")).toHaveTextContent("EMAIL");
  });

  it("removes the chip via × without leaving a gap", async () => {
    render(
      <ControlledChipInput
        label="Columnas"
        initial={["ONE", "TWO", "THREE"]}
        dataTestId="cols"
      />,
    );
    expect(screen.getByTestId("cols-chip-0")).toHaveTextContent("ONE");
    expect(screen.getByTestId("cols-chip-1")).toHaveTextContent("TWO");
    await userEvent.click(screen.getByTestId("cols-remove-1"));
    // ONE stays at 0; TWO is gone; THREE slides to 1.
    expect(screen.getByTestId("cols-chip-0")).toHaveTextContent("ONE");
    expect(screen.getByTestId("cols-chip-1")).toHaveTextContent("THREE");
    expect(screen.queryByTestId("cols-chip-2")).not.toBeInTheDocument();
  });

  it("calls onChange with the correct array across adds", async () => {
    const onChange = vi.fn();
    const last: string[] = [];
    render(
      <ChipInput
        label="Columnas"
        value={last}
        onChange={(next) => {
          last.length = 0;
          last.push(...next);
          onChange(next);
        }}
        dataTestId="cols"
      />,
    );
    await userEvent.type(screen.getByTestId("cols-input"), "ID{Enter}");
    expect(onChange).toHaveBeenLastCalledWith(["ID"]);
    await userEvent.type(screen.getByTestId("cols-input"), "NAME{Enter}");
    expect(onChange).toHaveBeenLastCalledWith(["ID", "NAME"]);
  });

  it("renders the error message and marks input aria-invalid", () => {
    render(
      <ChipInput
        label="Columnas"
        value={[]}
        onChange={() => {}}
        error="Al menos una columna"
        dataTestId="cols"
      />,
    );
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Al menos una columna",
    );
    expect(screen.getByTestId("cols-input")).toHaveAttribute(
      "aria-invalid",
      "true",
    );
  });
});
