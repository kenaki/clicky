//
//  CompanionTranscriptPanel.swift
//  leanring-buddy
//
//  Frosted panel pinned to the top right of the cursor's screen that shows
//  the conversation as text: earlier exchanges from this run, then the
//  current question and its answer sentence by sentence as the sidecar
//  streams it. The sentence being spoken is marked with the overlay's blue
//  bar so the voice can be followed.
//
//  The window is exactly the card's size, resized as the text grows, so it
//  blocks nothing around the card and takes every click and scroll on it. A
//  close button hides it; a reply field sends the next turn. It never
//  activates the app. Screen captures leave out every Clicky window, so the
//  panel never shows up in what Claude sees. Animation speed comes from
//  CompanionTuningSettings.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionTranscriptViewModel: ObservableObject {
    struct AnswerSentence: Identifiable {
        /// The sidecar's `sentenceIndex`, 0-based and in order within a turn.
        let id: Int
        let text: String
    }

    struct CompletedExchange: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
    }

    enum SentencePlaybackState {
        case upcoming, speaking, spoken, settled
    }

    /// Claude asked to use a tool (chunk 6); answered by voice or with the card's buttons.
    struct PendingPermissionQuestion: Equatable {
        let permissionRequestId: String
        let question: String
        let answerHint: String
    }

    /// Earlier exchanges in this conversation, oldest first; kept for this app run only.
    @Published var earlierExchanges: [CompletedExchange] = []
    @Published var userTranscript: String = ""
    @Published var answerSentences: [AnswerSentence] = []
    /// Bumped per turn so the scroll view jumps to the new question.
    @Published var turnNumber: Int = 0
    /// The sentence playing right now; nil between sentences and before the first.
    @Published var speakingSentenceIndex: Int?
    /// The latest sentence that has started playing, so everything up to it counts as spoken.
    @Published var highestStartedSentenceIndex: Int?
    @Published var isAnswerComplete: Bool = false
    @Published var isSpeechFinished: Bool = false
    /// False when "speak answers" was off as the turn began: sentences show
    /// fully as they arrive, with no speaking highlight to wait for.
    @Published var isAnswerSpoken: Bool = true
    /// The card's height limit, set per screen; past it the conversation scrolls.
    @Published var maximumCardHeight: CGFloat = 440
    /// Multiplies animation speed (CompanionTuningSettings.transcriptPanelAnimationSpeed).
    @Published var animationSpeed: Double = 1
    @Published var pendingPermissionQuestion: PendingPermissionQuestion?

    /// Called with (permissionRequestId, allowed) when a card button is clicked.
    var permissionButtonHandler: ((String, Bool) -> Void)?
    /// Called with the text when a reply is sent from the card's field.
    var replyHandler: ((String) -> Void)?
    /// Called when the card's close button or Escape is used.
    var closeHandler: (() -> Void)?
    /// Called with a sentence's index when that line of the current answer is clicked.
    var replaySentenceHandler: ((Int) -> Void)?
    /// Called when the header's replay button is clicked: the whole current answer again.
    var replayWholeAnswerHandler: (() -> Void)?
    /// Called with an earlier answer's text when it is clicked.
    var replayEarlierAnswerHandler: ((String) -> Void)?
    /// Called when the header's stop button is clicked.
    var stopSpeakingHandler: (() -> Void)?
    /// The reply being typed.
    @Published var replyDraft: String = ""
    /// An earlier answer is being played again. Its lines have no sentence
    /// indexes, so this is what tells the header to offer stop.
    @Published var isReplayingEarlierAnswer = false

    /// Not published: written from layout and read by the pointer tracking.
    var isPointerOverCard = false

    private static let maximumEarlierExchangeCount = 12

    func beginNewTurn(userTranscript: String, isAnswerSpoken: Bool) {
        if !self.userTranscript.isEmpty && !answerSentences.isEmpty {
            earlierExchanges.append(.init(
                question: self.userTranscript,
                answer: answerSentences.map(\.text).joined(separator: " ")
            ))
            if earlierExchanges.count > Self.maximumEarlierExchangeCount {
                earlierExchanges.removeFirst(earlierExchanges.count - Self.maximumEarlierExchangeCount)
            }
        }
        self.userTranscript = userTranscript
        self.isAnswerSpoken = isAnswerSpoken
        answerSentences = []
        speakingSentenceIndex = nil
        highestStartedSentenceIndex = nil
        isAnswerComplete = false
        isSpeechFinished = false
        turnNumber += 1
    }

    func clearConversation() {
        pendingPermissionQuestion = nil
        earlierExchanges = []
        userTranscript = ""
        answerSentences = []
        speakingSentenceIndex = nil
        highestStartedSentenceIndex = nil
        isAnswerComplete = false
        isSpeechFinished = false
        isReplayingEarlierAnswer = false
    }

    func playbackState(ofSentenceIndex sentenceIndex: Int) -> SentencePlaybackState {
        if isSpeechFinished || !isAnswerSpoken { return .settled }
        if sentenceIndex == speakingSentenceIndex { return .speaking }
        if let highestStartedSentenceIndex, sentenceIndex <= highestStartedSentenceIndex { return .spoken }
        return .upcoming
    }

    /// Short lowercase status for the header, in the app's voice.
    var statusText: String {
        if pendingPermissionQuestion != nil { return "waiting for your ok" }
        if isReplayingEarlierAnswer { return "replaying" }
        if !isAnswerSpoken {
            if isAnswerComplete { return "clicky" }
            return answerSentences.isEmpty ? "thinking" : "writing"
        }
        if isSpeechFinished { return "clicky" }
        if speakingSentenceIndex != nil { return "speaking" }
        if answerSentences.isEmpty { return isAnswerComplete ? "clicky" : "thinking" }
        return highestStartedSentenceIndex == nil ? "getting the voice ready" : "voice is catching up"
    }

    var isWorking: Bool {
        if !isAnswerSpoken { return !isAnswerComplete }
        return !isSpeechFinished && !(answerSentences.isEmpty && isAnswerComplete)
    }

    /// Lines can be played again once the answer has fully arrived; before
    /// that the voice is still busy with it.
    var isReplayAvailable: Bool {
        isAnswerComplete
    }

    /// Something is being said, or is about to be, for the current answer or a replay.
    var isStopSpeakingAvailable: Bool {
        if isReplayingEarlierAnswer { return true }
        return isAnswerSpoken && !isSpeechFinished && !(answerSentences.isEmpty && isAnswerComplete)
    }

    func animationDuration(_ baseDurationSeconds: Double) -> Double {
        baseDurationSeconds / max(animationSpeed, 0.1)
    }
}

// MARK: - Panel Manager

@MainActor
final class CompanionTranscriptPanelManager {
    private let tuningSettings: CompanionTuningSettings
    private let transcriptViewModel = CompanionTranscriptViewModel()
    private var transcriptPanel: NSPanel?
    /// Bumped on every show and hide so a fade that finishes late never hides a newer turn.
    private var panelVisibilityGeneration = 0
    /// Checks the pointer position while the card is up; see startTrackingPointer.
    private var pointerPollingTask: Task<Void, Never>?

    /// The card's top-right corner in screen coordinates; the window grows down and left from it.
    private var cardTopRightCorner: CGPoint = .zero
    /// Set when the card's content changes; the next few pointer checks
    /// re-measure. SwiftUI applies a change on a later run-loop pass, so one
    /// check straight after it could still measure the old content.
    private var windowResizeChecksRemaining = 0
    private var cardContentChangeCancellable: AnyCancellable?
    /// A second copy of the card that is never on screen, used only to measure
    /// it. The window's own hosting view cannot: with sizingOptions [] its
    /// fittingSize is zero, and with intrinsic sizing AppKit would resize the
    /// window from its bottom edge. NSHostingController.sizeThatFits returns
    /// the full maximum height whatever the content (all checked 2026-09-28).
    private lazy var cardMeasuringHostingView: NSHostingView<CompanionTranscriptPanelView> = {
        let cardMeasuringHostingView = NSHostingView(
            rootView: CompanionTranscriptPanelView(
                transcriptViewModel: transcriptViewModel,
                tuningSettings: tuningSettings,
                cardWidth: Self.cardWidth
            )
        )
        cardMeasuringHostingView.sizingOptions = [.intrinsicContentSize]
        return cardMeasuringHostingView
    }()

    private static let cardWidth: CGFloat = 360
    /// Gap between the card and the screen's top and right edges.
    private static let cardMargin: CGFloat = 16
    /// The smallest the card gets, so a nearly empty one still shows its header and reply field.
    private static let minimumCardHeight: CGFloat = 80

    init(tuningSettings: CompanionTuningSettings) {
        self.tuningSettings = tuningSettings
        transcriptViewModel.closeHandler = { [weak self] in
            self?.fadeOutAndHide()
        }
        cardContentChangeCancellable = transcriptViewModel.objectWillChange.sink { [weak self] _ in
            self?.windowResizeChecksRemaining = 3
        }
    }

    /// Moves the previous exchange into the history and shows the new question.
    func beginTurn(userTranscript: String) {
        transcriptViewModel.animationSpeed = tuningSettings.transcriptPanelAnimationSpeed
        transcriptViewModel.beginNewTurn(
            userTranscript: userTranscript,
            isAnswerSpoken: tuningSettings.isSpeakingAnswersEnabled
        )
        showPanelOnScreenWithCursor()
    }

    func appendSentence(sentenceIndex: Int, text: String) {
        guard !transcriptViewModel.answerSentences.contains(where: { $0.id == sentenceIndex }) else { return }
        transcriptViewModel.answerSentences.append(.init(id: sentenceIndex, text: text))
    }

    /// Adds a line of the app's own (an error, when answers are not spoken)
    /// after the answer's sentences.
    func appendNote(_ noteText: String) {
        let nextSentenceIndex = (transcriptViewModel.answerSentences.map(\.id).max() ?? -1) + 1
        transcriptViewModel.answerSentences.append(.init(id: nextSentenceIndex, text: noteText))
    }

    /// The current answer's lines with their sentence indexes, for replaying it.
    var currentAnswerSentences: [(sentenceIndex: Int, text: String)] {
        transcriptViewModel.answerSentences.map { ($0.id, $0.text) }
    }

    /// Lines of the current answer are about to be spoken again: bring the
    /// speaking highlight back, even if the answer was not spoken the first time.
    func beginReplayOfCurrentAnswer() {
        transcriptViewModel.isReplayingEarlierAnswer = false
        transcriptViewModel.isAnswerSpoken = true
        transcriptViewModel.speakingSentenceIndex = nil
        transcriptViewModel.highestStartedSentenceIndex = nil
        transcriptViewModel.isSpeechFinished = false
    }

    /// An earlier answer is about to be spoken again (no per-line highlight).
    func beginReplayOfEarlierAnswer() {
        transcriptViewModel.isReplayingEarlierAnswer = true
    }

    /// Called with a sentence's index when its audio starts, and nil when the voice runs dry.
    func updateSpeakingSentence(sentenceIndex: Int?) {
        guard !transcriptViewModel.isSpeechFinished else { return }
        transcriptViewModel.speakingSentenceIndex = sentenceIndex
        if let sentenceIndex {
            transcriptViewModel.highestStartedSentenceIndex = max(transcriptViewModel.highestStartedSentenceIndex ?? sentenceIndex, sentenceIndex)
        }
    }

    func markAnswerComplete() {
        transcriptViewModel.isAnswerComplete = true
    }

    func markSpeechFinished() {
        transcriptViewModel.speakingSentenceIndex = nil
        transcriptViewModel.isSpeechFinished = true
        transcriptViewModel.isReplayingEarlierAnswer = false
    }

    /// Called with (permissionRequestId, allowed) when Allow or Deny is clicked on the card.
    var permissionAnswerHandler: ((String, Bool) -> Void)? {
        get { transcriptViewModel.permissionButtonHandler }
        set { transcriptViewModel.permissionButtonHandler = newValue }
    }

    /// Called with the text when a reply is typed into the card and sent.
    var replyHandler: ((String) -> Void)? {
        get { transcriptViewModel.replyHandler }
        set { transcriptViewModel.replyHandler = newValue }
    }

    /// Called with a sentence's index when a line of the current answer is clicked.
    var replaySentenceHandler: ((Int) -> Void)? {
        get { transcriptViewModel.replaySentenceHandler }
        set { transcriptViewModel.replaySentenceHandler = newValue }
    }

    /// Called when the header's replay button is clicked.
    var replayWholeAnswerHandler: (() -> Void)? {
        get { transcriptViewModel.replayWholeAnswerHandler }
        set { transcriptViewModel.replayWholeAnswerHandler = newValue }
    }

    /// Called with an earlier answer's text when it is clicked.
    var replayEarlierAnswerHandler: ((String) -> Void)? {
        get { transcriptViewModel.replayEarlierAnswerHandler }
        set { transcriptViewModel.replayEarlierAnswerHandler = newValue }
    }

    /// Called when the header's stop button is clicked.
    var stopSpeakingHandler: (() -> Void)? {
        get { transcriptViewModel.stopSpeakingHandler }
        set { transcriptViewModel.stopSpeakingHandler = newValue }
    }

    /// Shows Claude's permission question on the card, bringing the panel back if it faded.
    func showPermissionQuestion(permissionRequestId: String, question: String, answerHint: String) {
        transcriptViewModel.pendingPermissionQuestion = .init(
            permissionRequestId: permissionRequestId,
            question: question,
            answerHint: answerHint
        )
        if transcriptPanel?.isVisible != true || (transcriptPanel?.alphaValue ?? 0) < 1 {
            showPanelOnScreenWithCursor()
        }
    }

    func clearPermissionQuestion() {
        transcriptViewModel.pendingPermissionQuestion = nil
    }

    /// Empties the history, for a new conversation.
    func clearConversation() {
        transcriptViewModel.clearConversation()
    }

    /// A reopened conversation: its recent exchanges become the history and
    /// nothing is in progress. Shown only when it was picked from the menu; a
    /// resume at launch fills the card quietly for the next question.
    func replaceConversation(withEarlierExchanges earlierExchanges: [(question: String, answer: String)], isShowingCard: Bool) {
        transcriptViewModel.clearConversation()
        transcriptViewModel.earlierExchanges = earlierExchanges.map {
            CompanionTranscriptViewModel.CompletedExchange(question: $0.question, answer: $0.answer)
        }
        transcriptViewModel.isAnswerComplete = true
        transcriptViewModel.isSpeechFinished = true
        transcriptViewModel.turnNumber += 1
        guard isShowingCard else { return }
        transcriptViewModel.animationSpeed = tuningSettings.transcriptPanelAnimationSpeed
        showPanelOnScreenWithCursor()
    }

    /// The card never hides by itself; this runs only when you close it (the ×
    /// or Escape) or start a new conversation.
    func fadeOutAndHide() {
        guard let transcriptPanel, transcriptPanel.isVisible else { return }
        panelVisibilityGeneration += 1
        let fadeGeneration = panelVisibilityGeneration
        stopTrackingPointer()
        NSAnimationContext.runAnimationGroup({ animationContext in
            animationContext.duration = transcriptViewModel.animationDuration(DS.Animation.slow)
            transcriptPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.panelVisibilityGeneration == fadeGeneration else { return }
                self.transcriptPanel?.orderOut(nil)
            }
        })
    }

    // MARK: - Showing

    private func showPanelOnScreenWithCursor() {
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        let transcriptPanel = transcriptPanelCreatedIfNeeded()
        let visibleFrame = targetScreen.visibleFrame

        transcriptViewModel.maximumCardHeight = min(440, visibleFrame.height * 0.5)
        cardTopRightCorner = CGPoint(
            x: visibleFrame.maxX - Self.cardMargin,
            y: visibleFrame.maxY - Self.cardMargin
        )
        resizeWindowToFitCard()

        panelVisibilityGeneration += 1
        if !transcriptPanel.isVisible || transcriptPanel.alphaValue < 1 {
            transcriptPanel.alphaValue = 0
            transcriptPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = transcriptViewModel.animationDuration(DS.Animation.normal)
                transcriptPanel.animator().alphaValue = 1
            }
        }
        startTrackingPointer()
    }

    private func transcriptPanelCreatedIfNeeded() -> NSPanel {
        if let transcriptPanel { return transcriptPanel }

        let newTranscriptPanel = KeyableTranscriptPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Below the cursor overlay (.screenSaver), so the blue cursor flies over it.
        newTranscriptPanel.level = .statusBar
        newTranscriptPanel.isOpaque = false
        newTranscriptPanel.backgroundColor = .clear
        // The window is exactly the card, so the system shadow follows its
        // rounded shape (the corners outside it are transparent).
        newTranscriptPanel.hasShadow = true
        // Always takes the mouse: the window is only as big as the card, so
        // nothing around the card is blocked. An earlier version used a bigger
        // transparent window and switched this on only over the card; that
        // switch never fired (2026-09-28), leaving the card unclickable.
        newTranscriptPanel.ignoresMouseEvents = false
        newTranscriptPanel.hidesOnDeactivate = false
        newTranscriptPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newTranscriptPanel.isExcludedFromWindowsMenu = true

        let hostingView = FirstClickHostingView(
            rootView: CompanionTranscriptPanelView(
                transcriptViewModel: transcriptViewModel,
                tuningSettings: tuningSettings,
                cardWidth: Self.cardWidth
            )
        )
        // resizeWindowToFitCard sizes the window; SwiftUI must not resize it
        // itself, because AppKit would grow it upward from the bottom edge.
        hostingView.sizingOptions = []
        newTranscriptPanel.contentView = hostingView

        transcriptPanel = newTranscriptPanel
        return newTranscriptPanel
    }

    // MARK: - Size and Pointer

    /// Fits the window to the card's content (up to maximumCardHeight, past
    /// which the conversation scrolls), keeping the top-right corner fixed.
    private func resizeWindowToFitCard() {
        guard let transcriptPanel else { return }
        let cardHeight = min(
            max(cardMeasuringHostingView.fittingSize.height, Self.minimumCardHeight),
            transcriptViewModel.maximumCardHeight
        )
        let cardFrame = NSRect(
            x: cardTopRightCorner.x - Self.cardWidth,
            y: cardTopRightCorner.y - cardHeight,
            width: Self.cardWidth,
            height: cardHeight
        )
        guard transcriptPanel.frame != cardFrame else { return }
        transcriptPanel.setFrame(cardFrame, display: true)
        transcriptPanel.invalidateShadow()
    }

    /// While the card is up: resize after content changes, and note whether
    /// the pointer is on it (the fade and the auto-scroll wait for it to leave).
    /// Polled rather than watched with event monitors, because Clicky is never
    /// the active app and mouse-moved events did not reliably reach it.
    private func startTrackingPointer() {
        guard pointerPollingTask == nil else { return }
        pointerPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateSizeAndPointerOverCard()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func stopTrackingPointer() {
        pointerPollingTask?.cancel()
        pointerPollingTask = nil
        transcriptViewModel.isPointerOverCard = false
    }

    private func updateSizeAndPointerOverCard() {
        guard let transcriptPanel else { return }
        if windowResizeChecksRemaining > 0 {
            windowResizeChecksRemaining -= 1
            resizeWindowToFitCard()
        }
        let isPointerOverCard = transcriptPanel.isVisible && transcriptPanel.frame.contains(NSEvent.mouseLocation)
        if transcriptViewModel.isPointerOverCard != isPointerOverCard {
            transcriptViewModel.isPointerOverCard = isPointerOverCard
        }
    }
}

// MARK: - SwiftUI View

private struct CompanionTranscriptPanelView: View {
    @ObservedObject var transcriptViewModel: CompanionTranscriptViewModel
    /// For the speed menu; the same setting as the menu bar panel's slider.
    @ObservedObject var tuningSettings: CompanionTuningSettings
    let cardWidth: CGFloat

    private static let cardCornerRadius = DS.CornerRadius.extraLarge
    private static let currentQuestionScrollID = "currentQuestion"
    private static let permissionQuestionScrollID = "permissionQuestion"
    /// Speeds offered on the card, inside CompanionTuningSettings.speechSpeedRange.
    private static let speechSpeedChoices: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    @FocusState private var isReplyFieldFocused: Bool
    @State private var isCloseButtonHovered = false
    @State private var isSpeedMenuHovered = false
    @State private var isReplySendButtonHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
            conversationBody
            replyField
        }
        .padding(14)
        .frame(width: cardWidth, alignment: .leading)
        .frame(maxHeight: transcriptViewModel.maximumCardHeight, alignment: .top)
        .background(frostedCardBackground)
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 6, height: 6)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 4, x: 0, y: 0)
                .opacity(transcriptViewModel.isWorking ? 1 : 0.5)
            Text(transcriptViewModel.statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .animation(nil, value: transcriptViewModel.statusText)
            Spacer(minLength: 0)
            speechSpeedMenu
            replayOrStopButton
            closeButton
        }
    }

    /// Kokoro's speaking rate. It applies from the next sentence the voice
    /// requests; the macOS fallback voice does not use it.
    private var speechSpeedMenu: some View {
        Menu {
            ForEach(Self.speechSpeedChoices, id: \.self) { speechSpeedChoice in
                Button(action: { tuningSettings.speechSpeed = speechSpeedChoice }) {
                    if abs(tuningSettings.speechSpeed - speechSpeedChoice) < 0.01 {
                        Label(Self.speedLabel(speechSpeedChoice), systemImage: "checkmark")
                    } else {
                        Text(Self.speedLabel(speechSpeedChoice))
                    }
                }
            }
        } label: {
            Text(Self.speedLabel(tuningSettings.speechSpeed))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundColor(isSpeedMenuHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(Color.white.opacity(isSpeedMenuHovered ? 0.14 : 0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .onHover { isHovering in isSpeedMenuHovered = isHovering }
        .help("Speaking speed")
    }

    /// "1×", "1.25×": no trailing zeros.
    private static func speedLabel(_ speechSpeed: Double) -> String {
        let roundedSpeed = (speechSpeed * 100).rounded() / 100
        return "\(roundedSpeed.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    /// Stop while something is being said; replay the whole answer once it has arrived.
    @ViewBuilder
    private var replayOrStopButton: some View {
        if transcriptViewModel.isStopSpeakingAvailable {
            CardHeaderIconButton(systemImageName: "stop.fill", helpText: "Stop speaking") {
                transcriptViewModel.stopSpeakingHandler?()
            }
        } else if transcriptViewModel.isReplayAvailable && !transcriptViewModel.answerSentences.isEmpty {
            CardHeaderIconButton(systemImageName: "play.fill", helpText: "Play the answer again (or click a line)") {
                transcriptViewModel.replayWholeAnswerHandler?()
            }
        }
    }

    /// Hides the card now; the conversation stays and comes back on the next turn.
    private var closeButton: some View {
        Button(action: { transcriptViewModel.closeHandler?() }) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isCloseButtonHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(isCloseButtonHovered ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in isCloseButtonHovered = isHovering }
        .help("Hide (Esc while typing)")
    }

    /// Type a follow-up without going back to the menu bar. Return sends it as
    /// the next turn in the same session and keeps the field focused for
    /// another; Escape hides the card.
    private var replyField: some View {
        let fieldShape = RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
        let isReplyDraftEmpty = transcriptViewModel.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 6) {
            TextField("Reply…", text: $transcriptViewModel.replyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isReplyFieldFocused)
                .onSubmit(sendReply)
                .onExitCommand { transcriptViewModel.closeHandler?() }
            Button(action: sendReply) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(
                        isReplyDraftEmpty
                            ? DS.Colors.textTertiary.opacity(0.6)
                            : DS.Colors.accent.opacity(isReplySendButtonHovered ? 0.85 : 1)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(isReplyDraftEmpty)
            .onHover { isHovering in isReplySendButtonHovered = isHovering }
            .help("Send (Return)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(fieldShape.fill(Color.white.opacity(0.07)))
        .overlay(
            fieldShape.stroke(
                isReplyFieldFocused ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle.opacity(0.7),
                lineWidth: isReplyFieldFocused ? 1 : 0.5
            )
        )
    }

    private func sendReply() {
        let replyText = transcriptViewModel.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replyText.isEmpty else { return }
        transcriptViewModel.replyDraft = ""
        transcriptViewModel.replyHandler?(replyText)
    }

    /// Short conversations show as they are; long ones scroll, following the
    /// voice unless the pointer is on the card.
    private var conversationBody: some View {
        ViewThatFits(in: .vertical) {
            conversationList
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    conversationList
                }
                .onAppear {
                    scrollToCurrentQuestion(using: scrollProxy)
                    scrollToSpeakingSentence(using: scrollProxy)
                }
                .onChange(of: transcriptViewModel.turnNumber) { _, _ in
                    scrollToCurrentQuestion(using: scrollProxy)
                }
                .onChange(of: transcriptViewModel.speakingSentenceIndex) { _, _ in
                    scrollToSpeakingSentence(using: scrollProxy)
                }
                .onChange(of: transcriptViewModel.pendingPermissionQuestion) { _, newQuestion in
                    guard newQuestion != nil else { return }
                    withAnimation(.easeInOut(duration: transcriptViewModel.animationDuration(DS.Animation.normal))) {
                        scrollProxy.scrollTo(Self.permissionQuestionScrollID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(transcriptViewModel.earlierExchanges) { earlierExchange in
                earlierExchangeView(earlierExchange)
                cardDivider
            }
            currentExchangeView
                .id(Self.currentQuestionScrollID)
        }
    }

    private func earlierExchangeView(_ earlierExchange: CompanionTranscriptViewModel.CompletedExchange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(earlierExchange.question)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ReplayOnClickRow(
                isReplayAvailable: transcriptViewModel.isReplayAvailable,
                replayHelpText: "Play this answer again",
                replayAction: { transcriptViewModel.replayEarlierAnswerHandler?(earlierExchange.answer) }
            ) {
                Text(earlierExchange.answer)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundColor(DS.Colors.textSecondary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentExchangeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !transcriptViewModel.userTranscript.isEmpty {
                Text(transcriptViewModel.userTranscript)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !transcriptViewModel.answerSentences.isEmpty {
                cardDivider
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(transcriptViewModel.answerSentences) { answerSentence in
                        answerSentenceRow(answerSentence)
                            .id(answerSentence.id)
                    }
                    #if DEBUG
                    CompanionLatexSpikeSampleEquationRows(cardWidth: cardWidth)
                    #endif
                }
            }
            if let pendingPermissionQuestion = transcriptViewModel.pendingPermissionQuestion {
                permissionQuestionView(pendingPermissionQuestion)
                    .id(Self.permissionQuestionScrollID)
            }
        }
    }

    /// Blue-tinted box with the question, how to answer by voice, and buttons.
    private func permissionQuestionView(_ pendingPermissionQuestion: CompanionTranscriptViewModel.PendingPermissionQuestion) -> some View {
        let boxShape = RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.top, 2)
                Text(pendingPermissionQuestion.question)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(pendingPermissionQuestion.answerHint)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            HStack(spacing: 8) {
                permissionButton(title: "Allow", isPrimary: true) {
                    transcriptViewModel.permissionButtonHandler?(pendingPermissionQuestion.permissionRequestId, true)
                }
                permissionButton(title: "Deny", isPrimary: false) {
                    transcriptViewModel.permissionButtonHandler?(pendingPermissionQuestion.permissionRequestId, false)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(boxShape.fill(DS.Colors.accent.opacity(0.14)))
        .overlay(boxShape.stroke(DS.Colors.blue400.opacity(0.35), lineWidth: 0.8))
    }

    private func permissionButton(title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        let buttonShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isPrimary ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(buttonShape.fill(isPrimary ? DS.Colors.accent : Color.white.opacity(0.06)))
                .overlay(buttonShape.stroke(isPrimary ? Color.clear : DS.Colors.borderSubtle, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle.opacity(0.6))
            .frame(height: 0.5)
    }

    private func answerSentenceRow(_ answerSentence: CompanionTranscriptViewModel.AnswerSentence) -> some View {
        let playbackState = transcriptViewModel.playbackState(ofSentenceIndex: answerSentence.id)
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 3)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 4, x: 0, y: 0)
                .opacity(playbackState == .speaking ? 1 : 0)
            ReplayOnClickRow(
                isReplayAvailable: transcriptViewModel.isReplayAvailable,
                replayHelpText: "Play this line again",
                replayAction: { transcriptViewModel.replaySentenceHandler?(answerSentence.id) }
            ) {
                Text(answerSentence.text)
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundColor(textColor(for: playbackState))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: transcriptViewModel.animationDuration(DS.Animation.normal)), value: playbackState)
    }

    private func textColor(for playbackState: CompanionTranscriptViewModel.SentencePlaybackState) -> Color {
        switch playbackState {
        case .speaking, .settled:
            return DS.Colors.textPrimary
        case .upcoming:
            // Readable enough to read ahead of the voice.
            return DS.Colors.textPrimary.opacity(0.72)
        case .spoken:
            return DS.Colors.textSecondary.opacity(0.8)
        }
    }

    private func scrollToCurrentQuestion(using scrollProxy: ScrollViewProxy) {
        guard !transcriptViewModel.isPointerOverCard else { return }
        withAnimation(.easeInOut(duration: transcriptViewModel.animationDuration(DS.Animation.normal))) {
            scrollProxy.scrollTo(Self.currentQuestionScrollID, anchor: .top)
        }
    }

    private func scrollToSpeakingSentence(using scrollProxy: ScrollViewProxy) {
        guard !transcriptViewModel.isPointerOverCard,
              let speakingSentenceIndex = transcriptViewModel.speakingSentenceIndex else { return }
        withAnimation(.easeInOut(duration: transcriptViewModel.animationDuration(DS.Animation.normal))) {
            scrollProxy.scrollTo(speakingSentenceIndex, anchor: .center)
        }
    }

    /// Dark frosted glass: the desktop blurs through, tinted toward the app's
    /// background, with the same subtle outline as the menu bar panel.
    private var frostedCardBackground: some View {
        let cardShape = RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
        return ZStack {
            BehindWindowBlurView(cornerRadius: Self.cardCornerRadius)
            cardShape
                .fill(DS.Colors.background.opacity(0.45))
        }
        .overlay(
            cardShape.stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 0.8)
        )
    }
}

/// A small round icon button for the card's header, brightening on hover.
private struct CardHeaderIconButton: View {
    let systemImageName: String
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(isHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(isHovered ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in isHovered = isHovering }
        .help(helpText)
    }
}

/// A line of the card that plays again when clicked, showing a speaker icon
/// and a faint highlight on hover to say so. While an answer is still coming
/// in the voice is busy with it, so clicks do nothing and nothing highlights.
/// The click is guarded instead of the button being disabled, because a
/// disabled plain button would dim the text.
private struct ReplayOnClickRow<RowContent: View>: View {
    let isReplayAvailable: Bool
    let replayHelpText: String
    let replayAction: () -> Void
    @ViewBuilder let rowContent: () -> RowContent

    @State private var isHovered = false

    private var isShowingReplayHint: Bool { isHovered && isReplayAvailable }

    var body: some View {
        Button(action: {
            guard isReplayAvailable else { return }
            replayAction()
        }) {
            HStack(alignment: .top, spacing: 4) {
                rowContent()
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 3)
                    .opacity(isShowingReplayHint ? 1 : 0)
            }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isShowingReplayHint ? 0.05 : 0))
                    .padding(-3)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: isReplayAvailable)
        .onHover { isHovering in isHovered = isHovering }
        .help(isReplayAvailable ? replayHelpText : "")
    }
}

/// A borderless panel refuses key status by default, which would leave the
/// reply field unable to take typing. Being a non-activating panel, it becomes
/// key without activating Clicky, so the app you were in stays in front.
private final class KeyableTranscriptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel is usually not key, so without this the first click on a card
/// button would only be spent focusing the window.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Blurs whatever is behind the window (other apps, the desktop), clipped to rounded corners.
private struct BehindWindowBlurView: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.appearance = NSAppearance(named: .darkAqua)
        visualEffectView.maskImage = Self.roundedCornerMaskImage(cornerRadius: cornerRadius)
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded rectangle; the cap insets keep the corners round at any size.
    private static func roundedCornerMaskImage(cornerRadius: CGFloat) -> NSImage {
        let edgeLength = 2 * cornerRadius + 1
        let maskImage = NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { drawingRect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: drawingRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        maskImage.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        maskImage.resizingMode = .stretch
        return maskImage
    }
}
