//
//  YouTubeWebView.swift
//  Shufflix
//
//  Created by Zach Rasmussen on 9/30/25.
//

import SwiftUI
import WebKit

struct YouTubeWebView: UIViewRepresentable {
    /// Accepts any of:
    ///  - https://www.youtube.com/watch?v=VIDEO_ID
    ///  - https://youtu.be/VIDEO_ID
    ///  - https://www.youtube.com/embed/VIDEO_ID
    let url: URL

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        #if os(iOS)
        // On modern iOS, this is ignored but safe; it helps older versions.
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        #endif

        // Content controller + message bridge
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "ytBridge")
        ucc.addUserScript(.init(source: Self.injectedCSS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(.init(source: Self.injectedJSBridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear

        // Load sanitized embed page
        let embedURL = Self.normalizedEmbedURL(from: url)
        webView.load(URLRequest(url: embedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // If the URL changes, reload with the new, normalized embed.
        let current = webView.url
        let desired = Self.normalizedEmbedURL(from: url)
        if current != desired {
            context.coordinator.hasReloadedOnce = false
            webView.load(URLRequest(url: desired, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var hasReloadedOnce = false

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ytBridge" else { return }
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }

            switch type {
            case "ready":
                // Player ready: ask JS to unmute if possible (we started muted to satisfy autoplay).
                (message.webView as? WKWebView)?.evaluateJavaScript("window.__ytq?.push({cmd:'unmute'});", completionHandler: nil)

            case "error":
                // One-time silent retry fixes the intermittent config/availability flake.
                guard let webView = message.webView as? WKWebView else { return }
                if !hasReloadedOnce {
                    hasReloadedOnce = true
                    // Small delay gives WebKit a beat to settle before retrying
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        webView.reload()
                    }
                }

            default:
                break
            }
        }

        // If the iframe fails to load at nav layer, a single retry also helps.
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !hasReloadedOnce {
                hasReloadedOnce = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    webView.reload()
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !hasReloadedOnce {
                hasReloadedOnce = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    webView.reload()
                }
            }
        }
    }

    // MARK: - Helpers

    /// Convert watch/short/normal links into a stable /embed URL with safe params.
    private static func normalizedEmbedURL(from input: URL) -> URL {
        // Extract video id
        let vid = Self.extractVideoID(from: input) ?? input.lastPathComponent

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "www.youtube.com"
        comps.path = "/embed/\(vid)"

        // Safe defaults:
        //  - autoplay=1 + mute=1 satisfies autoplay policies
        //  - playsinline=1 avoids full-screen takeover
        //  - rel=0 keeps related videos clean
        //  - modestbranding=1 reduces chrome
        //  - enablejsapi=1 lets our bridge control the player
        //  - origin is set to a neutral value to keep YT happy with JS API calls
        comps.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "mute", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "modestbranding", value: "1"),
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "origin", value: "https://shufflix.local")
        ]

        return comps.url ?? input
    }

    /// Try common URL shapes to grab the YouTube video id.
    private static func extractVideoID(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()

        if host.contains("youtube.com") {
            // watch?v=ID
            if url.path == "/watch" {
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
                    return v
                }
            }
            // embed/ID or short URLs like /shorts/ID -> We just use lastPathComponent
            if url.path.contains("/embed/") || url.path.contains("/shorts/") {
                return url.lastPathComponent
            }
        } else if host.contains("youtu.be") {
            return url.lastPathComponent
        }

        // Fallback: attempt to parse "v=" if present anywhere
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        return nil
    }

    // MARK: - Injected CSS & JS

    /// Light CSS to make the player fill, avoid flashes, and keep background clean.
    private static let injectedCSS = """
    const css = `
      html, body { margin:0; padding:0; background:transparent; height:100%; }
      iframe { position:fixed; inset:0; width:100%; height:100%; border:0; }
    `;
    const style = document.createElement('style');
    style.type = 'text/css';
    style.appendChild(document.createTextNode(css));
    document.documentElement.appendChild(style);
    """

    /// JS bridge that:
    ///  - Loads IFrame API (adds <script src="https://www.youtube.com/iframe_api">)
    ///  - Boots a YT.Player over the existing iframe
    ///  - Posts messages back to iOS on ready/error/state
    ///  - Keeps a tiny command queue to unmute on ready
    private static let injectedJSBridge = """
    (function() {
      // Guard: only run once
      if (window.__YT_BRIDGE_LOADED__) return;
      window.__YT_BRIDGE_LOADED__ = true;

      // Simple command queue the native side can push to
      window.__ytq = [];
      function flushCommands(player) {
        while (window.__ytq.length) {
          const msg = window.__ytq.shift();
          if (!msg || !msg.cmd) continue;
          try {
            if (msg.cmd === 'unmute') { player.unMute(); }
          } catch (_) {}
        }
      }

      function post(type, data) {
        try {
          window.webkit?.messageHandlers?.ytBridge?.postMessage({ type, data });
        } catch (_) {}
      }

      // Find the main iframe (YouTube embed)
      function findYTFrame() {
        const iframes = document.getElementsByTagName('iframe');
        for (let i=0; i<iframes.length; i++) {
          const src = (iframes[i].getAttribute('src') || '');
          if (src.indexOf('/embed/') !== -1) return iframes[i];
        }
        return null;
      }

      // Load the IFrame API
      function loadAPI(cb) {
        if (window.YT && window.YT.Player) return cb();
        const tag = document.createElement('script');
        tag.src = 'https://www.youtube.com/iframe_api';
        tag.onload = () => {
          // give it a tick to register YT on window
          setTimeout(cb, 0);
        };
        document.head.appendChild(tag);
      }

      // When API is ready it calls this
      window.onYouTubeIframeAPIReady = function() {
        const frame = findYTFrame();
        if (!frame) { post('error', { code: 'no_iframe' }); return; }

        const player = new YT.Player(frame, {
          events: {
            'onReady': function(e) {
              // Autoplay should already be in-flight (muted). Unmute on ready via queue.
              post('ready', {});
              flushCommands(e.target);
            },
            'onError': function(e) {
              // Common YT error codes: 2, 5, 100, 101, 150
              post('error', { code: e && e.data });
            },
            'onStateChange': function(e) {
              post('state', { state: e && e.data });
            }
          },
          playerVars: {
            // reiterate safe vars
            autoplay: 1, mute: 1, playsinline: 1, rel: 0, modestbranding: 1
          }
        });
      };

      // Kick everything off
      loadAPI(function() {
        if (window.YT && window.YT.Player) {
          // If API initialized before onYouTubeIframeAPIReady assigned
          window.onYouTubeIframeAPIReady();
        }
      });
    })();
    """
}
