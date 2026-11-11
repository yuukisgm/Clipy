//
//  Array+Remove.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/07/06.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Foundation

extension Array {
    mutating func removeObject<T: Equatable>(_ element: T) {
        self = filter { $0 as? T != element }
    }
}
