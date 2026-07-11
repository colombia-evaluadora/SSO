import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { StatusBadge } from "@/components/ui/StatusBadge";

/**
 * StatusBadge maps a normalized container state to a Tailwind
 * tone and an uppercase label. The component must:
 *   1. Render the canonical uppercase label for each known state.
 *   2. Reflect `data-state` so Playwright tests can target the
 *      badge by its underlying value (not the visible text —
 *      "UP" vs "PROVISIONING" both start with U but have
 *      different data-state attributes).
 *   3. Fall back to `unknown` when the prop is null/undefined or
 *      the backend surfaces a state we haven't enumerated (we
 *      keep "unknown" rather than throw — the page must not
 *      crash on a Docker Engine API change).
 */
describe("StatusBadge", () => {
  it("renders the uppercase label and data-state for running", () => {
    render(<StatusBadge state="running" />);
    const badge = screen.getByText("UP");
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveAttribute("data-state", "running");
  });

  it("renders PROVISIONING for the synthetic provisioning state", () => {
    render(<StatusBadge state="provisioning" />);
    expect(screen.getByText("PROVISIONING")).toHaveAttribute("data-state", "provisioning");
  });

  it("falls back to UNKNOWN when state is null", () => {
    render(<StatusBadge state={null} />);
    expect(screen.getByText("UNKNOWN")).toHaveAttribute("data-state", "unknown");
  });

  it("falls back to UNKNOWN when state is undefined", () => {
    render(<StatusBadge state={undefined} />);
    expect(screen.getByText("UNKNOWN")).toHaveAttribute("data-state", "unknown");
  });

  it("falls back to UNKNOWN when given an unknown state string", () => {
    // Defensive: if Docker adds a state we haven't seen, render
    // the raw uppercase value with data-state set so the operator
    // sees what the backend reported.
    render(<StatusBadge state="frobnicate" />);
    const badge = screen.getByText("FROBNICATE");
    expect(badge).toHaveAttribute("data-state", "frobnicate");
  });

  it("renders ABSENT in red when the container is gone", () => {
    render(<StatusBadge state="absent" />);
    const badge = screen.getByText("ABSENT");
    expect(badge).toHaveAttribute("data-state", "absent");
    expect(badge.className).toMatch(/bg-red/);
  });

  it("renders UP in green when the container is running", () => {
    render(<StatusBadge state="running" />);
    const badge = screen.getByText("UP");
    expect(badge.className).toMatch(/bg-emerald/);
  });
});
