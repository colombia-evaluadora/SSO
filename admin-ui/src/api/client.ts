import { env } from "@/env";
import { RefreshLock } from "./refreshLock";
import type { ErrorResponse, TokenResponse } from "./types";

/**
 * The HTTP client. Adds the Bearer header automatically, handles
 * 401 by calling /auth/refresh (using the sso_refresh cookie the
 * browser holds), and retries the original request once on a
 * successful refresh. On refresh failure, dispatches an
 * `auth:logout` CustomEvent so the AuthProvider can clear its
 * state and the router can navigate to /login.
 *
 * Cookies are sent automatically because we never set custom
 * credentials, and the browser carries the sso_refresh cookie on
 * every same-origin request. In dev, the Vite proxy at
 * http://localhost:5173 forwards /api/** to the gateway at
 * :8080 — single origin from the browser's perspective.
 */
export class ApiClient {
  private readonly refreshLock: RefreshLock;
  private getAccessToken: () => string | null = () => null;
  private onAuthFailure: () => void = () => {};

  constructor() {
    this.refreshLock = new RefreshLock(() => this.runRefresh());
  }

  /** Wired by AuthProvider once the in-memory token exists. */
  setAccessTokenGetter(fn: () => string | null): void {
    this.getAccessToken = fn;
  }

  /** Wired by AuthProvider. Called when refresh fails. */
  setAuthFailureHandler(fn: () => void): void {
    this.onAuthFailure = fn;
  }

  /**
   * GET helper. Returns parsed JSON; throws {@link ApiError} on
   * non-2xx. Pass `true` for {@code skipAuth} on the refresh
   * endpoint itself, to avoid the recursive 401 loop.
   *
   * Pass `base: ""` for cross-service calls that bypass the
   * {@code /api} prefix — used by the Queries Catalog page to
   * hit {@code /<serviceId>/query} directly via the gateway's
   * dynamic discovery locator.
   */
  async get<T>(path: string, init?: { skipAuth?: boolean; base?: string | null }): Promise<T> {
    return this.request<T>("GET", path, undefined, init);
  }

  async post<T>(path: string, body?: unknown, init?: { skipAuth?: boolean; base?: string | null }): Promise<T> {
    return this.request<T>("POST", path, body, init);
  }

  async put<T>(path: string, body?: unknown, init?: { skipAuth?: boolean; base?: string | null }): Promise<T> {
    return this.request<T>("PUT", path, body, init);
  }

  async delete<T>(path: string, init?: { skipAuth?: boolean; base?: string | null }): Promise<T> {
    return this.request<T>("DELETE", path, undefined, init);
  }

  /**
   * Internal: a single request, with one transparent 401 -> refresh
   * -> retry attempt. After that, the error bubbles up.
   */
  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
    init?: { skipAuth?: boolean; base?: string | null },
  ): Promise<T> {
    const resp = await this.fetchOnce(method, path, body, init?.skipAuth, init?.base);
    if (resp.status !== 401 || init?.skipAuth) {
      return this.handleResponse<T>(resp);
    }
    // 401: try to refresh once. If it succeeds, retry the original.
    const refreshed = await this.refreshLock.acquire();
    if (!refreshed) {
      this.onAuthFailure();
      throw new ApiError(401, "AUTH_EXPIRED", "Session expired; please log in again");
    }
    const retried = await this.fetchOnce(method, path, body, init?.skipAuth, init?.base);
    return this.handleResponse<T>(retried);
  }

  private async fetchOnce(
    method: string,
    path: string,
    body?: unknown,
    skipAuth = false,
    base: string | null = null,
  ): Promise<Response> {
    const headers: Record<string, string> = {
      Accept: "application/json",
    };
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
    }
    if (!skipAuth) {
      const token = this.getAccessToken();
      if (token) {
        headers["Authorization"] = `Bearer ${token}`;
      }
    }
    // exactOptionalPropertyTypes rejects `body: undefined`; only
    // attach the field when we have a real payload.
    const init: RequestInit = {
      method,
      headers,
      credentials: "same-origin",
    };
    if (body !== undefined) {
      init.body = JSON.stringify(body);
    }
    // `base === null` → use VITE_API_BASE (the default for every
    // existing call). `base === ""` → skip the prefix entirely;
    // used by the Queries Catalog page to hit gateway dynamic
    // routes like /query-service-<x>/query directly.
    const prefix = base === null ? env.VITE_API_BASE : base;
    return fetch(`${prefix}${path}`, init);
  }

  private async handleResponse<T>(resp: Response): Promise<T> {
    if (resp.ok) {
      // Some endpoints return no body — 204 always, but also a
      // few 200s (e.g. activateAccount/restorePassword's
      // ResponseEntity.ok().build()). resp.json() throws
      // "Unexpected end of JSON input" on a truly empty body, so
      // check the text first rather than trusting the status code.
      const text = await resp.text();
      if (text.length === 0) {
        return undefined as T;
      }
      return JSON.parse(text) as T;
    }
    let payload: ErrorResponse | null = null;
    try {
      payload = (await resp.json()) as ErrorResponse;
    } catch {
      // ignore: response wasn't JSON
    }
    throw new ApiError(
      resp.status,
      payload?.code ?? "HTTP_ERROR",
      payload?.message ?? `${resp.status} ${resp.statusText}`,
    );
  }

  /**
   * Refreshes the access token. Sends the cookie; receives a new
   * token + a rotated cookie. Updates the in-memory token via the
   * AuthProvider's onTokenRefreshed callback. Returns true on success.
   */
  private async runRefresh(): Promise<boolean> {
    try {
      const resp = await fetch(`${env.VITE_API_BASE}/auth/refresh`, {
        method: "POST",
        credentials: "same-origin",
      });
      if (!resp.ok) return false;
      const body = (await resp.json()) as TokenResponse;
      // The AuthProvider listens for this event and updates the
      // in-memory token. We do it via CustomEvent rather than a
      // direct callback so the circular import (client -> auth ->
      // client) doesn't bite us.
      window.dispatchEvent(
        new CustomEvent("auth:token-refreshed", { detail: body.token }),
      );
      return true;
    } catch {
      return false;
    }
  }
}

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

/** Singleton; wired up by AuthProvider on mount. */
export const apiClient = new ApiClient();
