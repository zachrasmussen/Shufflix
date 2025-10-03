//
//  LocalHTMLSheet.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/3/25.
//

import Foundation
import SwiftUI
import WebKit

struct LocalHTMLSheet: View {
    let title: String
    let resourceName: String // "terms" or "privacy"

    var body: some View {
        NavigationStack {
            LocalHTMLView(resourceName: resourceName)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct LocalHTMLView: UIViewRepresentable {
    let resourceName: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.allowsBackForwardNavigationGestures = true

        if let url = Bundle.main.url(forResource: resourceName, withExtension: "html") {
            // allow relative links like terms → privacy.html to work offline
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
