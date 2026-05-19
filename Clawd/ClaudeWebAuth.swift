import AppKit
import WebKit

final class ClaudeSignInWindowController: NSWindowController, WKNavigationDelegate {
    private let webView: WKWebView
    private let onComplete: (Bool) -> Void

    init(onComplete: @escaping (Bool) -> Void) {
        self.onComplete = onComplete

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: config)

        // Spoof desktop Safari so Google OAuth doesn't bail with "There was an error logging you in"
        // (Google blocks WKWebView by default to prevent OAuth phishing in embedded webviews).
        self.webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign In to Claude — use Email"
        window.center()
        window.contentView = webView
        super.init(window: window)

        self.webView.navigationDelegate = self
    }

    required init?(coder: NSCoder) { nil }

    func start() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // On the login page, nudge the user toward email sign-in (Google OAuth
        // is fingerprinted out of WKWebView; email login works reliably).
        if let url = webView.url?.absoluteString, url.contains("/login") {
            injectLoginHelpers()
        }

        UsageAPIClient.currentCookieHeader { cookieHeader in
            guard let cookieHeader else { return }
            UsageAPIClient.organizationID(cookieHeader: cookieHeader) { [weak self] organizationID in
                guard let self else { return }
                guard organizationID != nil else { return }
                DispatchQueue.main.async {
                    self.window?.title = "Signed in — fetching usage…"
                    self.close()
                    self.onComplete(true)
                }
            }
        }
    }

    private func injectLoginHelpers() {
        // Try multiple selectors so we survive small DOM changes; focus first match;
        // also inject a one-time hint banner above the form.
        let js = """
        (function() {
          const selectors = [
            'input[type="email"]',
            'input[name="email"]',
            'input[autocomplete="email"]',
            'input[placeholder*="email" i]'
          ];
          let emailField = null;
          for (const s of selectors) {
            const el = document.querySelector(s);
            if (el) { emailField = el; break; }
          }
          if (emailField) {
            emailField.focus();
            try { emailField.scrollIntoView({ block: 'center' }); } catch (e) {}
          }
          if (!document.getElementById('__shanks_tip__') && emailField) {
            const tip = document.createElement('div');
            tip.id = '__shanks_tip__';
            tip.style.cssText = [
              'background:rgba(225,175,60,0.12)',
              'border:1px solid rgba(225,175,60,0.5)',
              'color:#f3e1a8',
              'border-radius:10px',
              'padding:10px 14px',
              'margin:14px auto',
              'max-width:480px',
              'text-align:center',
              'font:13px/1.4 -apple-system,system-ui,sans-serif',
              'box-shadow:0 2px 12px rgba(0,0,0,0.25)'
            ].join(';');
            tip.textContent = 'yarr cap\\'n — use email sign-in below. Google OAuth is blocked inside embedded windows.';
            const host = emailField.closest('form') || emailField.parentElement;
            if (host && host.parentElement) {
              host.parentElement.insertBefore(tip, host);
            }
          }
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("[ClaudeWebAuth] JS inject failed: %@", error.localizedDescription)
            }
        }
    }

    override func close() {
        super.close()
    }
}
