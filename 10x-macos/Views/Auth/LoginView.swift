import AppKit
import Foundation
import SwiftUI

struct LoginView: View {
    private enum WelcomeStep: Equatable {
        case systemCheck
        case auth
    }

    private static let setupProgressSectionHeight: CGFloat = 196
    private static let automaticSystemCheckIntervalSeconds: Double = 5
    private static let pinnedBannerInsetTop: CGFloat = 24
    private static let pinnedTopStackReservedHeight: CGFloat = 156
    private static let pinnedBottomActionReservedHeight: CGFloat = 92
    private static let authButtonHeight: CGFloat = 44
    private static let authButtonCornerRadius: CGFloat = 12

    @Environment(AuthManager.self) private var auth
    @Environment(\.scenePhase) private var scenePhase

    @State private var fadeIn = false
    @State private var showControls = false
    @State private var systemCheck = LoginSystemCheckState.checking
    @State private var isRefreshingSystemCheck = false
    @State private var setupProgress: LoginSetupProgressState?
    @State private var welcomeStep: WelcomeStep = .systemCheck

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            GeometryReader { proxy in
                let reservedBottomHeight = welcomeStep == .auth ? Self.pinnedBottomActionReservedHeight : 40

                ZStack {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 24) {
                            welcomeStepContent
                                .opacity(showControls ? 1 : 0)
                                .offset(y: showControls ? 0 : 16)
                        }
                        .padding(.horizontal, 32)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(.top, Self.pinnedTopStackReservedHeight)
                    .padding(.bottom, reservedBottomHeight)

                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            animatedLogo
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 32)
                                .padding(.top, Self.pinnedBannerInsetTop)
                                .opacity(showControls ? 1 : 0)
                                .offset(y: showControls ? 0 : -10)
                        }

                        Spacer(minLength: 0)
                    }

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)

                        if welcomeStep == .auth {
                            pinnedBackButton
                                .padding(.horizontal, 32)
                                .padding(.bottom, 24)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
            }
        }
        .task {
            await automaticSystemCheckLoop()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeOut(duration: 0.8)) {
                    fadeIn = true
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.35)) {
                    showControls = true
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await refreshSystemChecks(showCheckingState: false, force: shouldAutoRefreshSystemChecks)
            }
        }
    }

    private var animatedLogo: some View {
        Image("10XbuilderLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 64)
            .opacity(fadeIn ? 1 : 0)
            .scaleEffect(fadeIn ? 1 : 0.92)
            .frame(height: 120)
    }

    @ViewBuilder
    private var welcomeStepContent: some View {
        ZStack {
            switch welcomeStep {
            case .systemCheck:
                systemCheckStep
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
            case .auth:
                authStep
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.25), value: welcomeStep)
    }

    private var systemCheckStep: some View {
        VStack(spacing: 24) {
            requirementsCard

            systemCheckFooter
        }
        .frame(maxWidth: 520)
    }

    private var authStep: some View {
        VStack(spacing: 24) {
            authCard

            if let error = auth.authError {
                Text(error)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: 520)
    }

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingLG) {
            HStack(alignment: .top, spacing: Theme.spacingMD) {
                Text("System Check")
                    .font(Theme.geist(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 12)

                statusPill
            }

            VStack(spacing: Theme.spacingSM) {
                ForEach(systemCheck.requirements) { requirement in
                    LoginRequirementRow(
                        requirement: requirement,
                        setupProgress: setupProgress,
                        actionHandler: runRequirementAction(_:)
                    )
                }
            }

            if shouldShowSetupProgressSection {
                setupProgressSection
            }

            HStack {
                Spacer(minLength: 0)

                Button {
                    setupProgress = nil
                    Task {
                        await refreshSystemChecks(showCheckingState: true, force: true)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Check Again")
                            .font(Theme.geist(11, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRefreshingSystemCheck || setupProgress?.isRunning == true)
                .opacity((isRefreshingSystemCheck || setupProgress?.isRunning == true) ? 0.6 : 1)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var shouldShowSetupProgressSection: Bool {
        setupProgress != nil || !systemCheck.allResolved
    }

    private var setupProgressSection: some View {
        ZStack {
            if let setupProgress {
                setupProgressCard(setupProgress)
            } else {
                setupProgressPlaceholder
            }
        }
        .frame(height: Self.setupProgressSectionHeight, alignment: .top)
    }

    private var systemCheckFooter: some View {
        VStack(spacing: 14) {
            if systemCheck.allResolved {
                Text("Everything looks ready. Continue to account setup.")
                    .font(Theme.geist(12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            } else {
                setupPendingNote
            }

            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    welcomeStep = .auth
                }
            } label: {
                Text(systemCheck.allResolved ? "Continue" : "Complete Checks to Continue")
                    .font(Theme.geist(14, weight: .medium))
                    .foregroundStyle(systemCheck.allResolved ? .black : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(systemCheck.allResolved ? Color.white : Color.white.opacity(0.06))
            )
            .disabled(!systemCheck.allResolved)
            .opacity(systemCheck.allResolved ? 1 : 0.75)
        }
    }

    private var authCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)

                Text("System check complete")
                    .font(Theme.geist(12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            authButtons
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .frame(maxWidth: 520)
    }

    private var authButtons: some View {
        let isAuthenticating = auth.isAuthenticating
        let googleInFlight = auth.activeSignInProvider == .google
        return VStack(spacing: 16) {
            Button {
                auth.signInWithGoogle()
            } label: {
                HStack(spacing: 10) {
                    GoogleLogoMark()

                    Text(googleInFlight ? "Opening Google..." : "Sign in with Google")
                        .font(Theme.geist(14, weight: .medium))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .contentShape(
                    RoundedRectangle(cornerRadius: Self.authButtonCornerRadius, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .frame(height: Self.authButtonHeight)
            .background(
                .white,
                in: RoundedRectangle(cornerRadius: Self.authButtonCornerRadius, style: .continuous)
            )
            .disabled(isAuthenticating)
            .opacity(isAuthenticating && !googleInFlight ? 0.6 : 1)

            if let status = auth.signInStatusMessage {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(Theme.geist(12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }

            if AuthManager.isLocalDevModeAvailable {
                Button {
                    auth.continueLocally()
                } label: {
                    Text("Continue locally (no account)")
                        .font(Theme.geist(12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(
                            RoundedRectangle(cornerRadius: Self.authButtonCornerRadius, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: Self.authButtonCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .disabled(isAuthenticating)
                .help("Skips sign-in for local development. Requires the local backend from local-backend/ on port 8000.")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var pinnedBackButton: some View {
        HStack {
            Spacer(minLength: 0)

            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    welcomeStep = .systemCheck
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back to system check")
                        .font(Theme.geist(12, weight: .medium))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 520)
        .opacity(showControls ? 1 : 0)
    }

    private var setupPendingNote: some View {
        VStack(spacing: 8) {
            Text(systemCheck.isChecking ? "Checking your Mac..." : "Finish setup to continue")
                .font(Theme.geist(13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            Text(systemCheck.isChecking
                 ? "The continue button unlocks after the local preview dependencies pass."
                 : "Use the setup buttons above to install what is missing. This screen checks again automatically every few seconds.")
                .font(Theme.geist(11))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(width: 280)
        .frame(minHeight: 76)
    }

    @ViewBuilder
    private var statusPill: some View {
        if systemCheck.isChecking {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking")
                    .font(Theme.geist(11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
            )
        } else {
            let isReady = systemCheck.allResolved

            HStack(spacing: 6) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(isReady ? "Ready" : "Needs Setup")
                    .font(Theme.geist(11, weight: .medium))
            }
            .foregroundStyle(isReady ? Theme.accent : Theme.warning)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill((isReady ? Theme.accent : Theme.warning).opacity(0.12))
            )
        }
    }

    private var setupProgressPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup Progress")
                .font(Theme.geist(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Install and download activity appears here.")
                    .font(Theme.geist(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                Text(" ")
                    .font(Theme.geist(11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Capsule()
                .fill(Color.white.opacity(0.05))
                .frame(height: 6)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .frame(height: 72)
                .overlay(
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .frame(height: 10)
                        }
                    }
                    .padding(12)
                )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private func setupProgressCard(_ progress: LoginSetupProgressState) -> some View {
        let display = LoginEnvironmentTooling.progressDisplay(
            message: progress.message,
            progressFraction: progress.progressFraction
        )
        let detailLines = setupProgressDetailLines(for: progress)

        return VStack(alignment: .leading, spacing: Theme.spacingMD) {
            HStack(alignment: .top, spacing: Theme.spacingMD) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.title)
                        .font(Theme.geist(13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Text(display.summary)
                        .font(Theme.geist(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(display.detail ?? " ")
                        .font(Theme.geist(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(display.detail == nil ? 0 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                setupProgressStateIcon(progress.phase)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {
                setupProgressMeter(
                    fraction: display.progressFraction,
                    phase: progress.phase
                )

                Text(setupProgressStatusLabel(progress.phase, progressText: display.progressText))
                    .font(Theme.geistMono(11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(setupProgressStatusColor(progress.phase))
                    .frame(width: 54, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Text(index < detailLines.count ? detailLines[index] : " ")
                        .font(Theme.geistMono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func setupProgressDetailLines(for progress: LoginSetupProgressState) -> [String] {
        if !progress.steps.isEmpty {
            return Array(
                progress.steps
                    .enumerated()
                    .map { index, step in "\(index + 1). \(step)" }
                    .prefix(4)
            )
        }

        let logLines = progress.logLines
        if let latest = logLines.last, latest == progress.message {
            return Array(logLines.dropLast().suffix(4))
        }

        return Array(logLines.suffix(4))
    }

    private func setupProgressMeter(
        fraction: Double?,
        phase: LoginSetupProgressState.Phase
    ) -> some View {
        GeometryReader { proxy in
            let resolvedFraction = max(0, min(phase == .succeeded ? 1 : (fraction ?? 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.06))

                if resolvedFraction > 0 {
                    Capsule()
                        .fill(setupProgressStatusColor(phase))
                        .frame(width: proxy.size.width * resolvedFraction)
                }
            }
        }
        .frame(height: 6)
    }

    private func setupProgressStatusLabel(
        _ phase: LoginSetupProgressState.Phase,
        progressText: String?
    ) -> String {
        switch phase {
        case .running:
            return progressText ?? "Live"
        case .awaitingUser:
            return "Manual"
        case .succeeded:
            return "Done"
        case .failed:
            return "Issue"
        }
    }

    private func setupProgressStatusColor(_ phase: LoginSetupProgressState.Phase) -> Color {
        switch phase {
        case .running, .awaitingUser, .succeeded:
            return Theme.accent
        case .failed:
            return Theme.warning
        }
    }

    @ViewBuilder
    private func setupProgressStateIcon(_ phase: LoginSetupProgressState.Phase) -> some View {
        switch phase {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .awaitingUser:
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.warning)
        }
    }

    private var shouldAutoRefreshSystemChecks: Bool {
        if setupProgress?.isRunning == true {
            return false
        }

        if systemCheck.allResolved {
            return false
        }

        return true
    }

    private func automaticSystemCheckLoop() async {
        await refreshSystemChecks(showCheckingState: true, force: true)

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.automaticSystemCheckIntervalSeconds))
            guard !Task.isCancelled else { return }

            await refreshSystemChecks(showCheckingState: false, force: shouldAutoRefreshSystemChecks)
        }
    }

    private func refreshSystemChecks(
        showCheckingState: Bool,
        force: Bool = false
    ) async {
        guard force || shouldAutoRefreshSystemChecks || systemCheck.isChecking else { return }

        let canStartRefresh = await MainActor.run { () -> Bool in
            guard force || !isRefreshingSystemCheck else { return false }
            isRefreshingSystemCheck = true

            if showCheckingState {
                withAnimation(.easeOut(duration: 0.2)) {
                    systemCheck = .checking
                }
            }

            return true
        }
        guard canStartRefresh else { return }

        let result = await Task.detached(priority: .userInitiated) {
            LoginSystemCheckRunner.run()
        }.value

        guard !Task.isCancelled else {
            await MainActor.run {
                isRefreshingSystemCheck = false
            }
            return
        }

        await MainActor.run {
            isRefreshingSystemCheck = false
            reconcileSetupProgress(with: result)
            withAnimation(.easeOut(duration: 0.25)) {
                systemCheck = result
            }
        }
    }

    private func reconcileSetupProgress(with result: LoginSystemCheckState) {
        guard let setupProgress, setupProgress.phase == .awaitingUser else { return }

        switch setupProgress.action {
        case .installXcode:
            if result.requirement(id: "xcode")?.action != .installXcode {
                self.setupProgress = nil
            }
        default:
            break
        }
    }

    private func runRequirementAction(_ action: LoginRequirementAction) {
        guard setupProgress?.isRunning != true else { return }

        Task {
            let finalState = await LoginSetupTaskRunner.run(action: action) { update in
                await MainActor.run {
                    self.setupProgress = update
                }
            }

            await MainActor.run {
                self.setupProgress = finalState
            }

            guard finalState.phase == .succeeded, action.refreshesSystemCheckOnSuccess else {
                return
            }

            await refreshSystemChecks(showCheckingState: true, force: true)
        }
    }
}

private struct LoginRequirementRow: View {
    let requirement: LoginSystemRequirement
    let setupProgress: LoginSetupProgressState?
    let actionHandler: (LoginRequirementAction) -> Void

    private var actionIsRunning: Bool {
        guard let action = requirement.action else { return false }
        return setupProgress?.action == action && setupProgress?.isRunning == true
    }

    private var actionIsBlocked: Bool {
        guard let setupProgress else { return false }
        guard setupProgress.isRunning else { return false }
        return setupProgress.action != requirement.action
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indicator
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(requirement.title)
                    .font(Theme.geist(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)

                Text(requirement.detail)
                    .font(Theme.geist(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            }

            Spacer(minLength: 0)

            if let action = requirement.action {
                Button {
                    actionHandler(action)
                } label: {
                    if actionIsRunning {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(action.runningButtonTitle)
                                .font(Theme.geist(11, weight: .medium))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 118)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    } else {
                        Text(action.buttonTitle)
                            .font(Theme.geist(11, weight: .medium))
                            .foregroundStyle(.black)
                            .frame(width: 118)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(actionIsRunning ? Color.white.opacity(0.06) : .white)
                )
                .disabled(actionIsRunning || actionIsBlocked)
                .opacity(actionIsBlocked ? 0.55 : 1)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 84, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    @ViewBuilder
    private var indicator: some View {
        switch requirement.status {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)

        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16, height: 16)

        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .frame(width: 16, height: 16)
        }
    }
}

private enum LoginRequirementAction: Sendable, Equatable {
    case installXcode
    case runFirstLaunch
    case downloadIOSRuntime
    case createIOSSimulator

    nonisolated var buttonTitle: String {
        switch self {
        case .installXcode:
            return "Get Xcode"
        case .runFirstLaunch:
            return "Finish Setup"
        case .downloadIOSRuntime:
            return "Download iOS"
        case .createIOSSimulator:
            return "Create iPhone"
        }
    }

    nonisolated var runningButtonTitle: String {
        switch self {
        case .installXcode:
            return "Opening..."
        case .runFirstLaunch:
            return "Finishing..."
        case .downloadIOSRuntime:
            return "Downloading..."
        case .createIOSSimulator:
            return "Creating..."
        }
    }

    nonisolated var progressTitle: String {
        switch self {
        case .installXcode:
            return "Install Xcode"
        case .runFirstLaunch:
            return "Finishing Xcode Setup"
        case .downloadIOSRuntime:
            return "Downloading iOS Simulator"
        case .createIOSSimulator:
            return "Creating iPhone Simulator"
        }
    }

    nonisolated var manualSteps: [String] {
        switch self {
        case .installXcode:
            return [
                "Click Get or Install in the App Store.",
                "Launch Xcode once after the install completes.",
                "Come back here. This screen will detect Xcode automatically within a few seconds."
            ]
        default:
            return []
        }
    }

    nonisolated var refreshesSystemCheckOnSuccess: Bool {
        switch self {
        case .installXcode:
            return false
        case .runFirstLaunch, .downloadIOSRuntime, .createIOSSimulator:
            return true
        }
    }
}

private struct LoginSetupProgressState: Sendable {
    enum Phase: Sendable, Equatable {
        case running
        case awaitingUser
        case succeeded
        case failed
    }

    let action: LoginRequirementAction
    let phase: Phase
    let title: String
    let message: String
    let progressFraction: Double?
    let steps: [String]
    let logLines: [String]

    nonisolated var isRunning: Bool {
        switch phase {
        case .running:
            return true
        case .awaitingUser, .succeeded, .failed:
            return false
        }
    }
}

private struct LoginSetupProgressDisplay: Sendable {
    let summary: String
    let detail: String?
    let progressFraction: Double?
    let progressText: String?
}

private struct LoginSystemRequirement: Identifiable, Sendable {
    enum Status: Sendable {
        case checking
        case passed
        case failed
    }

    let id: String
    let title: String
    let detail: String
    let status: Status
    let action: LoginRequirementAction?
}

private struct LoginSystemCheckState: Sendable {
    let requirements: [LoginSystemRequirement]

    static let checking = LoginSystemCheckState(
        requirements: [
            LoginSystemRequirement(
                id: "xcode",
                title: "Xcode installed",
                detail: "Checking local Xcode build tools and Simulator access.",
                status: .checking,
                action: nil
            ),
            LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: "Checking for an available iPhone simulator runtime.",
                status: .checking,
                action: nil
            ),
        ]
    )

    var isChecking: Bool {
        requirements.contains { $0.status == .checking }
    }

    var allResolved: Bool {
        !requirements.contains { $0.status != .passed }
    }

    func requirement(id: String) -> LoginSystemRequirement? {
        requirements.first { $0.id == id }
    }
}

private struct LoginXcodeCheck: Sendable {
    let developerDir: String
    let isInstalled: Bool
    let isReady: Bool
    let requirement: LoginSystemRequirement
}

private enum LoginSystemCheckRunner {
    nonisolated private static let minimumIOSMajorVersion = 26
    nonisolated private static let preferredDeviceNames = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone Air"]

    nonisolated static func run() -> LoginSystemCheckState {
        let xcodeCheck = checkXcode()

        return LoginSystemCheckState(
            requirements: [
                xcodeCheck.requirement,
                checkSimulator(xcodeCheck: xcodeCheck),
            ]
        )
    }

    nonisolated private static func checkXcode() -> LoginXcodeCheck {
        let resolvedDeveloperDir = LoginEnvironmentTooling.resolvedDeveloperDir()

        if LoginSystemCheckDebugOverride.forceMissingXcode {
            return LoginXcodeCheck(
                developerDir: resolvedDeveloperDir,
                isInstalled: false,
                isReady: false,
                requirement: LoginSystemRequirement(
                    id: "xcode",
                    title: "Xcode installed",
                    detail: "Debug testing: simulating missing Xcode. Click Get Xcode to test the install handoff.",
                    status: .failed,
                    action: .installXcode
                )
            )
        }

        guard let developerDir = LoginEnvironmentTooling.installedDeveloperDir() else {
            return LoginXcodeCheck(
                developerDir: resolvedDeveloperDir,
                isInstalled: false,
                isReady: false,
                requirement: LoginSystemRequirement(
                    id: "xcode",
                    title: "Xcode installed",
                    detail: "Install Xcode from the App Store, then open it once on this Mac.",
                    status: .failed,
                    action: .installXcode
                )
            )
        }

        let versionResult = LoginEnvironmentTooling.runProcess(
            LoginEnvironmentTooling.xcodebuildExecutablePath(for: developerDir),
            arguments: ["-version"],
            environment: LoginEnvironmentTooling.developerDirectoryEnvironment(developerDir)
        )

        guard versionResult.exitCode == 0 else {
            return LoginXcodeCheck(
                developerDir: developerDir,
                isInstalled: false,
                isReady: false,
                requirement: LoginSystemRequirement(
                    id: "xcode",
                    title: "Xcode installed",
                    detail: LoginEnvironmentTooling.failureMessage(
                        from: versionResult,
                        fallback: "Install Xcode from the App Store, then open it once on this Mac."
                    ),
                    status: .failed,
                    action: .installXcode
                )
            )
        }

        let firstLaunchResult = LoginEnvironmentTooling.runProcess(
            LoginEnvironmentTooling.xcodebuildExecutablePath(for: developerDir),
            arguments: ["-checkFirstLaunchStatus"],
            environment: LoginEnvironmentTooling.developerDirectoryEnvironment(developerDir)
        )

        guard firstLaunchResult.exitCode == 0 else {
            return LoginXcodeCheck(
                developerDir: developerDir,
                isInstalled: true,
                isReady: false,
                requirement: LoginSystemRequirement(
                    id: "xcode",
                    title: "Xcode installed",
                    detail: LoginEnvironmentTooling.failureMessage(
                        from: firstLaunchResult,
                        fallback: "Finish Xcode setup to install required components and accept the license."
                    ),
                    status: .failed,
                    action: .runFirstLaunch
                )
            )
        }

        let versionLine = LoginEnvironmentTooling.trimmedLines(in: versionResult.stdout).first ?? "Xcode build tools are ready."

        return LoginXcodeCheck(
            developerDir: developerDir,
            isInstalled: true,
            isReady: true,
            requirement: LoginSystemRequirement(
                id: "xcode",
                title: "Xcode installed",
                detail: "\(versionLine) is ready for local builds and previews.",
                status: .passed,
                action: nil
            )
        )
    }

    nonisolated private static func checkSimulator(xcodeCheck: LoginXcodeCheck) -> LoginSystemRequirement {
        if LoginSystemCheckDebugOverride.forceMissingSimulator {
            return LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: "Debug testing: simulating a missing iOS simulator runtime. Click Download iOS to test the setup flow.",
                status: .failed,
                action: .downloadIOSRuntime
            )
        }

        guard xcodeCheck.isInstalled else {
            return LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: "Install Xcode first. The iPhone simulator runtime ships with Xcode.",
                status: .failed,
                action: nil
            )
        }

        guard xcodeCheck.isReady else {
            return LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: "Finish Xcode setup first so simulator components can be installed.",
                status: .failed,
                action: nil
            )
        }

        let runtimeResult = LoginEnvironmentTooling.runXcrun(
            ["simctl", "list", "runtimes", "available", "-j"],
            developerDir: xcodeCheck.developerDir
        )

        guard runtimeResult.exitCode == 0 else {
            return LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: LoginEnvironmentTooling.failureMessage(
                    from: runtimeResult,
                    fallback: "Download an iOS 26 or newer simulator runtime from Xcode."
                ),
                status: .failed,
                action: .downloadIOSRuntime
            )
        }

        guard let runtimes = LoginEnvironmentTooling.parseIOSRuntimes(from: runtimeResult.stdout) else {
            return LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: "Could not read available iOS simulator runtimes from Xcode.",
                status: .failed,
                action: .downloadIOSRuntime
            )
        }

        let compatibleRuntimes = runtimes
            .filter { $0.version.major >= minimumIOSMajorVersion }
            .sorted(by: compareRuntimes(_:_:))

        guard let preferredRuntime = compatibleRuntimes.first else {
            return LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: "No iOS 26 or newer simulator runtime is installed yet.",
                status: .failed,
                action: .downloadIOSRuntime
            )
        }

        let deviceResult = LoginEnvironmentTooling.runXcrun(
            ["simctl", "list", "devices", "available", "-j"],
            developerDir: xcodeCheck.developerDir
        )

        guard deviceResult.exitCode == 0 else {
            return LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: LoginEnvironmentTooling.failureMessage(
                    from: deviceResult,
                    fallback: "Create an iPhone simulator device for the installed iOS runtime."
                ),
                status: .failed,
                action: .createIOSSimulator
            )
        }

        guard let devices = LoginEnvironmentTooling.parseAvailableDevices(from: deviceResult.stdout) else {
            return LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: "Could not read available iPhone simulator devices from Xcode.",
                status: .failed,
                action: .createIOSSimulator
            )
        }

        let compatibleDevices = devices
            .filter { $0.name.contains("iPhone") && $0.runtimeVersion.major >= minimumIOSMajorVersion }
            .sorted(by: compareDevices(_:_:))

        if let compatibleDevice = compatibleDevices.first {
            return LoginSystemRequirement(
                id: "simulator",
                title: "iOS 26+ simulator available",
                detail: "Found \(compatibleDevice.name) running \(compatibleDevice.runtimeLabel).",
                status: .passed,
                action: nil
            )
        }

        return LoginSystemRequirement(
            id: "simulator",
            title: "iOS 26+ simulator available",
            detail: "\(preferredRuntime.name) is installed, but no available iPhone simulator device exists yet.",
            status: .failed,
            action: .createIOSSimulator
        )
    }

    nonisolated private static func compareRuntimes(_ lhs: LoginSimulatorRuntime, _ rhs: LoginSimulatorRuntime) -> Bool {
        if lhs.version.major != rhs.version.major {
            return lhs.version.major > rhs.version.major
        }
        if lhs.version.minor != rhs.version.minor {
            return lhs.version.minor > rhs.version.minor
        }
        return lhs.name < rhs.name
    }

    nonisolated private static func compareDevices(_ lhs: LoginSimulatorDevice, _ rhs: LoginSimulatorDevice) -> Bool {
        if lhs.state == "Booted" && rhs.state != "Booted" { return true }
        if lhs.state != "Booted" && rhs.state == "Booted" { return false }

        if lhs.runtimeVersion.major != rhs.runtimeVersion.major {
            return lhs.runtimeVersion.major > rhs.runtimeVersion.major
        }
        if lhs.runtimeVersion.minor != rhs.runtimeVersion.minor {
            return lhs.runtimeVersion.minor > rhs.runtimeVersion.minor
        }

        let lhsPreferred = preferredDeviceNames.firstIndex(where: { lhs.name.contains($0) }) ?? Int.max
        let rhsPreferred = preferredDeviceNames.firstIndex(where: { rhs.name.contains($0) }) ?? Int.max
        if lhsPreferred != rhsPreferred {
            return lhsPreferred < rhsPreferred
        }

        return lhs.name < rhs.name
    }
}

private enum LoginSystemCheckDebugOverride {
    nonisolated static var forceMissingXcode: Bool {
        isEnabled("TENX_FORCE_MISSING_XCODE")
    }

    nonisolated static var forceMissingSimulator: Bool {
        isEnabled("TENX_FORCE_MISSING_SIMULATOR")
    }

    nonisolated private static func isEnabled(_ key: String) -> Bool {
#if DEBUG
        guard let rawValue = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(rawValue)
#else
        return false
#endif
    }
}

private enum LoginSetupTaskRunner {
    nonisolated static func run(
        action: LoginRequirementAction,
        onUpdate: @escaping @Sendable (LoginSetupProgressState) async -> Void
    ) async -> LoginSetupProgressState {
        switch action {
        case .installXcode:
            return await openXcodeInstallPage(onUpdate: onUpdate)
        case .runFirstLaunch:
            let developerDir = LoginEnvironmentTooling.resolvedDeveloperDir()
            return await runCommandAction(
                action: action,
                executablePath: LoginEnvironmentTooling.xcodebuildExecutablePath(for: developerDir),
                arguments: ["-runFirstLaunch"],
                environment: LoginEnvironmentTooling.developerDirectoryEnvironment(developerDir),
                initialMessage: "Installing required Xcode components and finishing first launch setup.",
                successMessage: "Xcode setup finished. Rechecking your environment now.",
                failureFallback: "Xcode setup did not complete. Open Xcode once manually, then try again.",
                onUpdate: onUpdate
            )
        case .downloadIOSRuntime:
            let developerDir = LoginEnvironmentTooling.resolvedDeveloperDir()
            return await runCommandAction(
                action: action,
                executablePath: LoginEnvironmentTooling.xcodebuildExecutablePath(for: developerDir),
                arguments: ["-verbose", "-downloadPlatform", "iOS"],
                environment: LoginEnvironmentTooling.developerDirectoryEnvironment(developerDir),
                initialMessage: "Starting the iOS simulator runtime download from Xcode.",
                successMessage: "The iOS simulator download finished. Rechecking your environment now.",
                failureFallback: "The iOS simulator download did not complete. Open Xcode > Settings > Platforms if this keeps failing.",
                onUpdate: onUpdate
            )
        case .createIOSSimulator:
            return await createIOSSimulator(onUpdate: onUpdate)
        }
    }

    nonisolated private static func openXcodeInstallPage(
        onUpdate: @escaping @Sendable (LoginSetupProgressState) async -> Void
    ) async -> LoginSetupProgressState {
        let opened = await LoginEnvironmentTooling.openXcodeInstallPage()
        let state = LoginSetupProgressState(
            action: .installXcode,
            phase: .awaitingUser,
            title: LoginRequirementAction.installXcode.progressTitle,
            message: opened
                ? "The App Store page for Xcode is open. Install it there, then open Xcode once on this Mac."
                : "Open Xcode in the App Store, install it, then open Xcode once on this Mac.",
            progressFraction: nil,
            steps: LoginRequirementAction.installXcode.manualSteps,
            logLines: []
        )
        await onUpdate(state)
        return state
    }

    nonisolated private static func createIOSSimulator(
        onUpdate: @escaping @Sendable (LoginSetupProgressState) async -> Void
    ) async -> LoginSetupProgressState {
        let developerDir = LoginEnvironmentTooling.resolvedDeveloperDir()
        let runtimeResult = LoginEnvironmentTooling.runXcrun(
            ["simctl", "list", "runtimes", "available", "-j"],
            developerDir: developerDir
        )

        guard runtimeResult.exitCode == 0,
              let runtimes = LoginEnvironmentTooling.parseIOSRuntimes(from: runtimeResult.stdout),
              let runtime = runtimes
                .filter({ $0.version.major >= 26 })
                .sorted(by: { lhs, rhs in
                    if lhs.version.major != rhs.version.major { return lhs.version.major > rhs.version.major }
                    if lhs.version.minor != rhs.version.minor { return lhs.version.minor > rhs.version.minor }
                    return lhs.name < rhs.name
                })
                .first,
              let deviceType = preferredDeviceType(for: runtime)
        else {
            let state = LoginSetupProgressState(
                action: .createIOSSimulator,
                phase: .failed,
                title: LoginRequirementAction.createIOSSimulator.progressTitle,
                message: "A compatible iOS runtime or iPhone device type was not available. Download the iOS runtime first.",
                progressFraction: nil,
                steps: [],
                logLines: []
            )
            await onUpdate(state)
            return state
        }

        let name = "10x \(deviceType.name)"
        let initialLogs = [
            "Runtime: \(runtime.name)",
            "Device type: \(deviceType.name)"
        ]

        return await runCommandAction(
            action: .createIOSSimulator,
            executablePath: LoginEnvironmentTooling.xcrunExecutablePath(for: developerDir),
            arguments: ["simctl", "create", name, deviceType.identifier, runtime.identifier],
            environment: LoginEnvironmentTooling.developerDirectoryEnvironment(developerDir),
            initialMessage: "Creating \(deviceType.name) on \(runtime.name).",
            successMessage: "Created \(deviceType.name). Rechecking your environment now.",
            failureFallback: "Could not create an iPhone simulator automatically. Open Xcode > Window > Devices and Simulators if this keeps failing.",
            initialLogLines: initialLogs,
            onUpdate: onUpdate
        )
    }

    nonisolated private static func preferredDeviceType(
        for runtime: LoginSimulatorRuntime
    ) -> LoginSimulatorSupportedDeviceType? {
        let preferredNames = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone Air"]
        let supportedIPhones = runtime.supportedDeviceTypes.filter { $0.productFamily == "iPhone" }

        for name in preferredNames {
            if let match = supportedIPhones.first(where: { $0.name == name }) {
                return match
            }
        }

        return supportedIPhones.first
    }

    nonisolated private static func runCommandAction(
        action: LoginRequirementAction,
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        initialMessage: String,
        successMessage: String,
        failureFallback: String,
        initialLogLines: [String] = [],
        onUpdate: @escaping @Sendable (LoginSetupProgressState) async -> Void
    ) async -> LoginSetupProgressState {
        let accumulator = LoginSetupOutputAccumulator(
            initialMessage: initialMessage,
            initialLogLines: initialLogLines
        )

        let startingState = LoginSetupProgressState(
            action: action,
            phase: .running,
            title: action.progressTitle,
            message: initialMessage,
            progressFraction: nil,
            steps: [],
            logLines: initialLogLines
        )
        await onUpdate(startingState)

        let result = await LoginEnvironmentTooling.runStreamingProcess(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment
        ) { rawLine in
            let normalized = LoginEnvironmentTooling.normalizedLine(rawLine)
            guard !normalized.isEmpty else { return }

            let snapshot = accumulator.record(line: normalized)
            await onUpdate(
                LoginSetupProgressState(
                    action: action,
                    phase: .running,
                    title: action.progressTitle,
                    message: snapshot.message,
                    progressFraction: snapshot.progressFraction,
                    steps: [],
                    logLines: snapshot.logLines
                )
            )
        }

        let snapshot = accumulator.snapshot()

        if result.exitCode == 0 {
            let finalState = LoginSetupProgressState(
                action: action,
                phase: .succeeded,
                title: action.progressTitle,
                message: successMessage,
                progressFraction: snapshot.progressFraction ?? 1,
                steps: [],
                logLines: snapshot.logLines
            )
            await onUpdate(finalState)
            return finalState
        }

        let failureMessage = LoginEnvironmentTooling.failureMessage(
            from: result,
            fallback: failureFallback
        )
        let finalState = LoginSetupProgressState(
            action: action,
            phase: .failed,
            title: action.progressTitle,
            message: failureMessage,
            progressFraction: snapshot.progressFraction,
            steps: [],
            logLines: snapshot.logLines
        )
        await onUpdate(finalState)
        return finalState
    }
}

private enum LoginEnvironmentTooling {
    nonisolated private static let preferredXcodeAppNames = [
        "Xcode.app",
        "Xcode-beta.app"
    ]

    nonisolated static func installedDeveloperDir() -> String? {
        var candidates: [String] = []

        let applicationRoots = [
            "/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]

        for root in applicationRoots {
            for appName in preferredXcodeAppNames {
                candidates.append((root as NSString).appendingPathComponent(appName + "/Contents/Developer"))
            }

            candidates.append(contentsOf: discoveredDeveloperDirs(in: root))
        }

        let selectedPath = runProcess("/usr/bin/xcode-select", arguments: ["-p"])
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedPath.isEmpty {
            candidates.append(selectedPath)
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if isValidXcodeDeveloperDir(candidate) {
                return candidate
            }
        }

        return nil
    }

    nonisolated static func resolvedDeveloperDir() -> String {
        if let installedDeveloperDir = installedDeveloperDir() {
            return installedDeveloperDir
        }

        let result = runProcess("/usr/bin/xcode-select", arguments: ["-p"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "/Applications/Xcode.app/Contents/Developer" : path
    }

    nonisolated static func developerDirectoryEnvironment(_ developerDir: String) -> [String: String] {
        ["DEVELOPER_DIR": developerDir]
    }

    nonisolated static func xcodebuildExecutablePath(for developerDir: String) -> String {
        let developerBinary = (developerDir as NSString).appendingPathComponent("usr/bin/xcodebuild")
        return isExecutable(atPath: developerBinary) ? developerBinary : "/usr/bin/xcodebuild"
    }

    nonisolated static func xcrunExecutablePath(for developerDir: String) -> String {
        let developerBinary = (developerDir as NSString).appendingPathComponent("usr/bin/xcrun")
        return isExecutable(atPath: developerBinary) ? developerBinary : "/usr/bin/xcrun"
    }

    nonisolated static func runXcrun(
        _ arguments: [String],
        developerDir: String
    ) -> LoginProcessResult {
        runProcess(
            xcrunExecutablePath(for: developerDir),
            arguments: arguments,
            environment: developerDirectoryEnvironment(developerDir)
        )
    }

    nonisolated private static func discoveredDeveloperDirs(in applicationsDirectory: String) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: applicationsDirectory
        ) else {
            return []
        }

        return contents
            .filter { entry in
                entry.hasPrefix("Xcode") &&
                entry.hasSuffix(".app") &&
                !entry.contains(".tenx-disabled")
            }
            .sorted()
            .map { entry in
                (applicationsDirectory as NSString).appendingPathComponent(entry + "/Contents/Developer")
            }
    }

    nonisolated private static func isValidXcodeDeveloperDir(_ path: String) -> Bool {
        isExecutable(atPath: (path as NSString).appendingPathComponent("usr/bin/xcodebuild"))
    }

    nonisolated private static func isExecutable(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    nonisolated static func runProcess(
        _ executablePath: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> LoginProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutData = NSMutableData()
        let stderrData = NSMutableData()
        let captureGroup = DispatchGroup()

        captureGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutData.append(data)
            captureGroup.leave()
        }

        captureGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrData.append(data)
            captureGroup.leave()
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return LoginProcessResult(
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: -1
            )
        }

        captureGroup.wait()

        let stdout = String(data: stdoutData as Data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData as Data, encoding: .utf8) ?? ""

        return LoginProcessResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus
        )
    }

    nonisolated static func runStreamingProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:],
        onLine: @escaping @Sendable (String) async -> Void
    ) async -> LoginProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let captureState = LoginStreamingCaptureState()

            @Sendable func finish(_ result: LoginProcessResult) {
                guard captureState.claimResume() else { return }
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: result)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }

                let lines = captureState.appendStdout(chunk)
                for line in lines {
                    Task {
                        await onLine(line)
                    }
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }

                let lines = captureState.appendStderr(chunk)
                for line in lines {
                    Task {
                        await onLine(line)
                    }
                }
            }

            process.terminationHandler = { terminatedProcess in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let finalized = captureState.finalize(
                    remainingStdout: remainingStdout,
                    remainingStderr: remainingStderr
                )

                for line in finalized.remainingLines {
                    Task {
                        await onLine(line)
                    }
                }

                finish(
                    LoginProcessResult(
                        stdout: finalized.stdout,
                        stderr: finalized.stderr,
                        exitCode: terminatedProcess.terminationStatus
                    )
                )
            }

            do {
                try process.run()
            } catch {
                finish(
                    LoginProcessResult(
                        stdout: "",
                        stderr: error.localizedDescription,
                        exitCode: -1
                    )
                )
            }
        }
    }

    nonisolated static func trimmedLines(in text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func failureMessage(from result: LoginProcessResult, fallback: String) -> String {
        let lines = trimmedLines(in: result.stderr + "\n" + result.stdout)
        let preferred = lines.first {
            !$0.hasPrefix("xcrun:") && !$0.hasPrefix("xcodebuild:")
        }
        return preferred ?? lines.first ?? fallback
    }

    nonisolated static func normalizedLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func progressFraction(from line: String) -> Double? {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let tokens = line.components(separatedBy: separators).filter { !$0.isEmpty }

        for token in tokens.reversed() {
            let cleaned = token.replacingOccurrences(of: "%", with: "")
            if let value = Double(cleaned), (0...100).contains(value) {
                return value / 100
            }
        }

        return nil
    }

    nonisolated static func progressDisplay(
        message: String,
        progressFraction currentFraction: Double?
    ) -> LoginSetupProgressDisplay {
        let normalizedMessage = normalizedLine(message)

        if let parsedDownload = parseDownloadProgress(
            from: normalizedMessage,
            fallbackFraction: currentFraction
        ) {
            return parsedDownload
        }

        let split = splitProgressMessage(normalizedMessage)
        let resolvedFraction = currentFraction ?? progressFraction(from: normalizedMessage)

        return LoginSetupProgressDisplay(
            summary: split.summary,
            detail: split.detail,
            progressFraction: resolvedFraction,
            progressText: progressText(from: resolvedFraction)
        )
    }

    nonisolated private static func parseDownloadProgress(
        from line: String,
        fallbackFraction: Double?
    ) -> LoginSetupProgressDisplay? {
        let prefix = "Downloading "
        guard line.hasPrefix(prefix) else { return nil }

        let payload = String(line.dropFirst(prefix.count))
        guard let separatorRange = payload.range(of: ": ", options: .backwards) else { return nil }

        let rawTarget = String(payload[..<separatorRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let progressPayload = String(payload[separatorRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let summary = compactDownloadTarget(rawTarget)
        let detail = progressDetail(from: progressPayload)
        let resolvedFraction = progressFraction(from: progressPayload) ?? fallbackFraction

        return LoginSetupProgressDisplay(
            summary: summary.isEmpty ? normalizedLine(line) : summary,
            detail: detail,
            progressFraction: resolvedFraction,
            progressText: progressText(from: resolvedFraction)
        )
    }

    nonisolated private static func compactDownloadTarget(_ rawTarget: String) -> String {
        guard let metadataStart = rawTarget.firstIndex(of: "(") else {
            return rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(rawTarget[..<metadataStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func progressDetail(from payload: String) -> String? {
        guard let openParen = payload.firstIndex(of: "("),
              let closeParen = payload.lastIndex(of: ")"),
              openParen < closeParen
        else {
            return nil
        }

        let detail = String(payload[payload.index(after: openParen)..<closeParen])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? nil : detail
    }

    nonisolated private static func splitProgressMessage(_ message: String) -> (summary: String, detail: String?) {
        guard !message.isEmpty else {
            return ("Preparing setup action.", nil)
        }

        if let range = message.range(of: ". ") {
            let summary = String(message[..<range.lowerBound]) + "."
            let detail = String(message[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (summary, detail.isEmpty ? nil : detail)
        }

        return (message, nil)
    }

    nonisolated private static func progressText(from fraction: Double?) -> String? {
        guard let fraction else { return nil }
        return String(format: "%.1f%%", min(max(fraction, 0), 1) * 100)
    }

    nonisolated static func parseIOSRuntimes(from rawJSON: String) -> [LoginSimulatorRuntime]? {
        guard let data = rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["runtimes"] as? [[String: Any]]
        else {
            return nil
        }

        var parsedRuntimes: [LoginSimulatorRuntime] = []

        for runtime in runtimes {
            guard let identifier = runtime["identifier"] as? String,
                  let name = runtime["name"] as? String,
                  let isAvailable = runtime["isAvailable"] as? Bool,
                  let platform = runtime["platform"] as? String,
                  platform == "iOS"
            else {
                continue
            }

            let version = LoginEnvironmentTooling.runtimeVersion(from: identifier)
            var supportedDeviceTypes: [LoginSimulatorSupportedDeviceType] = []

            for deviceType in runtime["supportedDeviceTypes"] as? [[String: Any]] ?? [] {
                guard let deviceName = deviceType["name"] as? String,
                      let deviceIdentifier = deviceType["identifier"] as? String,
                      let productFamily = deviceType["productFamily"] as? String
                else {
                    continue
                }

                supportedDeviceTypes.append(
                    LoginSimulatorSupportedDeviceType(
                        name: deviceName,
                        identifier: deviceIdentifier,
                        productFamily: productFamily
                    )
                )
            }

            parsedRuntimes.append(
                LoginSimulatorRuntime(
                    name: name,
                    identifier: identifier,
                    isAvailable: isAvailable,
                    version: version,
                    supportedDeviceTypes: supportedDeviceTypes
                )
            )
        }

        return parsedRuntimes.filter(\.isAvailable)
    }

    nonisolated static func parseAvailableDevices(from rawJSON: String) -> [LoginSimulatorDevice]? {
        guard let data = rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]]
        else {
            return nil
        }

        return devices.flatMap { runtimeIdentifier, deviceList in
            deviceList.compactMap { device in
                guard let name = device["name"] as? String,
                      let udid = device["udid"] as? String,
                      let isAvailable = device["isAvailable"] as? Bool,
                      isAvailable,
                      let state = device["state"] as? String
                else {
                    return nil
                }

                return LoginSimulatorDevice(
                    name: name,
                    udid: udid,
                    runtimeIdentifier: runtimeIdentifier,
                    state: state
                )
            }
        }
    }

    nonisolated static func runtimeVersion(from identifier: String) -> (major: Int, minor: Int) {
        guard let range = identifier.range(of: "iOS-") else { return (0, 0) }
        let parts = identifier[range.upperBound...]
            .split(separator: "-")
            .compactMap { Int($0) }

        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0
        )
    }

    nonisolated static func openXcodeInstallPage() async -> Bool {
        await MainActor.run {
            let urls = [
                "macappstore://itunes.apple.com/app/id497799835?mt=12",
                "macappstore://apps.apple.com/app/id497799835",
                "https://apps.apple.com/us/app/xcode/id497799835"
            ]

            for rawURL in urls {
                guard let url = URL(string: rawURL) else { continue }
                if NSWorkspace.shared.open(url) {
                    return true
                }
            }

            return false
        }
    }
}

private final class LoginStreamingCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var stdoutData = Data()
    nonisolated(unsafe) private var stderrData = Data()
    nonisolated(unsafe) private var pendingStdout = ""
    nonisolated(unsafe) private var pendingStderr = ""
    nonisolated(unsafe) private var didResume = false

    nonisolated init() {}

    nonisolated func appendStdout(_ chunk: Data) -> [String] {
        append(chunk, toStdout: true)
    }

    nonisolated func appendStderr(_ chunk: Data) -> [String] {
        append(chunk, toStdout: false)
    }

    nonisolated func finalize(remainingStdout: Data, remainingStderr: Data) -> (stdout: String, stderr: String, remainingLines: [String]) {
        lock.lock()
        stdoutData.append(remainingStdout)
        stderrData.append(remainingStderr)

        let extraStdout = String(data: remainingStdout, encoding: .utf8) ?? ""
        let extraStderr = String(data: remainingStderr, encoding: .utf8) ?? ""
        pendingStdout += extraStdout
        pendingStderr += extraStderr

        let remainingLines = flushPendingLines()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        lock.unlock()
        return (stdout, stderr, remainingLines)
    }

    nonisolated func claimResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }

    nonisolated private func append(_ chunk: Data, toStdout: Bool) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        if toStdout {
            stdoutData.append(chunk)
            pendingStdout += String(data: chunk, encoding: .utf8) ?? ""
        } else {
            stderrData.append(chunk)
            pendingStderr += String(data: chunk, encoding: .utf8) ?? ""
        }

        return flushPendingLines()
    }

    nonisolated private func flushPendingLines() -> [String] {
        let combined = (pendingStdout + "\n" + pendingStderr)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let parts = combined.components(separatedBy: "\n")
        pendingStdout = parts.last ?? ""
        pendingStderr = ""
        return Array(parts.dropLast())
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private final class LoginSetupOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var message: String
    nonisolated(unsafe) private var progressFraction: Double?
    nonisolated(unsafe) private var logLines: [String]

    nonisolated init(initialMessage: String, initialLogLines: [String]) {
        self.message = initialMessage
        self.logLines = initialLogLines
    }

    nonisolated func record(line: String) -> (message: String, progressFraction: Double?, logLines: [String]) {
        lock.lock()
        if let parsed = LoginEnvironmentTooling.progressFraction(from: line) {
            progressFraction = parsed
        }
        message = line
        logLines = Array((logLines + [line]).suffix(4))
        let snapshot = (message, progressFraction, logLines)
        lock.unlock()
        return snapshot
    }

    nonisolated func snapshot() -> (message: String, progressFraction: Double?, logLines: [String]) {
        lock.lock()
        let snapshot = (message, progressFraction, logLines)
        lock.unlock()
        return snapshot
    }
}

private struct GoogleLogoMark: View {
    var body: some View {
        Image("GoogleLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
    }
}

private struct LoginProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private struct LoginSimulatorRuntime: Sendable {
    let name: String
    let identifier: String
    let isAvailable: Bool
    let version: (major: Int, minor: Int)
    let supportedDeviceTypes: [LoginSimulatorSupportedDeviceType]
}

private struct LoginSimulatorSupportedDeviceType: Sendable {
    let name: String
    let identifier: String
    let productFamily: String
}

private struct LoginSimulatorDevice: Sendable {
    let name: String
    let udid: String
    let runtimeIdentifier: String
    let state: String

    nonisolated var runtimeVersion: (major: Int, minor: Int) {
        LoginEnvironmentTooling.runtimeVersion(from: runtimeIdentifier)
    }

    nonisolated var runtimeLabel: String {
        let version = runtimeVersion
        if version.minor > 0 {
            return "iOS \(version.major).\(version.minor)"
        }
        return "iOS \(version.major)"
    }
}
