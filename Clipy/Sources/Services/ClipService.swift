//
//  ClipService.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/11/17.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Foundation
import Cocoa
import RealmSwift
import PINCache
import RxSwift
import RxCocoa
import RxOptional

final class ClipService {

    // MARK: - Properties
    fileprivate var cachedChangeCount = BehaviorRelay<Int>(value: 0)
    fileprivate var storeTypes = [String: NSNumber]()
    fileprivate let scheduler = SerialDispatchQueueScheduler(qos: .userInteractive)
    fileprivate var disposeBag = DisposeBag()

    // MARK: - Clips
    func startMonitoring() {
        disposeBag = DisposeBag()
        // Pasteboard observe timer
        // macOS は NSPasteboard 用の push 通知を提供しないためポーリングが必要。
        // 200ms (5Hz) は常時アイドル CPU/電池を浪費する一方、500ms に伸ばしても
        // 体感のレスポンスはほぼ変わらない。コピー直後にメニューを開く操作にも十分間に合う。
        Observable<Int>
            .interval(.milliseconds(500), scheduler: scheduler)
            .map { _ in NSPasteboard.general.changeCount }
            .withLatestFrom(cachedChangeCount.asObservable()) { ($0, $1) }
            .filter { $0 != $1 }
            .subscribe(onNext: { [weak self] changeCount, _ in
                self?.cachedChangeCount.accept(changeCount)
                self?.create()
            })
            .disposed(by: disposeBag)
        // Store types
        AppEnvironment.current.defaults.rx
            .observe([String: NSNumber].self, Constants.UserDefaults.storeTypes)
            .filterNil()
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] in
                self?.storeTypes = $0
            })
            .disposed(by: disposeBag)
    }

    func clearAll() {
        let realm = try! Realm()
        let clips = realm.objects(CPYClip.self)

        // Delete saved images
        clips
            .filter { !$0.thumbnailPath.isEmpty }
            .map { $0.thumbnailPath }
            .forEach { PINCache.shared.removeObject(forKey: $0) }
        // Delete Realm
        realm.transaction { realm.delete(clips) }
        // Delete writed datas
        AppEnvironment.current.dataCleanService.cleanDatas()
    }

    func delete(with clip: CPYClip) {
        let realm = try! Realm()
        // Delete saved images
        let path = clip.thumbnailPath
        if !path.isEmpty {
            PINCache.shared.removeObject(forKey: path)
        }
        // Delete Realm
        realm.transaction { realm.delete(clip) }
    }

    func incrementChangeCount() {
        cachedChangeCount.accept(cachedChangeCount.value + 1)
    }

}

// MARK: - Create Clip
extension ClipService {
    /// 取り込み画像の最長辺を抑える上限。これを超える場合、tiffRepresentation の中間
    /// ビットマップ (width × height × 4 byte) と保存 Data の両方が一気に膨らむため、
    /// 取り込み時にダウンサンプルする。普通の Web 画像 (~1920px) は影響なし。
    fileprivate static let maxImageLongerSide: CGFloat = 4096

    fileprivate func create() {
        // Store types
        if !storeTypes.values.contains(NSNumber(value: true)) { return }
        // Pasteboard types
        let pasteboard = NSPasteboard.general
        let types = self.types(with: pasteboard)
        if types.isEmpty { return }

        // Excluded application
        guard !AppEnvironment.current.excludeAppService.frontProcessIsExcludedApplication() else { return }
        // Special applications
        guard !AppEnvironment.current.excludeAppService.copiedProcessIsExcludedApplications(pasteboard: pasteboard) else { return }

        // 取り込みパス全体を autoreleasepool で囲み、巨大な中間 NSImage / Data を
        // ループ脱出時に確実に解放させる。これがないと malloc プールに残り続けて
        // Activity Monitor の RSS が下がらない。
        autoreleasepool {
            // 画像が含まれる場合、Pasteboard から NSImage を 1 度だけ作って下流で使い回す。
            // 過剰解像度はここでダウンサンプルしてから後段に渡す。
            var preloadedImage: NSImage? = nil
            if types.contains(.png) || types.contains(.tiff) {
                if let raw = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
                    preloadedImage = raw.downscaledIfNeeded(maxLongerSide: Self.maxImageLongerSide)
                }
            }

            let data = CPYClipData(pasteboard: pasteboard, types: types, preloadedImage: preloadedImage)
            save(with: data, preloadedImage: preloadedImage)
        }
    }

    func create(with title: String, image: NSImage) {
        // Create only image data
        let downsampled = image.downscaledIfNeeded(maxLongerSide: Self.maxImageLongerSide)
        let data = CPYClipData(title: title, image: downsampled)
        save(with: data, preloadedImage: downsampled)
    }

    fileprivate func save(with data: CPYClipData, preloadedImage: NSImage? = nil) {
        // Don't save empty string history
        if !data.isValid { return }

        DispatchQueue.global(qos: .userInteractive).async {
            autoreleasepool {
                // Saved time and path
                let unixTime = Int(Date().timeIntervalSince1970)
                let savedPath = CPYUtilities.applicationSupportFolder() + "/\(NSUUID().uuidString).data"
                // Create Realm object
                let clip = CPYClip()
                clip.dataHash = data.identifier
                clip.dataPath = savedPath
                clip.title = data.stringValue?[0...10000] ?? ""
                clip.updateTime = unixTime
                clip.primaryType = data.primaryType?.rawValue ?? ""

                // Save thumbnail image
                // preloadedImage があれば直接 cropToSquare し、CPYClipData.thumbnailImage 経由
                // (Image.image getter が encode 済み Data を再 decode する) のフル解像度 CGImage
                // 再展開を避ける。これだけで 1 画像あたり 30〜40 MB のピーク削減になる。
                let thumbnailLength = AppEnvironment.current.defaults.integer(forKey: Preferences.Menu.thumbnailLength)
                let thumbnailImage: NSImage? = {
                    if let preloaded = preloadedImage {
                        return preloaded.cropToSquare(with: CGFloat(thumbnailLength), and: .center)
                    }
                    return data.thumbnailImage
                }()

                if let thumbnailImage = thumbnailImage {
                    let cost = UInt(thumbnailImage.size.width * thumbnailImage.size.height * 4)
                    PINCache.shared.setObjectAsync(thumbnailImage, forKey: "\(unixTime)", withCost: cost, completion: nil)
                    clip.thumbnailPath = "\(unixTime)"
                } else if let colorCodeImage = data.colorCodeImage {
                    let cost = UInt(colorCodeImage.size.width * colorCodeImage.size.height * 4)
                    PINCache.shared.setObjectAsync(colorCodeImage, forKey: "\(unixTime)", withCost: cost, completion: nil)
                    clip.thumbnailPath = "\(unixTime)"
                    clip.isColorCode = true
                }

                if CPYUtilities.prepareSaveToPath(CPYUtilities.applicationSupportFolder()) {
                    try? JSONEncoder().encode(data).write(to: .init(fileURLWithPath: savedPath))

                    DispatchQueue.main.async {
                        // Save Realm and .data file
                        let dispatchRealm = try! Realm()
                        // Clean up the prior on-disk payload when this dataHash already exists,
                        // so the Realm record always points at a fresh, valid file.
                        let stalePath = dispatchRealm
                            .object(ofType: CPYClip.self, forPrimaryKey: clip.dataHash)?
                            .dataPath
                        dispatchRealm.transaction {
                            dispatchRealm.add(clip, update: .all)
                        }
                        if let stalePath = stalePath, stalePath != savedPath {
                            try? FileManager.default.removeItem(atPath: stalePath)
                        }
                    }
                }
            }
        }
    }

    private func types(with pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let types = pasteboard.types?.filter { canSave(with: $0) } ?? []
        var deduped = NSOrderedSet(array: types).array as? [NSPasteboard.PasteboardType] ?? []
        // PNG と TIFF は同一画像の二重表現で、Pasteboard に大半の画像で両方が入る。
        // 双方を取り込むと Pasteboard から NSImage を 2 回作り、tiffRepresentation を
        // 2 回呼ぶため、巨大画像で中間ビットマップ (width × height × 4 byte) が二重に展開される。
        // PNG はロスレス・サイズ小・互換性高なので PNG 側を残し TIFF をスキップする。
        if deduped.contains(.png), let tiffIdx = deduped.firstIndex(of: .tiff) {
            deduped.remove(at: tiffIdx)
        }
        return deduped
    }

    private func canSave(with type: NSPasteboard.PasteboardType) -> Bool {
        let dictionary = CPYClipData.availableTypesDictionary
        guard let value = dictionary[type] else { return false }
        guard let number = storeTypes[value] else { return false }
        return number.boolValue
    }
}
