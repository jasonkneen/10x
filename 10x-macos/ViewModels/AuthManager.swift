import Foundation
import AuthenticationServices
import AppKit
import CryptoKit
import Security
import Supabase

/// Manages authentication state via Supabase auth sessions.
/// Supports Google and Apple sign-in via web-based OAuth flows.
@Observable
@MainActor
final class AuthManager {
    private enum StartupAuthError: Error {
        case timedOut
        case invalidConfiguration
        case sessionMissing
    }

    private struct RefreshedSessionPayload: Sendable {
        let accessToken: String
        let refreshToken: String?
        let userId: String?
        let userEmail: String?
    }

    enum SignInProvider: String, Sendable {
        case google
        case apple

        var progressMessage: String {
            switch self {
            case .google:
                return "Opening Google sign-in..."
            case .apple:
                return "Signing in with Apple..."
            }
        }

        var oauthProviderValue: String { rawValue }
    }

    private struct AppleProfileName: Sendable {
        let fullName: String?
        let givenName: String?
        let familyName: String?
    }

    private static let sdkSessionSyncTimeoutSeconds: Double = 5
    private static let startupRefreshTimeoutSeconds: Double = 8
    private static let accessTokenRefreshLeewaySeconds: TimeInterval = 60

    var isAuthenticated = false
    var isCheckingAuth = false
    var activeSignInProvider: SignInProvider?
    var accessToken: String?
    var refreshToken: String?
    var userId: String?
    var userEmail: String?
    var authError: String?

    private let tokenKey = "tenx_access_token"
    private let refreshTokenKey = "tenx_refresh_token"
    private let userIdKey = "tenx_user_id"
    private let userEmailKey = "tenx_user_email"
    private static let localDevModeKey = "tenx_local_dev_mode"
    private static let localDevAccessToken = "tenx-local-dev-token"
    private let callbackScheme = "app.10x.macos"
    private let callbackURLString = "app.10x.macos://auth/callback"
    private let authTokenStore = AuthTokenStore()
    private var webAuthSession: ASWebAuthenticationSession?
    private var presentationProvider = AuthPresentationProvider()
    private var authStateTask: Task<Void, Never>?
    private var currentAppleNonce: String?
    private var appleSignInCoordinator: AppleSignInCoordinator?

    var isAuthenticating: Bool {
        activeSignInProvider != nil
    }

    /// Local development mode: skips Supabase auth entirely so the app can run
    /// against a local backend without hosted credentials. DEBUG builds only.
    nonisolated static var isLocalDevModeAvailable: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    var isLocalDevSession: Bool {
        accessToken == Self.localDevAccessToken
    }

    var signInStatusMessage: String? {
        activeSignInProvider?.progressMessage
    }

    init() {
        if Self.isLocalDevModeAvailable, UserDefaults.standard.bool(forKey: Self.localDevModeKey) {
            accessToken = Self.localDevAccessToken
            userId = "local-dev"
            isAuthenticated = true
            return
        }

        startAuthStateObserver()

        if let saved = authTokenStore.string(for: tokenKey, allowUserInteraction: false), !saved.isEmpty {
            accessToken = saved
            refreshToken = authTokenStore.string(for: refreshTokenKey, allowUserInteraction: false)
            userId = UserDefaults.standard.string(forKey: userIdKey)
            userEmail = UserDefaults.standard.string(forKey: userEmailKey)
            isAuthenticated = true
            isCheckingAuth = true

            let token = saved
            let refresh = refreshToken
            Task {
                defer {
                    self.isCheckingAuth = false
                }

                let restored = await self.restoreSavedSession(
                    accessToken: token,
                    refreshToken: refresh
                )
                if !restored {
                    print("[Auth] Startup restore failed, signing out")
                    self.signOut()
                }
            }
        }
    }

    func signInWithGoogle() {
        startOAuthSignIn(provider: .google)
    }

    /// DEBUG-only: continue without an account for local development against
    /// a local backend (see `local-backend/`). No Supabase calls are made.
    func continueLocally() {
        guard Self.isLocalDevModeAvailable else { return }
        UserDefaults.standard.set(true, forKey: Self.localDevModeKey)
        accessToken = Self.localDevAccessToken
        refreshToken = nil
        userId = "local-dev"
        userEmail = nil
        authError = nil
        isAuthenticated = true
    }

    private func startOAuthSignIn(provider: SignInProvider) {
        guard activeSignInProvider == nil || activeSignInProvider == provider else { return }
        activeSignInProvider = provider
        currentAppleNonce = nil

        let supabaseURL = Config.supabaseURL
        guard !supabaseURL.isEmpty else {
            activeSignInProvider = nil
            authError = "Supabase URL not configured. Set SUPABASE_URL in Config."
            return
        }

        guard let authBaseURL = URL(string: "\(supabaseURL)/auth/v1/authorize") else {
            activeSignInProvider = nil
            authError = "Invalid auth URL"
            return
        }

        var components = URLComponents(url: authBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "provider", value: provider.oauthProviderValue),
            URLQueryItem(name: "redirect_to", value: callbackURLString),
        ]

        guard let url = components?.url else {
            activeSignInProvider = nil
            authError = "Failed to build \(provider.rawValue.capitalized) sign-in URL"
            return
        }

        authError = nil

        let completionHandler: @Sendable (URL?, (any Error)?) -> Void = { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.webAuthSession = nil
                defer {
                    self.activeSignInProvider = nil
                }

                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    self.authError = error.localizedDescription
                    return
                }

                guard let callbackURL else {
                    self.authError = "No callback URL received. Ensure Supabase allows \(self.callbackURLString) as a redirect URL."
                    return
                }

                await self.handleOAuthCallback(url: callbackURL)
            }
        }

        let session: ASWebAuthenticationSession
        if #available(macOS 14.4, *) {
            session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme),
                completionHandler: completionHandler
            )
        } else {
            session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme,
                completionHandler: completionHandler
            )
        }

        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = presentationProvider
        webAuthSession = session
        if !session.start() {
            webAuthSession = nil
            activeSignInProvider = nil
            authError = "Could not start \(provider.rawValue.capitalized) sign-in."
        }
    }

    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard activeSignInProvider == nil else { return }

        let rawNonce = Self.randomNonceString()
        currentAppleNonce = rawNonce
        activeSignInProvider = .apple
        authError = nil

        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(rawNonce)
    }

    func signInWithApple() {
        if !Config.useNativeAppleSignIn {
            startOAuthSignIn(provider: .apple)
            return
        }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        prepareAppleSignInRequest(request)

        guard activeSignInProvider == .apple else { return }

        let coordinator = AppleSignInCoordinator { [weak self] result in
            guard let self else { return }
            self.appleSignInCoordinator = nil
            self.handleAppleSignInCompletion(result)
        }

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = coordinator
        controller.presentationContextProvider = presentationProvider
        coordinator.controller = controller
        appleSignInCoordinator = coordinator
        controller.performRequests()
    }

    private func startAppleOAuthFallback() {
        print(
            "[Auth] Native Apple ID token audience was rejected by Supabase. " +
            "Falling back to Apple OAuth. Add app.10x.macos to the Supabase Apple provider Client IDs."
        )
        startOAuthSignIn(provider: .apple)
    }

    func handleAppleSignInCompletion(_ result: Result<ASAuthorization, any Error>) {
        Task { @MainActor in
            switch result {
            case .failure(let error):
                currentAppleNonce = nil
                activeSignInProvider = nil
                if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
                    return
                }
                authError = error.localizedDescription
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                    currentAppleNonce = nil
                    activeSignInProvider = nil
                    authError = "Apple sign-in returned an unsupported credential."
                    return
                }

                guard let rawNonce = currentAppleNonce else {
                    currentAppleNonce = nil
                    activeSignInProvider = nil
                    authError = "Apple sign-in state was lost. Please try again."
                    return
                }

                guard
                    let identityTokenData = credential.identityToken,
                    let identityToken = String(data: identityTokenData, encoding: .utf8),
                    !identityToken.isEmpty
                else {
                    currentAppleNonce = nil
                    activeSignInProvider = nil
                    authError = "Apple sign-in did not return a valid identity token."
                    return
                }

                await completeAppleSignIn(
                    identityToken: identityToken,
                    rawNonce: rawNonce,
                    fullName: credential.fullName
                )
            }
        }
    }

    private func handleOAuthCallback(url: URL) async {
        let components: URLComponents?

        if let fragment = url.fragment {
            components = URLComponents(string: "?\(fragment)")
        } else {
            components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        }

        guard let items = components?.queryItems else {
            authError = "Could not parse auth callback"
            return
        }

        let params = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        if let error = params["error_description"] ?? params["error"] {
            authError = Self.normalizedOAuthErrorMessage(
                rawValue: error,
                provider: activeSignInProvider,
                supabaseURL: Config.supabaseURL,
                callbackURLString: callbackURLString
            )
            return
        }

        if params["code"] != nil {
            authError = "Supabase returned a web redirect instead of tokens. Make sure \(callbackURLString) is in Supabase redirect URLs and that the project Site URL is not pointing at your admin page."
            return
        }

        guard let token = params["access_token"] else {
            authError = "No access token in callback. Supabase likely redirected to its Site URL instead of \(callbackURLString)."
            return
        }

        let refresh = params["refresh_token"]

        await saveSession(
            accessToken: token,
            refreshToken: refresh,
            userId: nil,
            userEmail: nil
        )

        Task {
            await fetchUser(accessToken: token)
        }
    }

    private func completeAppleSignIn(
        identityToken: String,
        rawNonce: String,
        fullName: PersonNameComponents?
    ) async {
        do {
            let snapshot = try await SupabaseService.shared.signInWithApple(
                idToken: identityToken,
                nonce: rawNonce
            )

            await persistSession(
                accessToken: snapshot.accessToken,
                refreshToken: snapshot.refreshToken,
                userId: snapshot.userId,
                userEmail: snapshot.userEmail,
                syncToSupabase: false
            )

            let profileName = Self.appleProfileName(from: fullName)
            if profileName.fullName != nil || profileName.givenName != nil || profileName.familyName != nil {
                do {
                    try await SupabaseService.shared.updateCurrentUser(
                        fullName: profileName.fullName,
                        givenName: profileName.givenName,
                        familyName: profileName.familyName
                    )
                } catch {
                    print("[Auth] Failed to persist Apple profile metadata: \(error)")
                }
            }
            currentAppleNonce = nil
            activeSignInProvider = nil
        } catch {
            currentAppleNonce = nil

            if Self.isAppleNativeAudienceMismatch(error) {
                startAppleOAuthFallback()
                return
            }

            activeSignInProvider = nil
            authError = error.localizedDescription
        }
    }

    func refreshSession() async -> Bool {
        guard let refresh = refreshToken else {
            return false
        }

        do {
            let payload = try await Self.withTimeout(seconds: Self.startupRefreshTimeoutSeconds) {
                try await Self.requestRefreshedSession(refreshToken: refresh)
            }
            await persistSession(
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                userId: payload.userId,
                userEmail: payload.userEmail,
                syncToSupabase: true
            )
            return true
        } catch {
            return false
        }
    }

    func validAccessToken() async -> String? {
        guard let accessToken, !accessToken.isEmpty else {
            return nil
        }

        if isLocalDevSession {
            return accessToken
        }

        if !Self.isJWTExpiredOrNearExpiry(accessToken, leewaySeconds: Self.accessTokenRefreshLeewaySeconds) {
            return accessToken
        }

        let refreshed = await refreshSession()
        if refreshed, let accessToken = self.accessToken, !accessToken.isEmpty {
            return accessToken
        }

        signOut()
        authError = "Session expired. Please sign in again."
        return nil
    }

    private func fetchUser(accessToken: String) async {
        let supabaseURL = Config.supabaseURL
        guard !supabaseURL.isEmpty else { return }

        guard let url = URL(string: "\(supabaseURL)/auth/v1/user") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let id = json["id"] as? String
                let email = json["email"] as? String
                userId = id
                userEmail = email
                if let id { UserDefaults.standard.set(id, forKey: userIdKey) }
                if let email { UserDefaults.standard.set(email, forKey: userEmailKey) }
            }
        } catch {
            print("[Auth] Failed to fetch user: \(error)")
        }
    }

    private func saveSession(accessToken: String, refreshToken: String?, userId: String?, userEmail: String?) async {
        await persistSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
            userEmail: userEmail,
            syncToSupabase: true
        )
    }

    private func persistSession(
        accessToken: String,
        refreshToken: String?,
        userId: String?,
        userEmail: String?,
        syncToSupabase: Bool
    ) async {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userId = userId
        self.userEmail = userEmail
        self.authError = nil

        authTokenStore.set(accessToken, for: tokenKey)
        authTokenStore.set(refreshToken, for: refreshTokenKey)
        if let userId, !userId.isEmpty {
            UserDefaults.standard.set(userId, forKey: userIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userIdKey)
        }
        if let userEmail, !userEmail.isEmpty {
            UserDefaults.standard.set(userEmail, forKey: userEmailKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userEmailKey)
        }

        if syncToSupabase {
            await syncSessionToSupabaseSDK(
                accessToken: accessToken,
                refreshToken: refreshToken
            )
        }

        self.isAuthenticated = true
    }

    private func restoreSavedSession(accessToken: String, refreshToken: String?) async -> Bool {
        do {
            let snapshot = try await Self.withTimeout(seconds: Self.sdkSessionSyncTimeoutSeconds) {
                try await SupabaseService.shared.setSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }
            await persistSession(
                accessToken: snapshot.accessToken,
                refreshToken: snapshot.refreshToken,
                userId: snapshot.userId,
                userEmail: snapshot.userEmail,
                syncToSupabase: false
            )
            return true
        } catch {
            print("[Auth] setSession failed or timed out, attempting manual refresh: \(error)")
        }

        guard let refreshToken, !refreshToken.isEmpty else {
            return false
        }

        do {
            let payload = try await Self.withTimeout(seconds: Self.startupRefreshTimeoutSeconds) {
                try await Self.requestRefreshedSession(refreshToken: refreshToken)
            }
            await persistSession(
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                userId: payload.userId,
                userEmail: payload.userEmail,
                syncToSupabase: true
            )
            return true
        } catch {
            print("[Auth] Manual refresh timed out: \(error)")
            return false
        }
    }

    private func syncSessionToSupabaseSDK(accessToken: String, refreshToken: String?) async {
        guard let refreshToken, !refreshToken.isEmpty else { return }

        do {
            _ = try await Self.withTimeout(seconds: Self.sdkSessionSyncTimeoutSeconds) {
                try await SupabaseService.shared.setSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }
        } catch {
            print("[Auth] Timed out syncing Supabase session: \(error)")
        }
    }

    private func startAuthStateObserver() {
        authStateTask?.cancel()
        authStateTask = Task { [weak self] in
            guard let self else { return }
            let stream = await SupabaseService.shared.authStateChanges()
            for await update in stream {
                await self.handleSupabaseAuthStateUpdate(update)
            }
        }
    }

    private func handleSupabaseAuthStateUpdate(_ update: SupabaseAuthStateUpdate) async {
        switch update.event {
        case .signedOut:
            clearSessionState()
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
            guard shouldAcceptSupabaseSessionUpdate(update) else { return }
            guard let session = update.session else { return }
            await persistSession(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                userId: session.userId,
                userEmail: session.userEmail,
                syncToSupabase: false
            )
            if isCheckingAuth {
                isCheckingAuth = false
            }
        default:
            break
        }
    }

    private func shouldAcceptSupabaseSessionUpdate(_ update: SupabaseAuthStateUpdate) -> Bool {
        if update.event == .initialSession, update.session == nil {
            return !isCheckingAuth && accessToken == nil && refreshToken == nil
        }

        if update.session == nil {
            return false
        }

        if isAuthenticated || isCheckingAuth || accessToken != nil || refreshToken != nil {
            return true
        }

        return update.event == .signedIn
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw StartupAuthError.timedOut
            }

            guard let result = try await group.next() else {
                throw StartupAuthError.timedOut
            }

            group.cancelAll()
            return result
        }
    }

    private static func requestRefreshedSession(refreshToken: String) async throws -> RefreshedSessionPayload {
        let supabaseURL = Config.supabaseURL
        guard !supabaseURL.isEmpty,
              let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token") else {
            throw StartupAuthError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = startupRefreshTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw StartupAuthError.sessionMissing
        }

        let refreshedToken = json["refresh_token"] as? String
        let user = json["user"] as? [String: Any]

        return RefreshedSessionPayload(
            accessToken: accessToken,
            refreshToken: refreshedToken,
            userId: user?["id"] as? String,
            userEmail: user?["email"] as? String
        )
    }

    private static func isJWTExpiredOrNearExpiry(_ jwt: String, leewaySeconds: TimeInterval) -> Bool {
        guard let expiration = jwtExpiration(jwt) else {
            return false
        }
        return Date().timeIntervalSince1970 >= expiration - leewaySeconds
    }

    private static func jwtExpiration(_ jwt: String) -> TimeInterval? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        let payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - payload.count % 4) % 4
        let paddedPayload = payload + String(repeating: "=", count: paddingLength)

        guard let data = Data(base64Encoded: paddedPayload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let exp = json["exp"] as? NSNumber {
            return exp.doubleValue
        }
        return nil
    }

    private static func randomNonceString(length: Int = 32) -> String {
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var randomBytes = [UInt8](repeating: 0, count: length)

        if SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes) != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        return String(randomBytes.map { characters[Int($0) % characters.count] })
    }

    private static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func appleProfileName(from components: PersonNameComponents?) -> AppleProfileName {
        let givenName = trimmedNameComponent(components?.givenName)
        let middleName = trimmedNameComponent(components?.middleName)
        let familyName = trimmedNameComponent(components?.familyName)
        let fullNameComponents = [givenName, middleName, familyName].compactMap { $0 }
        let fullName = fullNameComponents.isEmpty ? nil : fullNameComponents.joined(separator: " ")

        return AppleProfileName(
            fullName: fullName,
            givenName: givenName,
            familyName: familyName
        )
    }

    private static func trimmedNameComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedOAuthErrorMessage(
        rawValue: String,
        provider: SignInProvider?,
        supabaseURL: String,
        callbackURLString: String
    ) -> String {
        let decoded = decodedOAuthCallbackValue(rawValue)
        guard provider == .apple else {
            return decoded
        }

        guard decoded.localizedCaseInsensitiveContains("Unable to exchange external code") else {
            return decoded
        }

        let projectHost = URL(string: supabaseURL)?.host ?? "<your-project-ref>.supabase.co"
        return """
        \(decoded). This app uses Apple web OAuth here. Check Supabase Auth > Sign In / Providers > Apple: the client ID must be your Apple Services ID, the client secret must still be valid, and Apple must allow Website URL https://\(projectHost) with redirect https://\(projectHost)/auth/v1/callback. Also keep \(callbackURLString) in the Supabase redirect allow list.
        """
    }

    static func decodedOAuthCallbackValue(_ value: String) -> String {
        let plusNormalized = value.replacingOccurrences(of: "+", with: " ")
        return plusNormalized.removingPercentEncoding ?? plusNormalized
    }

    private static func isAppleNativeAudienceMismatch(_ error: any Error) -> Bool {
        if case let AuthError.api(message, errorCode, _, _) = error {
            if errorCode == .unexpectedAudience {
                return true
            }
            return message.localizedCaseInsensitiveContains("unacceptable audience in id_token")
        }

        return error.localizedDescription.localizedCaseInsensitiveContains(
            "unacceptable audience in id_token"
        )
    }

    func handleUnauthorized() async {
        guard !isLocalDevSession else { return }
        let refreshed = await refreshSession()
        if !refreshed {
            signOut()
        }
    }

    func signOut() {
        let wasLocalDevSession = isLocalDevSession
        UserDefaults.standard.removeObject(forKey: Self.localDevModeKey)
        clearSessionState()
        guard !wasLocalDevSession else { return }
        Task {
            await SupabaseService.shared.signOut()
        }
    }

    private func clearSessionState() {
        accessToken = nil
        refreshToken = nil
        userId = nil
        userEmail = nil
        isAuthenticated = false
        authError = nil
        webAuthSession = nil

        authTokenStore.remove(tokenKey)
        authTokenStore.remove(refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: userIdKey)
        UserDefaults.standard.removeObject(forKey: userEmailKey)
    }
}

private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate {
    var controller: ASAuthorizationController?

    private let completion: @MainActor (Result<ASAuthorization, any Error>) -> Void

    init(
        completion: @escaping @MainActor (Result<ASAuthorization, any Error>) -> Void
    ) {
        self.completion = completion
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        self.controller = nil
        Task { @MainActor in
            completion(.success(authorization))
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        self.controller = nil
        Task { @MainActor in
            completion(.failure(error))
        }
    }
}

private class AuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding, ASAuthorizationControllerPresentationContextProviding {
    private func currentAnchor() -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        currentAnchor()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        currentAnchor()
    }
}
