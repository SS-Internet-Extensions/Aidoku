//
//  LegacyUpdateNotificationManager.swift
//  AidokuLegacy (iOS 12)
//
//  User-facing local notifications for library updates. Callback-based, no Combine.
//  Wraps UNUserNotificationCenter (iOS 10+) so callers never touch it directly and
//  so a missing/denied authorization can never crash the legacy UIKit target.
//

import Foundation
import UserNotifications

/// Manages local update notifications for the legacy UIKit target.
///
/// All notification center work is guarded so it is safe to call even when the
/// user has never granted (or has revoked) notification authorization.
final class LegacyUpdateNotificationManager {
    static let shared = LegacyUpdateNotificationManager()

    /// UserDefaults key backing `isEnabled`.
    static let enabledDefaultsKey = "AidokuLegacy.notifications.libraryUpdates"
    static let categoryLibrarySummary = "AidokuLegacyNotificationLibrarySummary"
    static let categoryTitleUpdate = "AidokuLegacyNotificationTitleUpdate"
    static let actionOpenUpdates = "AidokuLegacyNotificationOpenUpdates"
    static let actionOpenTitle = "AidokuLegacyNotificationOpenTitle"
    static let actionMarkTitleRead = "AidokuLegacyNotificationMarkTitleRead"
    static let userInfoSourceKey = "sourceKey"
    static let userInfoMangaKey = "mangaKey"
    static let userInfoMangaTitle = "mangaTitle"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Preference

    /// Whether the user has opted in to library update notifications.
    ///
    /// Defaults to `false`. Persisted under `enabledDefaultsKey`.
    var isEnabled: Bool {
        get {
            return defaults.bool(forKey: LegacyUpdateNotificationManager.enabledDefaultsKey)
        }
        set {
            defaults.set(newValue, forKey: LegacyUpdateNotificationManager.enabledDefaultsKey)
        }
    }

    // MARK: - Authorization

    func configureNotificationCenter(delegate: UNUserNotificationCenterDelegate?) {
        let openUpdates = UNNotificationAction(
            identifier: Self.actionOpenUpdates,
            title: LegacyString("notification.action.open_updates"),
            options: [.foreground]
        )
        let openTitle = UNNotificationAction(
            identifier: Self.actionOpenTitle,
            title: LegacyString("notification.action.open_title"),
            options: [.foreground]
        )
        let markTitleRead = UNNotificationAction(
            identifier: Self.actionMarkTitleRead,
            title: LegacyString("notification.action.mark_read"),
            options: []
        )
        let summaryCategory = UNNotificationCategory(
            identifier: Self.categoryLibrarySummary,
            actions: [openUpdates],
            intentIdentifiers: [],
            options: []
        )
        let titleCategory = UNNotificationCategory(
            identifier: Self.categoryTitleUpdate,
            actions: [openTitle, openUpdates, markTitleRead],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([summaryCategory, titleCategory])
        center.delegate = delegate
    }

    /// Requests notification authorization from the system.
    ///
    /// Asks for alert, sound, and badge permissions. The completion is always
    /// dispatched on the main queue with the granted flag. When granted,
    /// `isEnabled` is set to `true` so a Settings toggle can flip on immediately.
    ///
    /// - Parameter completion: Called on the main queue with whether access was granted.
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { [weak self] granted, _ in
            DispatchQueue.main.async {
                if granted {
                    self?.isEnabled = true
                }
                completion?(granted)
            }
        }
    }

    /// Reports whether the system currently authorizes notifications.
    ///
    /// - Parameter completion: Called on the main queue with `true` when the
    ///   authorization status is `.authorized`.
    func authorizationStatus(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized
            DispatchQueue.main.async {
                completion(authorized)
            }
        }
    }

    // MARK: - Notifications

    /// Posts a notification announcing new chapters for a single manga.
    ///
    /// No-op when the user has not opted in or when `newChapterCount <= 0`.
    ///
    /// - Parameters:
    ///   - mangaTitle: The manga title, used as the notification title.
    ///   - newChapterCount: The number of newly found chapters.
    func notifyNewChapters(
        mangaTitle: String,
        sourceKey: String,
        mangaKey: String,
        newChapterCount: Int
    ) {
        guard isEnabled else { return }
        guard newChapterCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = mangaTitle
        if newChapterCount == 1 {
            content.body = LegacyString("notification.title_update.one")
        } else {
            content.body = String(format: LegacyString("notification.title_update.many"), newChapterCount)
        }
        content.sound = .default
        content.categoryIdentifier = Self.categoryTitleUpdate
        content.threadIdentifier = "AidokuLegacyLibraryUpdates"
        content.userInfo = [
            Self.userInfoSourceKey: sourceKey,
            Self.userInfoMangaKey: mangaKey,
            Self.userInfoMangaTitle: mangaTitle
        ]

        add(content: content)
    }

    /// Posts a summary notification after a library update check finishes.
    ///
    /// No-op when the user has not opted in or when `totalNewChapters <= 0`.
    ///
    /// - Parameters:
    ///   - updatedMangaCount: The number of titles that gained new chapters.
    ///   - totalNewChapters: The total number of new chapters across all titles.
    func notifyLibraryUpdateSummary(updatedMangaCount: Int, totalNewChapters: Int) {
        guard isEnabled else { return }
        guard totalNewChapters > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = LegacyString("library.updated.title")

        let chapterText: String
        if totalNewChapters == 1 {
            chapterText = LegacyString("notification.summary.chapter.one")
        } else {
            chapterText = String(format: LegacyString("notification.summary.chapter.many"), totalNewChapters)
        }
        let titleText: String
        if updatedMangaCount == 1 {
            titleText = LegacyString("notification.summary.title.one")
        } else {
            titleText = String(format: LegacyString("notification.summary.title.many"), updatedMangaCount)
        }
        content.body = String(format: LegacyString("notification.summary.body"), chapterText, titleText)
        content.sound = .default
        content.categoryIdentifier = Self.categoryLibrarySummary
        content.threadIdentifier = "AidokuLegacyLibraryUpdates"

        add(content: content)
    }

    // MARK: - Helpers

    /// Schedules an immediate (trigger-less) notification with a unique identifier.
    ///
    /// Failures are swallowed: a denied or missing authorization must never crash
    /// the legacy target.
    private func add(content: UNNotificationContent) {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
