//
//  VelocityApp.swift
//  Velocity
//
//  Created by Avinash Dola on 03/09/25.
//

import SwiftUI

@main
struct VelocityApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
