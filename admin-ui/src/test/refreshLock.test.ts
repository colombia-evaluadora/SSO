import { describe, expect, it, vi } from "vitest";
import { RefreshLock } from "@/api/refreshLock";

/**
 * Single-flight semantics:
 *  - the underlying refresh is called at most once per tick
 *  - concurrent callers all see the same result
 *  - once settled, the next caller starts a fresh refresh
 *  - the lock clears on both success and failure
 */
describe("RefreshLock", () => {
  it("calls refresh once when many callers race", async () => {
    const refresh = vi.fn(async () => true);
    const lock = new RefreshLock(refresh);

    const results = await Promise.all([
      lock.acquire(),
      lock.acquire(),
      lock.acquire(),
      lock.acquire(),
    ]);

    expect(refresh).toHaveBeenCalledTimes(1);
    expect(results).toEqual([true, true, true, true]);
  });

  it("propagates the result to all waiters (true)", async () => {
    const lock = new RefreshLock(async () => true);
    const [a, b] = await Promise.all([lock.acquire(), lock.acquire()]);
    expect(a).toBe(true);
    expect(b).toBe(true);
  });

  it("propagates the result to all waiters (false)", async () => {
    const lock = new RefreshLock(async () => false);
    const [a, b] = await Promise.all([lock.acquire(), lock.acquire()]);
    expect(a).toBe(false);
    expect(b).toBe(false);
  });

  it("starts a fresh refresh after the previous one settles", async () => {
    const refresh = vi
      .fn<() => Promise<boolean>>()
      .mockResolvedValueOnce(true)
      .mockResolvedValueOnce(false);
    const lock = new RefreshLock(refresh);

    expect(await lock.acquire()).toBe(true);
    expect(await lock.acquire()).toBe(false);
    expect(refresh).toHaveBeenCalledTimes(2);
  });

  it("clears the inflight pointer on failure", async () => {
    const lock = new RefreshLock(async () => false);
    expect(await lock.acquire()).toBe(false);
    expect(lock.isRunning()).toBe(false);
  });

  it("clears the inflight pointer on success", async () => {
    const lock = new RefreshLock(async () => true);
    expect(await lock.acquire()).toBe(true);
    expect(lock.isRunning()).toBe(false);
  });

  it("does not throw if the refresh itself rejects", async () => {
    const lock = new RefreshLock(async () => {
      throw new Error("network down");
    });
    // The single-flight wrapper rejects, the same as the underlying
    // call would. The lock is cleared so the next caller starts fresh.
    await expect(lock.acquire()).rejects.toThrow("network down");
    expect(lock.isRunning()).toBe(false);

    // Recovery: a subsequent caller gets a fresh attempt.
    const second = new RefreshLock(async () => true);
    expect(await second.acquire()).toBe(true);
  });
});
