import { describe, expect, it } from "vitest";
import { SentenceStreamSplitter } from "../src/agent/sentenceStreamSplitter.js";

function feedAll(chunks: string[]): { sentences: string[]; remainder: string | null } {
  const splitter = new SentenceStreamSplitter();
  const sentences = chunks.flatMap((chunk) => splitter.feed(chunk));
  return { sentences, remainder: splitter.flush() };
}

describe("SentenceStreamSplitter", () => {
  it("emits a sentence only once the whitespace after its punctuation has arrived", () => {
    const splitter = new SentenceStreamSplitter();
    expect(splitter.feed("the search bar is up top.")).toEqual([]);
    expect(splitter.feed(" press command")).toEqual(["the search bar is up top."]);
    expect(splitter.flush()).toBe("press command");
  });

  it("splits sentences that arrive in arbitrary chunk boundaries", () => {
    const { sentences, remainder } = feedAll(["it's in the menu ba", "r. click it! then wha", "t? okay"]);
    expect(sentences).toEqual(["it's in the menu bar.", "click it!", "then what?"]);
    expect(remainder).toBe("okay");
  });

  it("does not split a decimal number", () => {
    const { sentences, remainder } = feedAll(["it takes 3.", "5 seconds to load. then it's done "]);
    expect(sentences).toEqual(["it takes 3.5 seconds to load."]);
    expect(remainder).toBe("then it's done");
  });

  it("splits after a single-letter word, because 'press command f.' is common in speech", () => {
    const { sentences, remainder } = feedAll(["press command f. then type your search "]);
    expect(sentences).toEqual(["press command f."]);
    expect(remainder).toBe("then type your search");
  });

  it("treats a newline as a boundary even without punctuation", () => {
    const { sentences, remainder } = feedAll(["let me check the file\nreading it now. "]);
    expect(sentences).toEqual(["let me check the file", "reading it now."]);
    expect(remainder).toBeNull();
  });

  it("keeps closing quotes with the sentence", () => {
    const { sentences } = feedAll(['click "save." then wait. ']);
    expect(sentences).toEqual(['click "save."', "then wait."]);
  });

  it("flush returns null when nothing is pending and resets state", () => {
    const splitter = new SentenceStreamSplitter();
    splitter.feed("done. ");
    expect(splitter.flush()).toBeNull();
    expect(splitter.pending).toBe("");
  });
});
