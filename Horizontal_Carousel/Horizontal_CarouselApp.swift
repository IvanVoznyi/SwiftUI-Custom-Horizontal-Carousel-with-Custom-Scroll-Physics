//
//  Horizontal_CarouselApp.swift
//  Horizontal_Carousel
//
//  Created by Ivan Voznyi on 3/3/26.
//

import SwiftUI

@main
struct Horizontal_CarouselApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(totalItemCount: 100_000, startIndex: 0) { index in
                CardView(index: index)
            }
        }
    }
}
