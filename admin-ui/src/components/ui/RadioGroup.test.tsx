import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { RadioGroup } from "@/components/ui/RadioGroup";

const OPTIONS = [
  { value: "REST", label: "REST routing rule", description: "Classic gateway target." },
  { value: "QUERY", label: "Query service", description: "Spin up a query-service container." },
] as const;

describe("RadioGroup", () => {
  it("renders all options as radios under a legend", () => {
    render(
      <RadioGroup name="kind" value="REST" options={OPTIONS} onChange={() => {}} label="Tipo" />,
    );
    expect(screen.getByText("Tipo")).toBeInTheDocument();
    expect(screen.getByLabelText(/REST routing rule/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Query service/i)).toBeInTheDocument();
  });

  it("marks the selected option via checked + aria", () => {
    render(
      <RadioGroup name="kind" value="QUERY" options={OPTIONS} onChange={() => {}} label="Tipo" />,
    );
    expect(screen.getByLabelText(/Query service/i)).toBeChecked();
    expect(screen.getByLabelText(/REST routing rule/i)).not.toBeChecked();
  });

  it("fires onChange with the chosen value when clicked", async () => {
    const onChange = vi.fn();
    render(
      <RadioGroup name="kind" value="REST" options={OPTIONS} onChange={onChange} label="Tipo" />,
    );
    await userEvent.click(screen.getByLabelText(/Query service/i));
    expect(onChange).toHaveBeenCalledWith("QUERY");
  });

  it("renders the error and sets aria-invalid on radios when error is set", () => {
    render(
      <RadioGroup
        name="kind"
        value="REST"
        options={OPTIONS}
        onChange={() => {}}
        label="Tipo"
        error="Pick one"
      />,
    );
    const radios = screen.getAllByRole("radio");
    for (const r of radios) {
      expect(r).toHaveAttribute("aria-invalid", "true");
    }
    expect(screen.getByRole("alert")).toHaveTextContent("Pick one");
  });

  it("shows the hint when there is no error", () => {
    render(
      <RadioGroup
        name="kind"
        value="REST"
        options={OPTIONS}
        onChange={() => {}}
        label="Tipo"
        hint="Pick the kind of microservice"
      />,
    );
    expect(screen.getByText("Pick the kind of microservice")).toBeInTheDocument();
  });

  it("hides the hint when an error is shown (error wins)", () => {
    render(
      <RadioGroup
        name="kind"
        value="REST"
        options={OPTIONS}
        onChange={() => {}}
        label="Tipo"
        hint="Hint"
        error="Bad"
      />,
    );
    expect(screen.queryByText("Hint")).not.toBeInTheDocument();
    expect(screen.getByText("Bad")).toBeInTheDocument();
  });
});