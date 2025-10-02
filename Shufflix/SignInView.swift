//
//  SignInView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//

import SwiftUI
import AuthenticationServices
import Supabase
import UIKit

struct SignInView: View {
  // MARK: - UI State
  @Environment(\.colorScheme) private var colorScheme
  @State private var isLoading = false
  @State private var errorMessage: String? = nil
  @State private var animateBlob = false

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

        // Fine print
        Text("By continuing, you agree to the Terms and acknowledge the Privacy Policy.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
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
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
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

    isLoading = true

    Task {
      do {
        // Authenticate with Supabase using the Apple ID token
        let session = try await Supa.client.auth.signInWithIdToken(
          credentials: OpenIDConnectCredentials(
            provider: .apple,
            idToken: idToken,
            nonce: nil // If you add a nonce later, pass it here
          )
        )

        // Success feedback
        await MainActor.run {
          isLoading = false
          errorMessage = nil
          UINotificationFeedbackGenerator().notificationOccurred(.success)
          // Root auth router will switch screens
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
