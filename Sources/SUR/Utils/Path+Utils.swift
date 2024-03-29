//
//  Path+Utils.swift
//  
//
//  Created by Alexander Chernousov on 16.12.2023.
//

import Foundation
import PathKit

extension Path {
    var size: Int {
        if isDirectory {
            let childrenPaths = try? children()
            return (childrenPaths ?? []).reduce(0) { $0 + $1.size }
        }
        else {
            // Skip hidden files
            if lastComponent.hasPrefix(".") { return 0 }
            let attr = try? FileManager.default.attributesOfItem(atPath: absolute().string)
            if let num = attr?[.size] as? NSNumber {
                return num.intValue
            }
            else {
                return 0
            }
        }
    }
}
