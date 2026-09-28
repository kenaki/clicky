//
//  CompanionTranscriptPanel.swift
//  leanring-buddy
//
//  Frosted panel pinned to the top right of the cursor's screen that shows
//  the current voice turn as text: the user's question, then the answer
//  sentence by sentence as the sidecar streams it. The answer text arrives
//  in seconds while the Spark voice runs slower than real time, so the
//  panel lets the user read ahead; the sentence being spoken is marked with
//  the overlay's blue bar so the voice can be followed.
//
//  Click-through (ignoresMouseEvents) and never activates the app, so it
//  never blocks what is underneath. Screen captures leave out every Clicky
//  window, so the panel never shows up in what Claude sees.
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

    enum SentencePlaybackState {
        case upcoming, speaking, spoken, settled
    }

    @Published var userTranscript: String = ""
    @Published var answerSentences: [AnswerSentence] = []
    /// The sentence playing right now; nil between sentences and before the first.
    @Published var speakingSentenceIndex: Int?
    /// The latest sentence that has started playing, so everything up to it counts as spoken.
    @Published var highestStartedSentenceIndex: Int?
    @Published var isAnswerComplete: Bool = false
    @Published var isSpeechFinished: Bool = false
    /// The answer area's height limit, set per screen; past it the answer scrolls.
    @Published var maximumCardHeight: CGFloat = 440

    func reset(userTranscript: String) {
        self.userTranscript = userTranscript
        answerSentences = []
        speakingSentenceIndex = nil
        highestStartedSentenceIndex = nil
        isAnswerComplete = false
        isSpeechFinished = false
    }

    func playbackState(ofSentenceIndex sentenceIndex: Int) -> SentencePlaybackState {
        if isSpeechFinished { return .settled }
        if sentenceIndex == speakingSentenceIndex { return .speaking }
        if let highestStartedSentenceIndex, sentenceIndex <= highestStartedSentenceIndex { return .spoken }
        return .upcoming
    }

    /// Short lowercase status for the header, in the app's voice.
    var statusText: String {
        if isSpeechFinished { return "clicky" }
        if speakingSentenceIndex != nil { return "speaking" }
        if answerSentences.isEmpty { return isAnswerComplete ? "clicky" : "thinking" }
        return highestStartedSentenceIndex == nil ? "getting the voice ready" : "voice is catching up"
    }

    var isWorking: Bool {
        !isSpeechFinished && !(answerSentences.isEmpty && isAnswerComplete)
    }
}

// MARK: - Panel Manager

@MainActor
final class CompanionTranscriptPanelManager {
    private let transcriptViewModel = CompanionTranscriptViewModel()
    private var transcriptPanel: NSPanel?
    /// Bumped on every show and hide so a fade that finishes late never hides a newer turn.
    private var panelVisibilityGeneration = 0

    private static let cardWidth: CGFloat = 360
    /// Gap between the card and the screen's top and right edges; also room for the shadow.
    private static let cardMargin: CGFloat = 16
    /// Extra transparent room under the card so its shadow is not cut off.
    private static let shadowRoomBelowCard: CGFloat = 28

    /// Clears the previous turn and shows the panel with the user's question.
    func beginTurn(userTranscript: String) {
        transcriptViewModel.reset(userTranscript: userTranscript)
        showPanelOnScreenWithCursor()
    }

    func appendSentence(sentenceIndex: Int, text: String) {
        guard !transcriptViewModel.answerSentences.contains(where: { $0.id == sentenceIndex }) else { return }
        transcriptViewModel.answerSentences.append(.init(id: sentenceIndex, text: text))
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
    }

    func fadeOutAndHide() {
        guard let transcriptPanel, transcriptPanel.isVisible else { return }
        panelVisibilityGeneration += 1
        let fadeGeneration = panelVisibilityGeneration
        NSAnimationContext.runAnimationGroup({ animationContext in
            animationContext.duration = DS.Animation.slow
            transcriptPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.panelVisibilityGeneration == fadeGeneration else { return }
                self.transcriptPanel?.orderOut(nil)
            }
        })
    }

    // MARK: - Private

    private func showPanelOnScreenWithCursor() {
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        let transcriptPanel = transcriptPanelCreatedIfNeeded()
        let visibleFrame = targetScreen.visibleFrame

        let maximumCardHeight = min(440, visibleFrame.height * 0.5)
        transcriptViewModel.maximumCardHeight = maximumCardHeight

        // A fixed-size transparent window; the card is pinned to its top right
        // and sizes itself to the text inside it.
        let panelSize = CGSize(
            width: Self.cardWidth + 2 * Self.cardMargin,
            height: maximumCardHeight + Self.cardMargin + Self.shadowRoomBelowCard
        )
        let panelOrigin = CGPoint(x: visibleFrame.maxX - panelSize.width, y: visibleFrame.maxY - panelSize.height)
        transcriptPanel.setFrame(NSRect(origin: panelOrigin, size: panelSize), display: false)

        panelVisibilityGeneration += 1
        if !transcriptPanel.isVisible || transcriptPanel.alphaValue < 1 {
            transcriptPanel.alphaValue = 0
            transcriptPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = DS.Animation.normal
                transcriptPanel.animator().alphaValue = 1
            }
        }
    }

    private func transcriptPanelCreatedIfNeeded() -> NSPanel {
        if let transcriptPanel { return transcriptPanel }

        let newTranscriptPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Below the cursor overlay (.screenSaver), so the blue cursor flies over it.
        newTranscriptPanel.level = .statusBar
        newTranscriptPanel.isOpaque = false
        newTranscriptPanel.backgroundColor = .clear
        newTranscriptPanel.hasShadow = false
        newTranscriptPanel.ignoresMouseEvents = true
        newTranscriptPanel.hidesOnDeactivate = false
        newTranscriptPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newTranscriptPanel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(
            rootView: CompanionTranscriptPanelView(
                transcriptViewModel: transcriptViewModel,
                cardWidth: Self.cardWidth,
                cardMargin: Self.cardMargin
            )
        )
        // The window keeps the size set above; don't let SwiftUI resize it.
        hostingView.sizingOptions = []
        newTranscriptPanel.contentView = hostingView

        transcriptPanel = newTranscriptPanel
        return newTranscriptPanel
    }
}

// MARK: - SwiftUI View

private struct CompanionTranscriptPanelView: View {
    @ObservedObject var transcriptViewModel: CompanionTranscriptViewModel
    let cardWidth: CGFloat
    let cardMargin: CGFloat

    private static let cardCornerRadius = DS.CornerRadius.extraLarge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader

            if !transcriptViewModel.userTranscript.isEmpty {
                Text(transcriptViewModel.userTranscript)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !transcriptViewModel.answerSentences.isEmpty {
                Rectangle()
                    .fill(DS.Colors.borderSubtle.opacity(0.6))
                    .frame(height: 0.5)
                answerBody
            }
        }
        .padding(14)
        .frame(width: cardWidth, alignment: .leading)
        .frame(maxHeight: transcriptViewModel.maximumCardHeight, alignment: .top)
        .background(frostedCardBackground)
        .padding([.top, .trailing], cardMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
        }
    }

    /// Short answers show as they are; long ones scroll, following the voice.
    private var answerBody: some View {
        ViewThatFits(in: .vertical) {
            answerSentenceList
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    answerSentenceList
                }
                .onAppear {
                    scrollToSpeakingSentence(using: scrollProxy)
                }
                .onChange(of: transcriptViewModel.speakingSentenceIndex) { _, _ in
                    scrollToSpeakingSentence(using: scrollProxy)
                }
            }
        }
    }

    private var answerSentenceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(transcriptViewModel.answerSentences) { answerSentence in
                answerSentenceRow(answerSentence)
                    .id(answerSentence.id)
            }
        }
    }

    private func answerSentenceRow(_ answerSentence: CompanionTranscriptViewModel.AnswerSentence) -> some View {
        let playbackState = transcriptViewModel.playbackState(ofSentenceIndex: answerSentence.id)
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 3)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 4, x: 0, y: 0)
                .opacity(playbackState == .speaking ? 1 : 0)
            Text(answerSentence.text)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundColor(textColor(for: playbackState))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: DS.Animation.normal), value: playbackState)
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

    private func scrollToSpeakingSentence(using scrollProxy: ScrollViewProxy) {
        guard let speakingSentenceIndex = transcriptViewModel.speakingSentenceIndex else { return }
        withAnimation(.easeInOut(duration: DS.Animation.normal)) {
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
                .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
        }
        .overlay(
            cardShape.stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 0.8)
        )
    }
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
