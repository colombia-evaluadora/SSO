import { act, render, waitFor } from "@testing-library/react";
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { AuthProvider } from "@/auth/AuthProvider";
import { useAuth } from "@/auth/useAuth";

/**
 * Smoke tests for the AuthProvider state machine. The provider
 * fires a silent /api/auth/refresh on mount, so the first render
 * is "loading" and only later settles. We expose a `harness` from
 * a probe component — the probe re-renders on every state change,
 * so the test always reads the latest snapshot, and the harness
 * lets the test drive `login()` / `logout()` against the same
 * provider instance the probe is observing.
 */
/**
 * A successful login/refresh is followed by a GET
 * /sso-admin/myMenu?app=... call (AuthProvider's app-access gate —
 * see hasAccessToThisApp). Queue this response right after the
 * login/refresh mock to let that check pass; queue an empty-array
 * response to simulate a role with no role_app binding to this app.
 */
function menuResponse(hasAccess: boolean) {
  return new Response(JSON.stringify(hasAccess ? [{ id: 1 }] : []), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

describe("AuthProvider", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  interface Harness {
    login: (u: string, p: string) => Promise<boolean>;
    logout: () => Promise<void>;
  }

  /**
   * Renders a Provider + probe, returning a `harness` with the
   * provider's actions and a `snapshot` getter that reads the
   * current state from the DOM.
   */
  function mount() {
    let harness: Harness = {
      login: async () => false,
      logout: async () => {},
    };

    function Probe() {
      const auth = useAuth();
      harness = {
        login: auth.login,
        logout: auth.logout,
      };
      return (
        <div
          data-testid="probe"
          data-status={auth.status}
          data-email={auth.user?.email ?? ""}
          data-error={auth.error ?? ""}
          data-token={auth.getAccessToken() ?? ""}
        />
      );
    }

    const utils = render(
      <AuthProvider>
        <Probe />
      </AuthProvider>,
    );

    function snapshot() {
      const el = utils.getByTestId("probe");
      return {
        status: el.dataset.status as "loading" | "authenticated" | "unauthenticated",
        email: el.dataset.email ?? "",
        error: el.dataset.error ?? "",
        token: el.dataset.token ?? "",
      };
    }

    async function waitForStatus(s: "authenticated" | "unauthenticated") {
      await waitFor(() => {
        expect(snapshot().status).toBe(s);
      });
    }

    return { harness, snapshot, waitForStatus };
  }

  it("starts in loading, then settles to unauthenticated on refresh failure", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("nope", { status: 401 }));

    const { snapshot } = mount();
    await waitFor(() => expect(snapshot().status).toBe("unauthenticated"));
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/auth/refresh",
      expect.objectContaining({ method: "POST" }),
    );
  });

  it("hydrates to authenticated when the silent refresh succeeds", async () => {
    fetchSpy
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({ token: "abc", refreshToken: "r", expiresIn: 600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      )
      .mockResolvedValueOnce(menuResponse(true));

    const { snapshot } = mount();
    await waitFor(() => expect(snapshot().status).toBe("authenticated"));
    expect(snapshot().token).toBe("abc");
  });

  it("logs out a stale session whose role lost access to this app", async () => {
    fetchSpy
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({ token: "abc", refreshToken: "r", expiresIn: 600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      )
      .mockResolvedValueOnce(menuResponse(false))
      .mockResolvedValueOnce(new Response(null, { status: 204 })); // logout cleanup

    const { snapshot } = mount();
    await waitFor(() => expect(snapshot().status).toBe("unauthenticated"));
    expect(snapshot().token).toBe("");
    expect(snapshot().error).toMatch(/no tienes permiso/i);
  });

  it("login() flips to authenticated and stores the token", async () => {
    fetchSpy
      .mockResolvedValueOnce(new Response("nope", { status: 401 })) // boot
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({ token: "login-tok", refreshToken: "r", expiresIn: 600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      )
      .mockResolvedValueOnce(menuResponse(true));

    const { harness, snapshot, waitForStatus } = mount();
    await waitForStatus("unauthenticated");

    let ok = false;
    await act(async () => {
      ok = await harness.login("admin", "pw");
    });
    expect(ok).toBe(true);
    await waitForStatus("authenticated");
    expect(snapshot().token).toBe("login-tok");
    expect(snapshot().email).toBe("admin");
  });

  it("login() rejects a role with no role_app binding to this app", async () => {
    fetchSpy
      .mockResolvedValueOnce(new Response("nope", { status: 401 })) // boot
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({ token: "login-tok", refreshToken: "r", expiresIn: 600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      )
      .mockResolvedValueOnce(menuResponse(false)) // empty menu = no access
      .mockResolvedValueOnce(new Response(null, { status: 204 })); // logout cleanup

    const { harness, snapshot, waitForStatus } = mount();
    await waitForStatus("unauthenticated");

    let ok = true;
    await act(async () => {
      ok = await harness.login("no-access@example.com", "pw");
    });
    expect(ok).toBe(false);
    expect(snapshot().status).toBe("unauthenticated");
    expect(snapshot().token).toBe("");
    expect(snapshot().error).toMatch(/no tienes permiso/i);
  });

  it("login() surfaces the server error and stays unauthenticated", async () => {
    fetchSpy
      .mockResolvedValueOnce(new Response("nope", { status: 401 })) // boot
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            code: "BAD_CREDENTIALS",
            message: "Bad creds",
            timestamp: "",
          }),
          { status: 401, headers: { "Content-Type": "application/json" } },
        ),
      );

    const { harness, snapshot, waitForStatus } = mount();
    await waitForStatus("unauthenticated");

    let ok = true;
    await act(async () => {
      ok = await harness.login("admin", "wrong");
    });
    expect(ok).toBe(false);
    expect(snapshot().status).toBe("unauthenticated");
    expect(snapshot().error).toBe("Bad creds");
  });

  it("logout() clears the token and the user", async () => {
    fetchSpy
      .mockResolvedValueOnce(new Response("nope", { status: 401 })) // boot
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({ token: "t", refreshToken: "r", expiresIn: 600 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      ) // login
      .mockResolvedValueOnce(menuResponse(true)) // app-access check
      .mockResolvedValueOnce(new Response(null, { status: 204 })); // logout

    const { harness, snapshot, waitForStatus } = mount();
    await waitForStatus("unauthenticated");

    await act(async () => {
      await harness.login("admin", "pw");
    });
    await waitForStatus("authenticated");
    expect(snapshot().token).toBe("t");

    await act(async () => {
      await harness.logout();
    });
    expect(snapshot().status).toBe("unauthenticated");
    expect(snapshot().token).toBe("");
    expect(snapshot().email).toBe("");
  });
});
