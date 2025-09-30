//
//  SignInView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//

import Foundation
import SwiftUI
import AuthenticationServices
import Supabase

struct SignInView: View {
  @State private var error: String?

  var body: some View {
    VStack {
      Text("Shufflix")
        .font(.largeTitle)
        .bold()

      SignInWithAppleButton(.continue) { request in
        request.requestedScopes = [.fullName, .email]
      } onCompletion: { result in
        switch result {
        case .success(let auth):
          handleAppleAuth(auth)
        case .failure(let err):
          error = err.localizedDescription
        }
      }
      .signInWithAppleButtonStyle(.black)
      .frame(height: 50)

      if let error = error {
        Text(error).foregroundColor(.red)
      }
    }
    .padding()
  }

  func handleAppleAuth(_ auth: ASAuthorization) {
    guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
          let tokenData = credential.identityToken,
          let idToken = String(data: tokenData, encoding: .utf8)
    else {
      error = "Apple auth failed"
      return
    }

    Task {
      do {
        let session = try await Supa.client.auth.signInWithIdToken(
          credentials: OpenIDConnectCredentials(
            provider: .apple,
            idToken: idToken,
            nonce: nil
          )
        )
        print("✅ Signed in as \(session.user.id)")
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
