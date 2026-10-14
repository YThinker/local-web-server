//
//  Item.swift
//  LocalWebServer
//
//  Created by 杨星恺 on 2026/10/14.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
