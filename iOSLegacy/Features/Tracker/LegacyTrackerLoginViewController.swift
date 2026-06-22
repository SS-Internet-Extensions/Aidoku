//
//  LegacyTrackerLoginViewController.swift
//  AidokuLegacy
//
//  WKWebView-hosted OAuth login for the supported trackers. iOS 12 safe (UIKit + WebKit).
//
//  - AniList uses the implicit grant: the redirect carries the access token in its
//    fragment, captured directly.
//  - MyAnimeList uses the PKCE authorization-code grant: the redirect carries a
//    `?code=`, which is exchanged for an access token before finishing.
//

import UIKit
import WebKit

final class LegacyTrackerLoginViewController: UIViewController, WKNavigationDelegate {
    // Called once with true if login succeeded, false if the user cancelled.
    private let completion: ((Bool) -> Void)?
    private let trackerId: LegacyTrackerId
    private let anilist: LegacyAniListTracker
    private let myanimelist: LegacyMyAnimeListTracker
    private var webView: WKWebView!
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private var didCapture = false

    init(
        trackerId: LegacyTrackerId,
        anilist: LegacyAniListTracker = .shared,
        myanimelist: LegacyMyAnimeListTracker = .shared,
        completion: ((Bool) -> Void)? = nil
    ) {
        self.trackerId = trackerId
        self.anilist = anilist
        self.myanimelist = myanimelist
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Authorization URL for the selected tracker.
    private var authorizationURL: URL {
        switch trackerId {
            case .anilist:
                return anilist.authorizationURL
            case .myanimelist:
                return myanimelist.authorizationURL
        }
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
        title = String(format: LegacyString("tracker.login.title"), trackerId.displayName)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel)
        )
        progressView.frame = CGRect(x: 0, y: 0, width: 120, height: 2)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: progressView)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: [.new], context: nil)
        webView.load(URLRequest(url: authorizationURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
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
        if let url = navigationAction.request.url, captureCredentialIfPresent(in: url) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressView.isHidden = true
        if let url = webView.url {
            _ = captureCredentialIfPresent(in: url)
        }
    }

    // Extracts a token (AniList) or code (MyAnimeList) from a redirect URL, completes
    // the login, then dismisses. Returns true when a credential was found.
    @discardableResult
    private func captureCredentialIfPresent(in url: URL) -> Bool {
        guard !didCapture else { return true }
        switch trackerId {
            case .anilist:
                guard let token = LegacyAniListTracker.accessToken(fromRedirect: url) else {
                    return false
                }
                didCapture = true
                anilist.setAccessToken(token)
                finish(success: true)
                return true
            case .myanimelist:
                guard let code = LegacyMyAnimeListTracker.authorizationCode(fromRedirect: url) else {
                    return false
                }
                didCapture = true
                myanimelist.exchangeCode(code) { [weak self] result in
                    DispatchQueue.main.async {
                        switch result {
                            case .success:
                                self?.finish(success: true)
                            case .failure(let error):
                                self?.presentExchangeFailure(error)
                        }
                    }
                }
                return true
        }
    }

    private func presentExchangeFailure(_ error: Error) {
        let alert = UIAlertController(
            title: LegacyString("tracker.login.failed.title"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: LegacyString("button.ok"), style: .default) { [weak self] _ in
            self?.finish(success: false)
        })
        present(alert, animated: true)
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
