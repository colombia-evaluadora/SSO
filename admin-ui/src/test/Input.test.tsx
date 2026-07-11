import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Input } from "@/components/ui/Input";

describe("Input", () => {
  it("associates the label with the input via for/id", () => {
    render(<Input label="Username" name="username" />);
    const input = screen.getByLabelText("Username");
    expect(input).toHaveAttribute("name", "username");
  });

  it("shows an asterisk when required", () => {
    render(<Input label="Email" required />);
    expect(screen.getByText("*")).toBeInTheDocument();
  });

  it("shows the error message and sets aria-invalid", () => {
    render(<Input label="Username" error="Required" />);
    const input = screen.getByLabelText("Username");
    expect(input).toHaveAttribute("aria-invalid", "true");
    expect(screen.getByRole("alert")).toHaveTextContent("Required");
  });

  it("shows the hint when there is no error", () => {
    render(<Input label="Username" hint="Pick something memorable" />);
    expect(screen.getByText("Pick something memorable")).toBeInTheDocument();
  });

  it("hides the hint when an error is shown (error wins)", () => {
    render(<Input label="Username" hint="Hint" error="Bad" />);
    expect(screen.queryByText("Hint")).not.toBeInTheDocument();
    expect(screen.getByText("Bad")).toBeInTheDocument();
  });

  it("reflects user typing", async () => {
    render(<Input label="Username" />);
    const input = screen.getByLabelText("Username");
    await userEvent.type(input, "admin");
    expect(input).toHaveValue("admin");
  });
});
