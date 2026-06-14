//
//  LegacyTrackerLoginViewController.swift
//  AidokuLegacy
//
//  WKWebView-hosted OAuth implicit-grant login for AniList. iOS 12 safe (UIKit + WebKit).
//

import UIKit
import WebKit

final class LegacyTrackerLoginViewController: UIViewController, WKNavigationDelegate {
    // Called once with true if a token was captured, false if the user cancelled.
    private let completion: ((Bool) -> Void)?
    private let tracker: LegacyAniListTracker
    private var webView: WKWebView!
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private var didCapture = false

    init(
        tracker: LegacyAniListTracker = .shared,
        completion: ((Bool) -> Void)? = nil
    ) {
        self.tracker = tracker
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AniList Login"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel)
        )
        progressView.frame = CGRect(x: 0, y: 0, width: 120, height: 2)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: progressView)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: [.new], context: nil)
        webView.load(URLRequest(url: tracker.authorizationURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == #keyPath(WKWebView.estimatedProgress) else { return }
        progressView.progress = Float(webView.estimatedProgress)
        progressView.isHidden = webView.estimatedProgress >= 1
    }

    // MARK: - Navigation handling

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, captureTokenIfPresent(in: url) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressView.isHidden = true
        if let url = webView.url {
            _ = captureTokenIfPresent(in: url)
        }
    }

    // Extracts and stores an access token from a redirect URL fragment, then dismisses.
    @discardableResult
    private func captureTokenIfPresent(in url: URL) -> Bool {
        guard !didCapture else { return true }
        guard let token = LegacyAniListTracker.accessToken(fromRedirect: url) else {
            return false
        }
        didCapture = true
        tracker.setAccessToken(token)
        finish(success: true)
        return true
    }

    @objc private func cancel() {
        finish(success: false)
    }

    private func finish(success: Bool) {
        let completion = self.completion
        let dismissAction = {
            if let completion = completion {
                completion(success)
            }
        }
        if let navigationController = navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
            dismissAction()
        } else if presentingViewController != nil {
            dismiss(animated: true, completion: dismissAction)
        } else {
            dismissAction()
        }
    }
}
