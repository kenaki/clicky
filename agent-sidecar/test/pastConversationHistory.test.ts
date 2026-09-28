import { describe, expect, it } from "vitest";
import {
  answerTextFromAssistantMessage,
  conversationExchangesFromSessionMessages,
  questionTextFromUserMessage,
  titleForPastConversation,
  type StoredSessionMessage
} from "../src/agent/pastConversationHistory.js";

const screenshotLabel = "screen 1 of 2 — cursor is on this screen (image dimensions: 1280x800 pixels, screen index 1)";

function clickyUserTurn(transcript: string): StoredSessionMessage {
  return {
    type: "user",
    parent_tool_use_id: null,
    message: {
      role: "user",
      content: [
        { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "AAAA" } },
        { type: "text", text: screenshotLabel },
        { type: "text", text: transcript }
      ]
    }
  };
}

function assistantMessage(blocks: unknown[], parentToolUseId: string | null = null): StoredSessionMessage {
  return { type: "assistant", parent_tool_use_id: parentToolUseId, message: { role: "assistant", content: blocks } };
}

const toolResultMessage: StoredSessionMessage = {
  type: "user",
  parent_tool_use_id: null,
  message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "ok" }] }
};

describe("questionTextFromUserMessage", () => {
  it("takes the transcript after the screenshots and their labels", () => {
    expect(questionTextFromUserMessage(clickyUserTurn("what is a minibatch").message)).toBe("what is a minibatch");
  });

  it("reads a plain-string message, which is how a spoken slash command is sent", () => {
    expect(questionTextFromUserMessage({ role: "user", content: "/compact keep the math" })).toBe("/compact keep the math");
  });

  it("is null for tool results, a turn that is only a screenshot, and interruption notices", () => {
    expect(questionTextFromUserMessage(toolResultMessage.message)).toBeNull();
    expect(questionTextFromUserMessage({ content: [{ type: "image" }, { type: "text", text: screenshotLabel }] })).toBeNull();
    expect(questionTextFromUserMessage({ content: [{ type: "text", text: "[Request interrupted by user]" }] })).toBeNull();
  });
});

describe("answerTextFromAssistantMessage", () => {
  it("joins text blocks and leaves out thinking and tool calls", () => {
    const message = assistantMessage([
      { type: "thinking", thinking: "hmm" },
      { type: "text", text: "sure, here it is." },
      { type: "tool_use", name: "mcp__clicky__point_at", input: {} },
      { type: "text", text: " it's up top." }
    ]).message;
    expect(answerTextFromAssistantMessage(message)).toBe("sure, here it is. it's up top.");
  });
});

describe("conversationExchangesFromSessionMessages", () => {
  const storedMessages: StoredSessionMessage[] = [
    clickyUserTurn("what is a minibatch"),
    assistantMessage([{ type: "thinking", thinking: "..." }]),
    assistantMessage([{ type: "text", text: "a small random group of rows." }]),
    clickyUserTurn("show me where it is in the code"),
    assistantMessage([{ type: "text", text: "taking a look." }]),
    assistantMessage([{ type: "tool_use", name: "Read", input: {} }]),
    toolResultMessage,
    assistantMessage([{ type: "text", text: "a subagent's own words" }], "toolu_9"),
    assistantMessage([{ type: "text", text: "it's the batch loop on line forty." }])
  ];

  it("pairs each question with everything said until the next one, across tool calls", () => {
    expect(conversationExchangesFromSessionMessages(storedMessages, 12)).toEqual([
      { question: "what is a minibatch", answer: "a small random group of rows." },
      { question: "show me where it is in the code", answer: "taking a look. it's the batch loop on line forty." }
    ]);
  });

  it("keeps only the most recent exchanges", () => {
    expect(conversationExchangesFromSessionMessages(storedMessages, 1)).toEqual([
      { question: "show me where it is in the code", answer: "taking a look. it's the batch loop on line forty." }
    ]);
    expect(conversationExchangesFromSessionMessages(storedMessages, 0)).toEqual([]);
  });

  it("ignores assistant text that comes before any question", () => {
    expect(conversationExchangesFromSessionMessages([assistantMessage([{ type: "text", text: "hello" }])], 12)).toEqual([]);
  });
});

describe("titleForPastConversation", () => {
  it("prefers a custom title, then the stored summary", () => {
    expect(titleForPastConversation({ customTitle: "Mini batch math", summary: "other" }, "q")).toBe("Mini batch math");
    expect(titleForPastConversation({ summary: "XNW plus B explanation" }, "q")).toBe("XNW plus B explanation");
  });

  it("never uses a screenshot label, falling back to the first question", () => {
    expect(titleForPastConversation({ summary: screenshotLabel }, "what is a minibatch")).toBe("what is a minibatch");
    expect(titleForPastConversation({ summary: screenshotLabel }, null)).toBe("untitled conversation");
  });

  it("shortens a long title to eighty characters", () => {
    const title = titleForPastConversation({ summary: "word ".repeat(40) }, null);
    expect(title.length).toBe(80);
    expect(title.endsWith("…")).toBe(true);
  });
});
