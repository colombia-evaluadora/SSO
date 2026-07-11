import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { act, render, screen, waitFor } from "@testing-library/react";
import { ToastProvider, useToast } from "@/components/ui/Toast";

/**
 * The Toast component auto-dismisses after 4s. We override
 * setTimeout/clearTimeout indirectly by advancing fake timers.
 */
describe("Toast", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  function Trigger() {
    const toast = useToast();
    return (
      <>
        <button onClick={() => toast.show("Saved!")}>info</button>
        <button onClick={() => toast.show("Boom", "error")}>error</button>
      </>
    );
  }

  it("renders a toast when show is called", () => {
    render(
      <ToastProvider>
        <Trigger />
      </ToastProvider>,
    );
    act(() => {
      screen.getByText("info").click();
    });
    expect(screen.getByText("Saved!")).toBeInTheDocument();
  });

  it("auto-dismisses after the timer", () => {
    render(
      <ToastProvider>
        <Trigger />
      </ToastProvider>,
    );
    act(() => {
      screen.getByText("info").click();
    });
    expect(screen.getByText("Saved!")).toBeInTheDocument();
    act(() => {
      vi.advanceTimersByTime(4000);
    });
    expect(screen.queryByText("Saved!")).not.toBeInTheDocument();
  });

  it("renders error toasts with role=alert", () => {
    render(
      <ToastProvider>
        <Trigger />
      </ToastProvider>,
    );
    act(() => {
      screen.getByText("error").click();
    });
    expect(screen.getByRole("alert")).toHaveTextContent("Boom");
  });

  it("falls back to console when no provider is mounted", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    function Bare() {
      const t = useToast();
      return <button onClick={() => t.show("hi")}>go</button>;
    }
    render(<Bare />);
    act(() => {
      screen.getByText("go").click();
    });
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("hi"));
    warn.mockRestore();
  });

  it("real timers: toasts disappear", async () => {
    vi.useRealTimers();
    render(
      <ToastProvider>
        <Trigger />
      </ToastProvider>,
    );
    act(() => {
      screen.getByText("info").click();
    });
    expect(screen.getByText("Saved!")).toBeInTheDocument();
    await waitFor(
      () => {
        expect(screen.queryByText("Saved!")).not.toBeInTheDocument();
      },
      { timeout: 5000 },
    );
  });
});
