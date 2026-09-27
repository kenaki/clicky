import { describe, expect, it } from "vitest";
import { AsyncPushQueue } from "../src/util/asyncPushQueue.js";

async function collect<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const items: T[] = [];
  for await (const item of iterable) items.push(item);
  return items;
}

describe("AsyncPushQueue", () => {
  it("yields items pushed before iteration, then ends on close", async () => {
    const queue = new AsyncPushQueue<number>();
    queue.push(1);
    queue.push(2);
    queue.close();
    expect(await collect(queue)).toEqual([1, 2]);
  });

  it("wakes a waiting consumer when an item arrives", async () => {
    const queue = new AsyncPushQueue<string>();
    const iterator = queue[Symbol.asyncIterator]();
    const pendingNext = iterator.next();
    queue.push("late");
    expect(await pendingNext).toEqual({ value: "late", done: false });
  });

  it("ends a waiting consumer on close", async () => {
    const queue = new AsyncPushQueue<string>();
    const iterator = queue[Symbol.asyncIterator]();
    const pendingNext = iterator.next();
    queue.close();
    expect((await pendingNext).done).toBe(true);
  });

  it("refuses pushes after close", () => {
    const queue = new AsyncPushQueue<number>();
    queue.close();
    expect(() => queue.push(1)).toThrowError(/closed/);
  });
});
