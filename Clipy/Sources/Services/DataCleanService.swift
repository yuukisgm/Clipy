//
//  DataCleanService.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/11/20.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Foundation
import RxSwift
import PINCache

final class DataCleanService {

    // MARK: - Properties
    fileprivate var disposeBag = DisposeBag()
    fileprivate let scheduler = SerialDispatchQueueScheduler(qos: .utility)
    // A new clip's file exists shortly before its database row, so recent files aren't orphans yet.
    private static let orphanGracePeriod: TimeInterval = 5 * 60

    // MARK: - Monitoring
    func startMonitoring() {
        disposeBag = DisposeBag()
        // Clean datas every 30 minutes
        Observable<Int>
            .interval(.seconds(60 * 30), scheduler: scheduler)
            .subscribe(onNext: { [weak self] _ in
                self?.cleanDatas()
            })
            .disposed(by: disposeBag)
    }

    // MARK: - Delete Data
    func cleanDatas() {
        let maxHistorySize = AppEnvironment.current.defaults.integer(forKey: Preferences.General.maxHistorySize)
        SQLiteClipStore.shared.deleteOverflowingClips(maxHistorySize: maxHistorySize)
        cleanFiles()
    }

    private func cleanFiles() {
        let fileManager = FileManager.default
        let storageFolder = CPYUtilities.sqliteStorageFolder()
        guard let paths = try? fileManager.contentsOfDirectory(atPath: storageFolder) else { return }

        // DB を読めないときは「履歴ゼロ」と区別できないので、何も消さない。
        guard let allClipPaths = SQLiteClipStore.shared.clipPayloadPaths() else { return }

        // Delete diff datas
        Set(paths)
            .subtracting(allClipPaths)
            .map { storageFolder + "/" + "\($0)" }
            .filter { path in
                let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                return Date().timeIntervalSince(modified ?? .distantPast) > Self.orphanGracePeriod
            }
            .forEach { CPYUtilities.deleteData(at: $0) }
    }
}
