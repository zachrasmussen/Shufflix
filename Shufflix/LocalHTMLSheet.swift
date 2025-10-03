//
//  LocalHTMLSheet.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 10/3/25.
//  Production Refactor: 2025-10-03
//

import SwiftUI
import WebKit
import UIKit

// MARK: - Sheet Wrapper

struct LocalHTMLSheet: View {
    let title: String
    let resourceName: String // e.g., "terms" or "privacy"

    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LocalHTMLView(
                    resourceName: resourceName,
                    onStateChange: { state in
                        switch state {
                        case .loading:    isLoading = true;  loadError = nil
                        case .loaded:     isLoading = false; loadError = nil
                        case .failed(let err):
                            isLoading = false
                            loadError = err
                        }
                    }
                )
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)

                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(radius: 8, y: 4)
                        .accessibilityLabel("Loading")
                }

                if let err = loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err).multilineTextAlignment(.center)
                        Button("Close") {
                            // parent typically presents as sheet; defer dismissal to parent
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - UIViewRepresentable

struct LocalHTMLView: UIViewRepresentable {
    enum LoadState {
        case loading
        case loaded
        case failed(String)
    }

    let resourceName: String
    var onStateChange: ((LoadState) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onStateChange: onStateChange) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        // Modern JS on iOS 14+
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        // Inject tiny CSS for dark mode + better readability
        let css = """
        :root {
          color-scheme: light dark;
          --fg: rgb(28,28,30);
          --bg: rgb(242,242,247);
        }
        @media (prefers-color-scheme: dark) {
          :root { --fg: rgb(229,229,234); --bg: rgb(0,0,0); }
        }
        html, body {
          margin: 0; padding: 16px 18px;
          -webkit-text-size-adjust: 100%;
          color: var(--fg); background: transparent;
          font: -apple-system-body;
          line-height: 1.45;
        }
        a { color: -apple-system-blue; text-decoration: underline; }
        h1,h2,h3 { margin-top: 1.2em; }
        """
        let cssSrc = """
        (function(){
          const style = document.createElement('style');
          style.type = 'text/css';
          style.appendChild(document.createTextNode(`\(css)`));
          document.documentElement.appendChild(style);
        })();
        """
        let cssScript = WKUserScript(source: cssSrc, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

        // Light content-sanitization: disable target=_blank JS window.open shenanigans
        let hardeningJS = """
        (function(){
          document.addEventListener('click', function(e){
            const a = e.target.closest('a');
            if (!a) return;
            a.setAttribute('rel','noopener');
          }, true);
        })();
        """
        let hardenScript = WKUserScript(source: hardeningJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)

        config.userContentController.addUserScript(hardenScript)
        config.userContentController.addUserScript(cssScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = .clear

        context.coordinator.load(resourceName: resourceName, in: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // If the resource name changes, reload.
        if context.coordinator.currentResource != resourceName {
            context.coordinator.load(resourceName: resourceName, in: uiView)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onStateChange: ((LoadState) -> Void)?
        fileprivate var currentResource: String?

        init(onStateChange: ((LoadState) -> Void)?) {
            self.onStateChange = onStateChange
        }

        func load(resourceName: String, in webView: WKWebView) {
            currentResource = resourceName
            onStateChange?(.loading)

            if let url = Bundle.main.url(forResource: resourceName, withExtension: "html") {
                // Allow relative links (terms -> privacy.html) to work offline
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                // Friendly fallback if the HTML is missing in the bundle
                let html = """
                <html><body>
                <h2>Document not found</h2>
                <p>We couldn’t locate “\(resourceName).html”.</p>
                </body></html>
                """
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onStateChange?(.loading)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onStateChange?(.loaded)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onStateChange?(.failed(Self.humanize(error)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onStateChange?(.failed(Self.humanize(error)))
        }

        // Keep navigation inside the local bundle; punt external links to the system.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel); return
            }

            // Allow local bundle navigation
            if url.isFileURL {
                decisionHandler(.allow); return
            }

            // Allow anchors / about:blank created during load
            if url.scheme == "about" { decisionHandler(.allow); return }

            // Open external schemes via the system (http/https/mailto/tel, etc.)
            if ["http","https","mailto","tel"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            decisionHandler(.cancel)
        }

        // MARK: WKUIDelegate (basic window.open handling)

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Handle target=_blank by opening externally
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return nil
        }

        // MARK: Helpers

        private static func humanize(_ error: Error) -> String {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                switch ns.code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost:
                    return "Network appears offline. Try again later."
                default: break
                }
            }
            return ns.localizedDescription.isEmpty ? "Failed to load content." : ns.localizedDescription
        }
    }
}
