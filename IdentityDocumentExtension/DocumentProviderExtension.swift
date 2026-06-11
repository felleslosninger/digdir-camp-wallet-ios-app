//
//  DocumentProviderExtension.swift
//  IdentityDocumentExtension
//
//  Created by Dusan Nikolic on 11/06/2026.
//

import ExtensionKit
import IdentityDocumentServicesUI
import SwiftUI

@main
struct DocumentProviderExtension: IdentityDocumentProvider {

    var body: some IdentityDocumentRequestScene {
        ISO18013MobileDocumentRequestScene { context in
            // Insert your view here
            Text("Hello, world!")
        }
    }

    func performRegistrationUpdates() async {
        
    }

}
