//
//  YouTubeWebView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//  Production-hardened: 2025-10-03
//

import SwiftUI
import WebKit

struct YouTubeWebView: UIViewRepresentable {
    let url: URL

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        #if os(iOS)
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        config.mediaTypesRequiringUserActionForPlayback = []
        #endif

        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: Coordinator.bridgeName)
        ucc.addUserScript(.init(source: Self.injectedCSS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(.init(source: Self.injectedJSBridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear

        context.coordinator.webView = webView
        context.coordinator.load(embedURL: Self.normalizedEmbedURL(from: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let desired = Self.normalizedEmbedURL(from: url)
        if webView.url != desired {
            context.coordinator.resetRetries()
            context.coordinator.load(embedURL: desired)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        static let bridgeName = "ytBridge"

        weak var webView: WKWebView?
        private var retryCount = 0
        private let maxRetries = 3

        func resetRetries() { retryCount = 0 }

        func load(embedURL: URL) {
            let req = URLRequest(url: embedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            webView?.load(req)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.bridgeName,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "ready":
                webView?.evaluateJavaScript("window.__ytq?.push({cmd:'unmute'});", completionHandler: nil)
                retryCount = 0 // reset once healthy

            case "error":
                if let data = body["data"] as? [String: Any], let code = data["code"] {
                    #if DEBUG
                    print("[YouTubeWebView] error code:", code)
                    #endif
                }
                retryWithBackoff()

            default: break
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            retryWithBackoff()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            retryWithBackoff()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navAction.request.url, !Self.isAllowed(url: url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func retryWithBackoff() {
            guard retryCount < maxRetries, let webView, let failingURL = webView.url else { return }
            retryCount += 1
            let delay = pow(2.0, Double(retryCount)) * 0.3 // 0.3s, 0.6s, 1.2s
            #if DEBUG
            print("[YouTubeWebView] retry \(retryCount) in \(delay)s")
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                webView.reload()
            }
        }

        private static func isAllowed(url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            if host.hasSuffix("youtube.com") || host.hasSuffix("ytimg.com") { return true }
            if url.scheme == "about" || url.scheme == "data" { return true }
            return false
        }
    }

    // MARK: - Helpers

    private static func normalizedEmbedURL(from input: URL) -> URL {
        let vid = extractVideoID(from: input) ?? input.lastPathComponent
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "www.youtube.com"
        comps.path = "/embed/\(vid)"
        comps.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "mute", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "modestbranding", value: "1"),
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "origin", value: "https://shufflix.app") // ✅ safer origin
        ]
        return comps.url ?? input
    }

    private static func extractVideoID(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()

        if host.contains("youtube.com") {
            if url.path == "/watch",
               let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
                return v
            }
            if url.path.contains("/embed/") || url.path.contains("/shorts/") {
                return url.lastPathComponent
            }
        } else if host.contains("youtu.be") {
            return url.lastPathComponent
        }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        return nil
    }

    // MARK: - Injected CSS & JS

    private static let injectedCSS = """
    const css = `
      html, body { margin:0; padding:0; background:transparent; height:100%; }
      iframe { position:fixed; inset:0; width:100%; height:100%; border:0; background:transparent; }
    `;
    const style = document.createElement('style');
    style.type = 'text/css';
    style.appendChild(document.createTextNode(css));
    document.documentElement.appendChild(style);
    """

    private static let injectedJSBridge = """
    (function() {
      if (window.__YT_BRIDGE_LOADED__) return;
      window.__YT_BRIDGE_LOADED__ = true;

      window.__ytq = [];
      function flushCommands(player) {
        while (window.__ytq.length) {
          const msg = window.__ytq.shift();
          if (!msg || !msg.cmd) continue;
          try { if (msg.cmd === 'unmute') player.unMute(); } catch (_) {}
        }
      }

      function post(type, data) {
        try { window.webkit?.messageHandlers?.ytBridge?.postMessage({ type, data }); } catch (_) {}
      }

      function findYTFrame() {
        const iframes = document.getElementsByTagName('iframe');
        for (let i=0; i<iframes.length; i++) {
          const src = (iframes[i].getAttribute('src') || '');
          if (src.indexOf('/embed/') !== -1) return iframes[i];
        }
        return null;
      }

      function loadAPI(cb) {
        if (window.YT && window.YT.Player) return cb();
        const tag = document.createElement('script');
        tag.src = 'https://www.youtube.com/iframe_api';
        tag.onload = () => setTimeout(cb, 0);
        document.head.appendChild(tag);
      }

      window.onYouTubeIframeAPIReady = function() {
        const frame = findYTFrame();
        if (!frame) { post('error', { code: 'no_iframe' }); return; }

        new YT.Player(frame, {
          events: {
            'onReady': function(e) { post('ready', {}); flushCommands(e.target); },
            'onError': function(e) { post('error', { code: e && e.data }); },
            'onStateChange': function(e) { post('state', { state: e && e.data }); }
          },
          playerVars: { autoplay: 1, mute: 1, playsinline: 1, rel: 0, modestbranding: 1 }
        });
      };

      loadAPI(function() {
        if (window.YT && window.YT.Player && typeof window.onYouTubeIframeAPIReady === 'function') {
          window.onYouTubeIframeAPIReady();
        }
      });
    })();
    """
}
