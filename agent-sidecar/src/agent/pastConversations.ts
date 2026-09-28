/**
 * Reads Clicky's saved conversations through the Agent SDK, for the menu
 * bar's "Past" menu and for refilling the transcript card when one is
 * reopened. Read-only: it never writes or deletes a session. Nothing is saved
 * when CLICKY_PERSIST_SESSIONS is false, so the list is then empty.
 */
import { getSessionMessages, listSessions } from "@anthropic-ai/claude-agent-sdk";
import {
  conversationExchangesFromSessionMessages,
  looksLikeScreenshotLabel,
  questionTextFromUserMessage,
  titleForPastConversation,
  type ConversationExchange
} from "./pastConversationHistory.js";

export interface PastConversationSummary {
  sessionId: string;
  title: string;
  lastModifiedMs: number;
}

/** Enough user messages to get past a turn that was only a slash command or an interruption. */
const MESSAGES_READ_FOR_A_FALLBACK_TITLE = 6;

/**
 * Clicky's own sessions in a workspace, newest first. The folder also holds
 * the Claude Code sessions a person ran there by hand; listing once with and
 * once without SDK-started ("programmatic") sessions leaves only the SDK ones,
 * which are Clicky's (and its spikes').
 */
export async function listPastConversations(
  projectDirectory: string,
  maximumConversationCount: number
): Promise<PastConversationSummary[]> {
  const [everySession, sessionsStartedByHand] = await Promise.all([
    listSessions({ dir: projectDirectory, includeWorktrees: false }),
    listSessions({ dir: projectDirectory, includeWorktrees: false, includeProgrammatic: false })
  ]);
  const sessionIdsStartedByHand = new Set(sessionsStartedByHand.map((sessionInfo) => sessionInfo.sessionId));
  const clickySessions = everySession
    .filter((sessionInfo) => !sessionIdsStartedByHand.has(sessionInfo.sessionId))
    .sort((earlierSession, laterSession) => laterSession.lastModified - earlierSession.lastModified)
    .slice(0, maximumConversationCount);

  return Promise.all(
    clickySessions.map(async (sessionInfo) => {
      const hasUsableStoredTitle =
        Boolean(sessionInfo.customTitle?.trim()) ||
        (sessionInfo.summary.trim() !== "" && !looksLikeScreenshotLabel(sessionInfo.summary));
      const firstQuestionText = hasUsableStoredTitle
        ? null
        : await firstQuestionOfSession(sessionInfo.sessionId, projectDirectory);
      return {
        sessionId: sessionInfo.sessionId,
        title: titleForPastConversation(sessionInfo, firstQuestionText),
        lastModifiedMs: sessionInfo.lastModified
      };
    })
  );
}

/** The most recent question and answer pairs of a saved session, oldest first. */
export async function loadConversationExchanges(
  sessionId: string,
  projectDirectory: string,
  maximumExchangeCount: number
): Promise<ConversationExchange[]> {
  const storedMessages = await getSessionMessages(sessionId, { dir: projectDirectory });
  return conversationExchangesFromSessionMessages(storedMessages, maximumExchangeCount);
}

async function firstQuestionOfSession(sessionId: string, projectDirectory: string): Promise<string | null> {
  const storedMessages = await getSessionMessages(sessionId, {
    dir: projectDirectory,
    limit: MESSAGES_READ_FOR_A_FALLBACK_TITLE
  });
  for (const storedMessage of storedMessages) {
    if (storedMessage.type !== "user") continue;
    const questionText = questionTextFromUserMessage(storedMessage.message);
    if (questionText !== null) return questionText;
  }
  return null;
}
