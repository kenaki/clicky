//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    // MARK: - Agent Sidecar State

    /// Voice turns go to the agent sidecar (agent-sidecar/, the Claude Agent SDK
    /// in a Node process) instead of ClaudeAPI. See docs/ipc-protocol.md.
    private let agentSidecarClient = AgentSidecarClient()
    private let sidecarProcessController = SidecarProcessController()
    /// Built-in macOS voice: speaks answers when no Spark voice server is configured,
    /// and always speaks error fallbacks, which must work even when the Spark is down.
    private let systemSpeechSentenceQueue = SystemSpeechSentenceQueue()
    /// Miso on the Spark (spark-tts-server/), when `SparkSpeechBaseURL` is set.
    private lazy var sparkSpeechSentenceQueue: SparkSpeechSentenceQueue? = {
        let sparkSpeechSentenceQueue = SparkSpeechSentenceQueue.makeIfConfigured()
        sparkSpeechSentenceQueue?.sentenceFailureHandler = { [weak self] failedSentenceText in
            // Say the words in the backup voice rather than drop them.
            self?.systemSpeechSentenceQueue.enqueueSentence(failedSentenceText)
        }
        return sparkSpeechSentenceQueue
    }()
    /// The in-flight attach-or-spawn, shared so two quick utterances never start two sidecars.
    private var sidecarConnectionTask: Task<Void, Error>?
    /// The utterance whose turn is running; sentences from any other turn are stale.
    private var currentAgentUtteranceId: String?
    /// Resumed when the sidecar finishes, fails, or abandons the turn for that utterance.
    private var agentTurnCompletionContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    /// The most recent captures, in screen-index order (index 0 is screen 1, the
    /// cursor screen). Overlay coordinates from the sidecar refer to these.
    private var latestScreenCaptures: [CompanionScreenCapture] = []
    private var screenCaptureBadgeHideTask: Task<Void, Never>?

    /// Which voice speaks answers, for the panel.
    var speechVoiceStatusText: String {
        if let sparkSpeechSentenceQueue {
            return "Miso on Spark (\(sparkSpeechSentenceQueue.voiceName))"
        }
        return "macOS voice"
    }

    /// One-line sidecar state for the panel, e.g. "attached on port 47821".
    @Published private(set) var agentSidecarStatusText: String = "not connected"
    /// Captures sent to the agent since its session started. Shown in the panel.
    @Published private(set) var screenCaptureCountThisSession: Int = 0
    @Published private(set) var lastScreenCaptureDate: Date?
    /// Bumped at the instant of every capture; every overlay flashes its border on change.
    @Published private(set) var screenCaptureFlashCount: Int = 0
    /// True while a capture is in flight (held for at least a moment so it can be seen);
    /// the cursor shows a camera badge.
    @Published private(set) var isScreenCaptureInFlight: Bool = false

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // Attach to or start the agent sidecar now so the first voice turn
        // doesn't pay for Node startup and the session handshake.
        Task {
            do {
                try await ensureAgentSidecarSession()
            } catch {
                print("⚠️ Agent sidecar not ready at launch: \(error.localizedDescription)")
            }
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        stopAllSpeechImmediately()
        agentSidecarClient.disconnect()
        // Only a sidecar this app spawned is stopped; an attached one is yours.
        sidecarProcessController.stopSpawnedSidecar()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance.
            // Cancelling the response task sends user.interrupt to the sidecar.
            currentResponseTask?.cancel()
            stopAllSpeechImmediately()
            clearDetectedElementLocation()
            // A sidecar turn holds .responding while it speaks; release it so
            // the listening waveform can take over.
            if voiceState == .responding {
                voiceState = .idle
            }

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures every screen, sends the transcript and screenshots to the agent
    /// sidecar, and waits until the sidecar finishes the turn. Everything the
    /// turn does arrives as sidecar messages while this waits (spoken sentences,
    /// pointing, fresh screenshots); see handleAgentSidecarMessage. Cancelling
    /// this task, which a new push-to-talk press does, interrupts the turn.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        stopAllSpeechImmediately()

        currentResponseTask = Task {
            // Spinner until the first sentence or pointing arrives
            voiceState = .processing
            let utteranceId = UUID().uuidString

            do {
                try await ensureAgentSidecarSession()
                guard !Task.isCancelled else { return }

                let screenshots = try await captureScreensVisiblyForAgent()
                guard !Task.isCancelled else { return }

                currentAgentUtteranceId = utteranceId
                await withTaskCancellationHandler {
                    await sendUtteranceAndWaitForTurnToFinish(
                        utteranceId: utteranceId,
                        transcript: transcript,
                        screenshots: screenshots
                    )
                } onCancel: {
                    Task { @MainActor in
                        self.interruptAgentTurn(utteranceId: utteranceId)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error.localizedDescription)")
                agentSidecarStatusText = "error: \(error.localizedDescription)"
                speakAgentErrorFallback(spokenExplanation: "i couldn't reach my agent sidecar. the details are in the xcode console.")
            }

            if currentAgentUtteranceId == utteranceId {
                currentAgentUtteranceId = nil
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Agent Sidecar Connection

    /// Makes sure a sidecar is connected and its agent session started.
    /// Attaches to one you started yourself (`npm run serve` in agent-sidecar/)
    /// if it is listening, otherwise spawns one. Safe to call before every turn:
    /// it returns immediately when already connected.
    private func ensureAgentSidecarSession() async throws {
        if agentSidecarClient.isConnected { return }
        if let sidecarConnectionTask {
            return try await sidecarConnectionTask.value
        }

        let connectionTask = Task { try await self.connectToAgentSidecarAndStartSession() }
        sidecarConnectionTask = connectionTask
        defer { sidecarConnectionTask = nil }
        try await connectionTask.value
    }

    private func connectToAgentSidecarAndStartSession() async throws {
        agentSidecarClient.incomingMessageHandler = { [weak self] message in
            self?.handleAgentSidecarMessage(message)
        }
        agentSidecarClient.disconnectHandler = { [weak self] reason in
            self?.handleAgentSidecarDisconnected(reason: reason)
        }

        let sidecarPort = AgentSidecarProtocol.defaultPort
        agentSidecarStatusText = "connecting…"
        let connectionMode: SidecarProcessController.ConnectionMode

        do {
            try await attachToRunningSidecarWaitingOutAStaleOne(port: sidecarPort)
            connectionMode = .attached
        } catch let connectionError as AgentSidecarClient.ConnectionError {
            // Something is listening but refused us (a second client, a token,
            // or not a sidecar at all). Spawning would only collide on the port.
            agentSidecarStatusText = "error: \(connectionError.localizedDescription)"
            throw connectionError
        } catch {
            print("🧩 No sidecar listening on port \(sidecarPort), spawning one")
            agentSidecarStatusText = "starting…"
            do {
                let runningSidecar = try await sidecarProcessController.spawnSidecar(port: sidecarPort)
                _ = try await agentSidecarClient.connect(
                    port: runningSidecar.port,
                    sharedToken: runningSidecar.sharedToken,
                    helloTimeoutSeconds: 5
                )
            } catch {
                agentSidecarStatusText = "error: \(error.localizedDescription)"
                throw error
            }
            connectionMode = .spawned
        }

        // Voice sessions use `default`: allow-listed tools run, edits ask.
        try await agentSidecarClient.startSession(permissionMode: "default")
        screenCaptureCountThisSession = 0
        lastScreenCaptureDate = nil
        agentSidecarStatusText = connectionMode == .attached
            ? "attached on port \(sidecarPort)"
            : "started on port \(sidecarPort)"
        print("🧩 Agent sidecar \(agentSidecarStatusText)")
    }

    /// Attach mode: no token, because a sidecar you started from a terminal
    /// reads its token (if any) from agent-sidecar/.env.
    ///
    /// When Xcode relaunches the app it kills the old one without running its
    /// quit cleanup, so the old app's sidecar lives on for up to ~2 s (its
    /// parent-pid watchdog interval) still holding the dead app's connection.
    /// A launch in that window is refused as a second client; wait it out and
    /// retry. Once the stale sidecar exits, the port is free and connect fails
    /// with a plain network error, which sends the caller down the spawn path.
    private func attachToRunningSidecarWaitingOutAStaleOne(port sidecarPort: Int) async throws {
        let maximumAttempts = 4
        for attemptNumber in 1...maximumAttempts {
            do {
                _ = try await agentSidecarClient.connect(port: sidecarPort, sharedToken: nil, helloTimeoutSeconds: 2)
                return
            } catch AgentSidecarClient.ConnectionError.helloRejected(let reason)
                        where reason.hasPrefix("client_already_connected") && attemptNumber < maximumAttempts {
                print("🧩 Sidecar on port \(sidecarPort) already has a client (attempt \(attemptNumber)); waiting for a stale one to exit")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func handleAgentSidecarDisconnected(reason: String) {
        agentSidecarStatusText = "disconnected"
        if currentAgentUtteranceId != nil {
            speakAgentErrorFallback(spokenExplanation: "i lost my connection to the agent sidecar.")
        }
        // No turn can finish now; release anything waiting on one. The next
        // push-to-talk reconnects (or respawns) through ensureAgentSidecarSession.
        for utteranceId in Array(agentTurnCompletionContinuations.keys) {
            finishAgentTurn(utteranceId: utteranceId)
        }
    }

    // MARK: - Agent Turn

    private func sendUtteranceAndWaitForTurnToFinish(
        utteranceId: String,
        transcript: String,
        screenshots: [AgentSidecarScreenshot]
    ) async {
        // Register the waiter before sending so a fast turn_complete can't arrive first.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            agentTurnCompletionContinuations[utteranceId] = continuation
            Task {
                do {
                    try await agentSidecarClient.sendUtterance(
                        utteranceId: utteranceId,
                        transcript: transcript,
                        screenshots: screenshots
                    )
                } catch {
                    print("⚠️ Could not send the utterance to the sidecar: \(error.localizedDescription)")
                    speakAgentErrorFallback(spokenExplanation: "i couldn't send that to my agent sidecar.")
                    finishAgentTurn(utteranceId: utteranceId)
                }
            }
        }
    }

    private func finishAgentTurn(utteranceId: String) {
        agentTurnCompletionContinuations.removeValue(forKey: utteranceId)?.resume()
    }

    private func interruptAgentTurn(utteranceId: String) {
        stopAllSpeechImmediately()
        finishAgentTurn(utteranceId: utteranceId)
        Task {
            try? await agentSidecarClient.sendInterrupt(utteranceId: utteranceId)
        }
    }

    private func handleAgentSidecarMessage(_ message: IncomingAgentSidecarMessage) {
        switch message {
        case .assistantSentence(let sentencePayload):
            // Sentences from an interrupted turn can still be in flight; drop them.
            guard sentencePayload.utteranceId == currentAgentUtteranceId else { return }
            enqueueAssistantSentenceForSpeech(sentencePayload.text)
            voiceState = .responding

        case .assistantTurnComplete(let turnCompletePayload):
            // The sentences were already spoken; spokenText is for the record only.
            ClickyAnalytics.trackAIResponseReceived(response: turnCompletePayload.spokenText)
            finishAgentTurn(utteranceId: turnCompletePayload.utteranceId)

        case .overlayPointAt(let pointAtPayload):
            pointCursorAtAgentScreenshotLocation(
                screenshotX: pointAtPayload.x,
                screenshotY: pointAtPayload.y,
                label: pointAtPayload.label,
                screenIndex: pointAtPayload.screenIndex
            )

        case .overlayCircleRegion(let circleRegionPayload):
            // Chunk 5 draws a real circle. Until then, point at the region's center.
            pointCursorAtAgentScreenshotLocation(
                screenshotX: circleRegionPayload.x + circleRegionPayload.width / 2,
                screenshotY: circleRegionPayload.y + circleRegionPayload.height / 2,
                label: circleRegionPayload.label,
                screenIndex: circleRegionPayload.screenIndex
            )

        case .overlayClear:
            clearDetectedElementLocation()

        case .screenshotRequest(let screenshotRequestPayload):
            Task {
                await answerAgentScreenshotRequest(screenshotRequestId: screenshotRequestPayload.screenshotRequestId)
            }

        case .permissionRequest(let permissionRequestPayload):
            // Spoken permissions are chunk 6. Until then every request is
            // declined at once rather than left to the sidecar's 30 s timeout.
            print("🧩 Declining \(permissionRequestPayload.toolName): \"\(permissionRequestPayload.spokenSummary)\"")
            Task {
                try? await agentSidecarClient.sendPermissionDecision(
                    permissionRequestId: permissionRequestPayload.permissionRequestId,
                    decision: "deny",
                    denialReason: "the voice app cannot ask for permission yet, so it declined automatically"
                )
            }

        case .error(let errorPayload):
            if let utteranceId = errorPayload.utteranceId {
                if errorPayload.code != "turn_interrupted" && utteranceId == currentAgentUtteranceId {
                    speakAgentErrorFallback(spokenExplanation: "something went wrong on that one. the details are in the xcode console.")
                }
                finishAgentTurn(utteranceId: utteranceId)
            } else if errorPayload.code.hasPrefix("session_"), let currentAgentUtteranceId {
                agentSidecarStatusText = "error: \(errorPayload.code)"
                finishAgentTurn(utteranceId: currentAgentUtteranceId)
            }

        case .sessionReady, .agentStatus, .sidecarHello, .ignored:
            // Logged by the client; the spinner is driven by voiceState instead.
            break
        }
    }

    // MARK: - Visible Screen Capture

    /// Every capture the agent receives goes through here so none is silent:
    /// each overlay flashes a border at the instant of capture, the cursor
    /// shows a camera badge while it is in flight, and the panel counts it
    /// (docs/privacy.md, "Making every capture visible").
    private func captureScreensVisiblyForAgent() async throws -> [AgentSidecarScreenshot] {
        // The indicator lives in the overlay, so make sure it is on screen.
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        screenCaptureBadgeHideTask?.cancel()
        isScreenCaptureInFlight = true
        screenCaptureFlashCount += 1

        let screenCaptures: [CompanionScreenCapture]
        do {
            // Our own overlay windows are excluded from the capture, so the flash never appears in it.
            screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        } catch {
            isScreenCaptureInFlight = false
            throw error
        }

        latestScreenCaptures = screenCaptures
        screenCaptureCountThisSession += 1
        lastScreenCaptureDate = Date()

        // A capture takes a fraction of a second; hold the badge long enough to
        // be seen without delaying the turn by waiting for it here.
        screenCaptureBadgeHideTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            isScreenCaptureInFlight = false
        }

        return screenCaptures.enumerated().map { captureIndex, screenCapture in
            AgentSidecarScreenshot(
                screenIndex: captureIndex + 1,
                label: screenCapture.label,
                isCursorScreen: screenCapture.isCursorScreen,
                widthPixels: screenCapture.screenshotWidthInPixels,
                heightPixels: screenCapture.screenshotHeightInPixels,
                jpegBase64: screenCapture.imageData.base64EncodedString()
            )
        }
    }

    /// Claude called take_screenshot. The persona announces it by voice first.
    private func answerAgentScreenshotRequest(screenshotRequestId: String) async {
        let screenshots: [AgentSidecarScreenshot]
        do {
            screenshots = try await captureScreensVisiblyForAgent()
        } catch {
            // An empty reply makes the tool fail fast instead of waiting out its 5 s timeout.
            print("⚠️ Agent screenshot request failed: \(error.localizedDescription)")
            screenshots = []
        }
        do {
            try await agentSidecarClient.sendScreenshotCaptured(screenshotRequestId: screenshotRequestId, screenshots: screenshots)
        } catch {
            print("⚠️ Could not send screenshots to the sidecar: \(error.localizedDescription)")
        }
    }

    // MARK: - Agent Pointing

    /// Flies the cursor to a point the agent gave in screenshot pixel space.
    private func pointCursorAtAgentScreenshotLocation(screenshotX: Double, screenshotY: Double, label: String, screenIndex: Int) {
        // screenIndex is 1-based and matches the order the screenshots were sent in.
        let targetScreenCapture: CompanionScreenCapture? = {
            if screenIndex >= 1 && screenIndex <= latestScreenCaptures.count {
                return latestScreenCaptures[screenIndex - 1]
            }
            return latestScreenCaptures.first(where: { $0.isCursorScreen })
        }()
        guard let targetScreenCapture else {
            print("🎯 Element pointing: no screenshot to map screen \(screenIndex) onto")
            return
        }

        // The agent's coordinates are in the screenshot's pixel space
        // (top-left origin, e.g. 1280x831). Scale to the display's point
        // space (e.g. 1512x982), then convert to AppKit global coords.
        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
        let displayFrame = targetScreenCapture.displayFrame

        // Clamp to screenshot coordinate space (the sidecar clamps too)
        let clampedX = max(0, min(CGFloat(screenshotX), screenshotWidth))
        let clampedY = max(0, min(CGFloat(screenshotY), screenshotHeight))

        // Scale from screenshot pixels to display points
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitY = displayHeight - displayLocalY

        // Convert display-local coords to global screen coords
        let globalLocation = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )

        // The spinner hides the triangle, so leave the processing state
        // before the flight or the animation is invisible.
        if voiceState == .processing {
            voiceState = .responding
        }

        detectedElementBubbleText = label
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = globalLocation
        ClickyAnalytics.trackElementPointed(elementLabel: label)
        print("🎯 Element pointing: (\(Int(screenshotX)), \(Int(screenshotY))) screen \(screenIndex) → \"\(label)\"")
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while isAnySpeechPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Says out loud that a voice turn failed, so a broken sidecar is never silent.
    /// The detail goes to the Xcode console.
    private func speakAgentErrorFallback(spokenExplanation: String) {
        stopAllSpeechImmediately()
        systemSpeechSentenceQueue.enqueueSentence(spokenExplanation)
    }

    // MARK: - Speech Output

    /// Answers go to the Spark voice when configured, otherwise the macOS voice.
    private func enqueueAssistantSentenceForSpeech(_ sentenceText: String) {
        if let sparkSpeechSentenceQueue {
            sparkSpeechSentenceQueue.enqueueSentence(sentenceText)
        } else {
            systemSpeechSentenceQueue.enqueueSentence(sentenceText)
        }
    }

    private func stopAllSpeechImmediately() {
        sparkSpeechSentenceQueue?.stopImmediately()
        systemSpeechSentenceQueue.stopImmediately()
    }

    /// True while either voice is generating or playing, so the transient
    /// overlay stays up until the last word is heard.
    private var isAnySpeechPlaying: Bool {
        (sparkSpeechSentenceQueue?.isSpeaking ?? false) || systemSpeechSentenceQueue.isSpeaking
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
