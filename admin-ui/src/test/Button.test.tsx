import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Button } from "@/components/ui/Button";

describe("Button", () => {
  it("renders its label and fires onClick", async () => {
    const onClick = vi.fn();
    render(<Button onClick={onClick}>Guardar</Button>);
    await userEvent.click(screen.getByRole("button", { name: /Guardar/i }));
    expect(onClick).toHaveBeenCalledOnce();
  });

  it("is disabled when disabled or loading", () => {
    const { rerender } = render(<Button disabled>Save</Button>);
    expect(screen.getByRole("button")).toBeDisabled();

    rerender(<Button loading>Save</Button>);
    const btn = screen.getByRole("button");
    expect(btn).toBeDisabled();
    // spinner present (role stays as button, but we look for the
    // sr-style spinner span — it's aria-hidden so we check by class)
    expect(btn.querySelector("span[aria-hidden='true']")).toBeInTheDocument();
  });

  it("defaults to type=button so it doesn't submit a parent form", () => {
    render(<Button>Click</Button>);
    expect(screen.getByRole("button")).toHaveAttribute("type", "button");
  });

  it("respects an explicit type=submit", () => {
    render(<Button type="submit">Submit</Button>);
    expect(screen.getByRole("button")).toHaveAttribute("type", "submit");
  });
});
