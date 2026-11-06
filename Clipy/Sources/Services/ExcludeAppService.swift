//
//  ExcludeAppService.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2017/02/10.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Foundation
import RxSwift
import RxCocoa

final class ExcludeAppService {

    // MARK: - Properties
    // Changed from Preferences on the main thread and read by the pasteboard polling thread.
    private let applicationsLock = NSLock()
    private var storedApplications: [CPYAppInfo]
    fileprivate(set) var applications: [CPYAppInfo] {
        get {
            applicationsLock.lock(); defer { applicationsLock.unlock() }
            return storedApplications
        }
        set {
            applicationsLock.lock(); defer { applicationsLock.unlock() }
            storedApplications = newValue
        }
    }
    fileprivate var frontApplication = BehaviorRelay<NSRunningApplication?>(value: nil)
    fileprivate var disposeBag = DisposeBag()

    // MARK: - Initialize
    init(applications: [CPYAppInfo]) {
        self.storedApplications = applications
    }

}

// MARK: - Monitor Applications
extension ExcludeAppService {
    func startMonitoring() {
        disposeBag = DisposeBag()
        // The notification only fires on the next switch, so seed the current app here.
        frontApplication.accept(NSWorkspace.shared.frontmostApplication)
        // Monitoring top active application
        NSWorkspace.shared.notificationCenter.rx.notification(NSWorkspace.didActivateApplicationNotification)
            .map { $0.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication }
            .bind(to: frontApplication)
            .disposed(by: disposeBag)
    }
}

// MARK: - Exclude
extension ExcludeAppService {
    /// Apple's password apps don't mark copied secrets as concealed, so they are always excluded.
    private static let alwaysExcludedIdentifiers: Set<String> = ["com.apple.Passwords",
                                                                 "com.apple.Passwords.MenuBarExtra",
                                                                 "com.apple.keychainaccess"]

    func frontProcessIsExcludedApplication() -> Bool {
        guard let frontApplicationIdentifier = frontApplication.value?.bundleIdentifier else { return false }
        if Self.alwaysExcludedIdentifiers.contains(frontApplicationIdentifier) { return true }

        for app in applications where app.identifier == frontApplicationIdentifier {
            return true
        }
        return false
    }
}

// MARK: - Add or Delete
extension ExcludeAppService {
    func add(with appInfo: CPYAppInfo) {
        if applications.contains(appInfo) { return }
        applications.append(appInfo)
        save()
    }

    func delete(with appInfo: CPYAppInfo) {
        applications = applications.filter { $0 != appInfo }
        save()
    }

    func delete(with index: Int) {
        delete(with: applications[index])
    }

    private func save() {
        let data = applications.archive()
        AppEnvironment.current.defaults.set(data, forKey: Constants.UserDefaults.excludeApplications)
        AppEnvironment.current.defaults.synchronize()
    }
}

// MARK: - Special Applications
extension ExcludeAppService {
    /**
     *  Responding to applications that have special handling for protection of passwords etc.
     *  e.g 1Password on GoogleChrome browser extension
     *
     *  ref: http://nspasteboard.org/
     */
    private enum Application: String {
        case onePassword = "com.agilebits.onepassword"

        // MARK: - Properties
        private var macApplicationIdentifiers: [String] {
            switch self {
            case .onePassword:
                return ["com.agilebits.onepassword-osx", // for 1Password 6
                        "com.agilebits.onepassword7", // for 1Password 7
                        "com.1password.1password"] // for 1Password 8
            }
        }

        // MARK: - Excluded
        func isExcluded(applications: [CPYAppInfo]) -> Bool {
            return !applications.filter { macApplicationIdentifiers.contains($0.identifier) }.isEmpty
        }

    }

    /// Markers from http://nspasteboard.org/ asking clipboard managers not to record the content.
    private static let doNotRecordTypes: Set<String> = ["org.nspasteboard.ConcealedType",
                                                        "org.nspasteboard.TransientType"]

    func pasteboardRequestsNoRecording(_ pasteboard: NSPasteboard) -> Bool {
        return pasteboard.types?.contains { Self.doNotRecordTypes.contains($0.rawValue) } ?? false
    }

    func copiedProcessIsExcludedApplications(pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        guard let application = types.compactMap({ Application(rawValue: $0.rawValue) }).first else { return false }
        return application.isExcluded(applications: applications)
    }
}
