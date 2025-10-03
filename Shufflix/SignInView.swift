//
//  SignInView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production Refactor: 2025-10-03
//

import SwiftUI
import AuthenticationServices
import Supabase
import CryptoKit
import WebKit
import Security

struct SignInView: View {
  // MARK: - UI State
  @Environment(\.colorScheme) private var colorScheme
  @State private var isLoading = false
  @State private var errorMessage: String? = nil
  @State private var animateBlob = false

  // MARK: - OIDC nonce
  @State private var currentNonce: String?

  // MARK: - Policy Sheet State
  @State private var activePolicy: Policy?

  var body: some View {
    ZStack {
      // Background
      backgroundLayer

      // Content Card
      VStack(spacing: 24) {
        // Logo / Mark (from Assets.xcassets)
        Image("SignInLogo")
          .resizable()
          .scaledToFit()
          .frame(width: 115, height: 115)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
              .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.16))
          )
          .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.06), radius: 20, y: 10)
          .padding(.bottom, 4)
          .accessibilityHidden(true)

        // Title + Tagline
        VStack(spacing: 8) {
          Text("Shufflix")
            .font(.system(size: 40, weight: .heavy, design: .rounded))
            .tracking(0.5)
          Text("Less Scrolling. More Watching.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)

        // Sign in with Apple
        signInButton

        // Fine print with tappable links that slide up
        policyFooter
          .padding(.horizontal)
      }
      .padding(.vertical, 32)
      .padding(.horizontal, 20)
      .frame(maxWidth: 440)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18))
      )
      .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.07), radius: 24, y: 10)
      .padding(.horizontal, 16)

      // Loading overlay
      if isLoading {
        Color.black.opacity(0.15).ignoresSafeArea()
        ProgressView()
          .scaleEffect(1.2)
          .progressViewStyle(.circular)
          .padding(24)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18))
          )
      }

      // Error toast
      if let errorMessage {
        ErrorToast(message: errorMessage) {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.9, blendDuration: 0.2)) {
            self.errorMessage = nil
          }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .bottom)
      }
    }
    .sheet(item: $activePolicy) { policy in
      PolicySheet(title: policy.title, resourceName: policy.filename)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .ignoresSafeArea(edges: .bottom)
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
        animateBlob = true
      }
    }
  }
}

// MARK: - Layers & Subviews
private extension SignInView {
  var backgroundLayer: some View {
    ZStack {
      // Soft gradient base
      LinearGradient(
        colors: colorScheme == .dark
          ? [Color(red: 0.06, green: 0.07, blue: 0.10), Color(red: 0.10, green: 0.12, blue: 0.16)]
          : [Color(red: 0.95, green: 0.96, blue: 0.99), Color.white],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      // Decorative blobs
      ZStack {
        blob(color: .purple, baseOpacity: colorScheme == .dark ? 0.35 : 0.18, size: 260)
          .offset(x: animateBlob ? -90 : -40, y: animateBlob ? -180 : -140)
        blob(color: .pink, baseOpacity: colorScheme == .dark ? 0.30 : 0.16, size: 220)
          .offset(x: animateBlob ? 100 : 40, y: animateBlob ? 160 : 120)
        blob(color: .blue, baseOpacity: colorScheme == .dark ? 0.28 : 0.14, size: 240)
          .offset(x: animateBlob ? -10 : 30, y: animateBlob ? 40 : 10)
      }
      .blur(radius: 60)
      .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: animateBlob)
      .allowsHitTesting(false)
    }
  }

  func blob(color: Color, baseOpacity: Double, size: CGFloat) -> some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [color.opacity(baseOpacity), color.opacity(0)],
          center: .center,
          startRadius: 8,
          endRadius: size * 0.8
        )
      )
      .frame(width: size, height: size)
  }

  var signInButton: some View {
    SignInWithAppleButton(.continue) { request in
      // Request basic scopes; keep it simple and privacy-friendly.
      request.requestedScopes = [.fullName, .email]

      // Include a nonce with OIDC providers to prevent replay.
      let nonce = Self.randomNonce()
      currentNonce = nonce
      request.nonce = Self.sha256(nonce)
    } onCompletion: { result in
      switch result {
      case .success(let auth):
        handleAppleAuth(auth)
      case .failure(let err):
        showError(err.localizedDescription)
      }
    }
    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
    .frame(height: 56)
    .clipShape(Capsule())
    .overlay(
      Capsule()
        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.16))
    )
    .opacity(isLoading ? 0.7 : 1)
    .overlay(alignment: .trailing) {
      if isLoading {
        ProgressView()
          .progressViewStyle(.circular)
          .padding(.trailing, 16)
      }
    }
    .disabled(isLoading)
    .accessibilityLabel(Text("Continue with Apple"))
    .padding(.top, 8)
  }

  // Footer with tappable Terms/Privacy presented as a slide-up sheet (local HTML)
  var policyFooter: some View {
    VStack(spacing: 8) {
      Text("By continuing, you agree to the")
        .font(.footnote)
        .foregroundStyle(.secondary)

      HStack(spacing: 6) {
        Button("Terms of Service") { activePolicy = .terms }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityLabel("View Terms of Service")

        Text("and acknowledge the")
          .font(.footnote)
          .foregroundStyle(.secondary)

        Button("Privacy Policy") { activePolicy = .privacy }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityLabel("View Privacy Policy.")
      }
      .fixedSize()
    }
    .multilineTextAlignment(.center)
  }
}

// MARK: - Policy Types (local filenames) & Sheet
private extension SignInView {
  enum Policy: Identifiable {
    case terms, privacy
    var id: String { title }
    var title: String {
      switch self {
      case .terms:   return "Terms of Service"
      case .privacy: return "Privacy Policy"
      }
    }
    var filename: String {
      switch self {
      case .terms:   return "terms"
      case .privacy: return "privacy"
      }
    }
  }
}

// MARK: - Nested helper views (namespaced under SignInView)
extension SignInView {
  struct PolicySheet: View {
    let title: String
    let resourceName: String // e.g., "terms" or "privacy"

    var body: some View {
      NavigationStack {
        PolicyWebView(resourceName: resourceName)
          .navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
      }
    }
  }

  struct PolicyWebView: UIViewRepresentable {
    let resourceName: String

    func makeUIView(context: Context) -> WKWebView {
      let config = WKWebViewConfiguration()
      let webView = WKWebView(frame: .zero, configuration: config)
      webView.scrollView.contentInsetAdjustmentBehavior = .automatic
      webView.allowsBackForwardNavigationGestures = true

      if let url = Bundle.main.url(forResource: resourceName, withExtension: "html") {
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
      }
      return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
  }
}

// MARK: - Optional link-pill style (kept for reuse)
private struct LinkPill: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.footnote.weight(.semibold))
      .underline(true)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(
        Capsule().fill(.ultraThinMaterial)
          .opacity(configuration.isPressed ? 1 : 0.6)
      )
      .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
  }
}

// MARK: - Error Toast
private struct ErrorToast: View {
  let message: String
  let onClose: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .imageScale(.medium)
      Text(message)
        .font(.callout)
        .lineLimit(3)
      Spacer(minLength: 8)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .imageScale(.small)
          .font(.system(size: 14, weight: .bold))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Dismiss error"))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      Capsule(style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          Capsule(style: .continuous)
            .strokeBorder(Color.red.opacity(0.35))
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 6)
    )
    .foregroundStyle(.red)
    .padding(.horizontal, 24)
  }
}

// MARK: - Apple Auth → Supabase
private extension SignInView {
  func showError(_ message: String) {
    Haptics.shared.warning()
    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
      errorMessage = message
    }
  }

  func handleAppleAuth(_ auth: ASAuthorization) {
    guard
      let credential = auth.credential as? ASAuthorizationAppleIDCredential,
      let tokenData = credential.identityToken,
      let idToken = String(data: tokenData, encoding: .utf8)
    else {
      showError("Apple sign-in failed. Please try again.")
      return
    }

    let nonce = currentNonce // Apple may not echo it back; Supabase accepts original here.
    isLoading = true

    Task {
      do {
        let session = try await Supa.client.auth.signInWithIdToken(
          credentials: OpenIDConnectCredentials(
            provider: .apple,
            idToken: idToken,
            nonce: nonce
          )
        )
        await MainActor.run {
          isLoading = false
          errorMessage = nil
          Haptics.shared.success()
          print("✅ Signed in as \(session.user.id)")
        }
      } catch {
        await MainActor.run {
          isLoading = false
          showError(error.localizedDescription)
        }
      }
    }
  }

  // MARK: Nonce helpers
  static func randomNonce(length: Int = 32) -> String {
    precondition(length > 0)
    let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    var result = ""
    result.reserveCapacity(length)
    var remaining = length

    while remaining > 0 {
      var random: UInt8 = 0
      let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
      if status != errSecSuccess { continue }
      result.append(charset[Int(random) % charset.count])
      remaining -= 1
    }
    return result
  }

  static func sha256(_ input: String) -> String {
    let data = Data(input.utf8)
    let hashed = SHA256.hash(data: data)
    return hashed.map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - Preview
#Preview {
  Group {
    SignInView()
      .preferredColorScheme(.light)
    SignInView()
      .preferredColorScheme(.dark)
  }
}
