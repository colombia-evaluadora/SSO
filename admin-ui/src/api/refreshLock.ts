/**
 * Single-flight refresh. When the access token expires, several
 * in-flight queries may hit 401 in the same tick; without this
 * guard, each one would call /auth/refresh independently, racing
 * to rotate the cookie and getting back inconsistent tokens.
 *
 * Pattern: when a refresh is in progress, subsequent callers get
 * a promise that resolves to the same result. Once the in-progress
 * call settles (success or failure), the next caller starts a
 * fresh refresh.
 */
export class RefreshLock {
  private inflight: Promise<boolean> | null = null;

  constructor(private readonly refresh: () => Promise<boolean>) {}

  /**
   * Run {@link refresh} if no other caller is already running it.
   * Returns true on success, false on failure.
   */
  acquire(): Promise<boolean> {
    if (this.inflight) {
      return this.inflight;
    }
    this.inflight = this.refresh().finally(() => {
      this.inflight = null;
    });
    return this.inflight;
  }

  /**
   * Test seam. Production code should call {@link acquire}.
   */
  isRunning(): boolean {
    return this.inflight !== null;
  }
}
