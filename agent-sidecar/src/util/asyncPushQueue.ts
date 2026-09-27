/**
 * An unbounded async queue: producers push, one consumer iterates with
 * `for await`. This is how the sidecar feeds user messages into the Agent
 * SDK's streaming-input query, which takes an AsyncIterable and keeps the
 * session alive for as long as the iterable stays open.
 */
export class AsyncPushQueue<T> implements AsyncIterable<T> {
  private readonly bufferedItems: T[] = [];
  private readonly waitingConsumers: Array<(result: IteratorResult<T>) => void> = [];
  private isClosed = false;

  push(item: T): void {
    if (this.isClosed) {
      throw new Error("Cannot push to a closed AsyncPushQueue");
    }
    const waitingConsumer = this.waitingConsumers.shift();
    if (waitingConsumer) {
      waitingConsumer({ value: item, done: false });
      return;
    }
    this.bufferedItems.push(item);
  }

  /** Ends iteration once buffered items are drained. Idempotent. */
  close(): void {
    if (this.isClosed) return;
    this.isClosed = true;
    for (const waitingConsumer of this.waitingConsumers.splice(0)) {
      waitingConsumer({ value: undefined as unknown as T, done: true });
    }
  }

  get closed(): boolean {
    return this.isClosed;
  }

  get pendingItemCount(): number {
    return this.bufferedItems.length;
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: () => {
        const bufferedItem = this.bufferedItems.shift();
        if (bufferedItem !== undefined) {
          return Promise.resolve({ value: bufferedItem, done: false });
        }
        if (this.isClosed) {
          return Promise.resolve({ value: undefined as unknown as T, done: true });
        }
        return new Promise<IteratorResult<T>>((resolve) => {
          this.waitingConsumers.push(resolve);
        });
      },
      return: () => {
        this.close();
        return Promise.resolve({ value: undefined as unknown as T, done: true });
      }
    };
  }
}
