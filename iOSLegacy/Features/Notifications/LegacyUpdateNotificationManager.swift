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
    func notifyNewChapters(mangaTitle: String, newChapterCount: Int) {
        guard isEnabled else { return }
        guard newChapterCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = mangaTitle
        if newChapterCount == 1 {
            content.body = "1 new chapter available"
        } else {
            content.body = "\(newChapterCount) new chapters available"
        }
        content.sound = .default

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
        content.title = "Library Updated"

        let chapterText: String
        if totalNewChapters == 1 {
            chapterText = "1 new chapter"
        } else {
            chapterText = "\(totalNewChapters) new chapters"
        }
        let titleText: String
        if updatedMangaCount == 1 {
            titleText = "1 title"
        } else {
            titleText = "\(updatedMangaCount) titles"
        }
        content.body = "\(chapterText) across \(titleText)"
        content.sound = .default

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
