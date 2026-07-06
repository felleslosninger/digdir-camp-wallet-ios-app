//import Foundation
import EudiWalletKit
import LongfellowZkp
import MdocDataModel18013

enum LongfellowProver {

  static func setup(wallet: EudiWallet) {
    let circuits = LongfellowZkSystem.enumerateLongfellowCircuits(bundle: .main)
    guard !circuits.isEmpty else { return }
    wallet.zkSystemRepository = ZkSystemRepository(
      systems: [LongfellowZkSystem(circuits: circuits)]
    )
  }
}
//  LongFellowProver.swift
//  logic-core
//
//  Created by Peter Storegjerde Sætre on 02/07/2026.
//

