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
                SQLiteClipStore.shared.purgeSessionCaches()
            })
            .disposed(by: disposeBag)
    }

    func clearAll() {
        SQLiteClipStore.shared.deleteAllClips()
        AppEnvironment.current.dataCleanService.cleanDatas()
    }

    func delete(with clip: CPYClip) {
        SQLiteClipStore.shared.deleteClip(clip)
    }

    func reorderAfterPasting(_ clip: CPYClip) {
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.General.reorderClipsAfterPasting) else { return }
        SQLiteClipStore.shared.touchClip(clip)
    }

    func incrementChangeCount() {
        cachedChangeCount.accept(cachedChangeCount.value + 1)
    }

    func ignoreCurrentPasteboardChange() {
        cachedChangeCount.accept(NSPasteboard.general.changeCount)
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
                let savedPath = CPYUtilities.sqliteStorageFolder() + "/\(NSUUID().uuidString).data"
                let clip = CPYClip()
                clip.dataHash = data.identifier
                clip.dataPath = savedPath
                clip.title = data.clipTitle?[0...10000] ?? ""
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

                guard CPYUtilities.prepareSaveToPath(CPYUtilities.sqliteStorageFolder()) else { return }
                do {
                    try JSONEncoder().encode(data).write(to: .init(fileURLWithPath: savedPath), options: .atomic)
                    SQLiteClipStore.shared.saveClip(clip)
                } catch {
                    lError(error)
                    try? FileManager.default.removeItem(atPath: savedPath)
                }
            }
        }
    }

    private func types(with pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let policy = PasteboardTypePolicy(storeTypes: storeTypes)
        if policy.storesPlainTextOnly {
            return pasteboard.string(forType: .string)?.trim.isNotEmpty == true ? [.string] : []
        }

        let types = pasteboard.types?.filter { policy.canSave($0) } ?? []
        var deduped = NSOrderedSet(array: types).array as? [NSPasteboard.PasteboardType] ?? []
        // PNG と TIFF は同一画像の二重表現で、Pasteboard に大半の画像で両方が入る。
        // 双方を取り込むと Pasteboard から NSImage を 2 回作り、tiffRepresentation を
        // 2 回呼ぶため、巨大画像で中間ビットマップ (width × height × 4 byte) が二重に展開される。
        // PNG はロスレス・サイズ小・互換性高なので PNG 側を残し TIFF をスキップする。
        if deduped.contains(.png), let tiffIdx = deduped.firstIndex(of: .tiff) {
            deduped.remove(at: tiffIdx)
        }
        if policy.canSaveSupplementalTypes {
            deduped.append(contentsOf: policy.supplementalTypes(from: pasteboard, excluding: deduped))
        }
        return deduped
    }
}

private struct PasteboardTypePolicy {
    private let storeTypes: [String: NSNumber]

    init(storeTypes: [String: NSNumber]) {
        self.storeTypes = storeTypes
    }

    var storesPlainTextOnly: Bool {
        storeTypes[StoreType.string.rawValue]?.boolValue == true &&
            !storeTypes.contains { key, value in
                key != StoreType.string.rawValue && !Self.ignoredLegacyStoreTypes.contains(key) && value.boolValue
            }
    }

    var canSaveSupplementalTypes: Bool {
        Self.supplementalStoreTypes.contains {
            storeTypes[$0.rawValue]?.boolValue == true
        }
    }

    func canSave(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == .png {
            return storeTypes[StoreType.image.rawValue]?.boolValue == true
        }
        let dictionary = CPYClipData.availableTypesDictionary
        guard let value = dictionary[type] else { return false }
        guard let number = storeTypes[value] else { return false }
        return number.boolValue
    }

    func supplementalTypes(from pasteboard: NSPasteboard,
                           excluding savedTypes: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        guard !savedTypes.isEmpty else { return [] }
        let candidates = pasteboard.types?.filter {
            !CPYClipData.availableTypes.contains($0) && !savedTypes.contains($0) && shouldPreserveSupplementalType($0)
        } ?? []
        return candidates.filter { type in
            if let data = pasteboard.data(forType: type) {
                return data.count <= Self.maxSupplementalPasteboardDataSize
            }
            return pasteboard.string(forType: type)?.isNotEmpty == true
        }
    }

    private func shouldPreserveSupplementalType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let value = type.rawValue.lowercased()
        return Self.supplementalPasteboardTypes.contains(type)
            || value.contains("microsoft")
            || value.contains("office")
            || value.contains("excel")
            || value.contains("word")
            || value.contains("biff")
            || value.contains("sylk")
            || value.contains("spreadsheet")
            || value.contains("worksheet")
            || value.contains("tabular")
            || value.contains("tab-separated")
            || value.contains("csv")
    }

    private static let maxSupplementalPasteboardDataSize = 8 * 1024 * 1024
    private static let ignoredLegacyStoreTypes: Set<String> = ["PNG"]
    private static let supplementalStoreTypes: Set<StoreType> = [
        .rtf,
        .rtfd,
        .pdf,
        .image
    ]

    private static let supplementalPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType(rawValue: "public.html"),
        NSPasteboard.PasteboardType(rawValue: "HTML Format"),
        NSPasteboard.PasteboardType(rawValue: "NSStringPboardType"),
        NSPasteboard.PasteboardType(rawValue: "NeXT plain ascii pasteboard type"),
        NSPasteboard.PasteboardType(rawValue: "NSTabularTextPboardType"),
        NSPasteboard.PasteboardType(rawValue: "public.utf8-tab-separated-values-text"),
        NSPasteboard.PasteboardType(rawValue: "public.tab-separated-values-text"),
        NSPasteboard.PasteboardType(rawValue: "public.comma-separated-values-text"),
        NSPasteboard.PasteboardType(rawValue: "com.microsoft.excel.xls"),
        NSPasteboard.PasteboardType(rawValue: "com.microsoft.Excel.xls"),
        NSPasteboard.PasteboardType(rawValue: "com.microsoft.Excel.Binary"),
        NSPasteboard.PasteboardType(rawValue: "Biff8"),
        NSPasteboard.PasteboardType(rawValue: "Biff5"),
        NSPasteboard.PasteboardType(rawValue: "Biff4"),
        NSPasteboard.PasteboardType(rawValue: "Biff3"),
        NSPasteboard.PasteboardType(rawValue: "BIFF8"),
        NSPasteboard.PasteboardType(rawValue: "BIFF5")
    ]

    private enum StoreType: String {
        case string = "String"
        case rtf = "RTF"
        case rtfd = "RTFD"
        case pdf = "PDF"
        case image = "TIFF"
    }
}
