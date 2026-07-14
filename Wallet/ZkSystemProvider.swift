/*
 * ZkSystemProvider — builds the ZK system repository the wallet uses to produce
 * zero-knowledge proofs during presentation.
 *
 * This lives in the app layer because it links the LongfellowZkp package (and its
 * internal MdocZK binary target). logic-core stays free of that dependency and
 * only receives the built `ZkSystemRepository` via `WalletKitController`.
 *
 * The circuit is derived from the native spec (single source of truth), so it
 * always matches what the native prover/verifier expects. Generation is heavy
 * (~10s, peaks ~99 MB) but the compressed result is ~300 KB, so we generate once
 * and disk-cache it, reusing it on every later launch.
 */
import Foundation
import LongfellowZkp
import MdocDataModel18013

enum ZkSystemProvider {

  /// Builds a repository containing the Longfellow v7 ZK system. Heavy on first
  /// call (circuit generation); cheap afterwards (loads the cached circuit).
  /// Call off the main thread.
  static func makeRepository() -> ZkSystemRepository? {
    let tag = "🔐 [ZkSystemProvider]"
    let nativeSpec = LongfellowNatives.getLongfellowZkSystemSpec(numAttributes: 1)

    // Read spec fields via the type's Codable JSON (stored properties are internal).
    guard
      let data = try? JSONEncoder().encode(nativeSpec),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = dict["version"] as? Int,
      let numAttr = dict["num_attributes"] as? Int,
      let blockEncHash = dict["block_enc_hash"] as? Int,
      let blockEncSig = dict["block_enc_sig"] as? Int,
      let circuitHash = dict["circuit_hash"] as? String
    else {
      print("\(tag) ❌ could not read native ZK spec")
      return nil
    }

    // Circuit filename convention: <version>_<numAttr>_<blockEncHash>_<blockEncSig>_<hash>
    let filename = "\(version)_\(numAttr)_\(blockEncHash)_\(blockEncSig)_\(circuitHash)"
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let cacheURL = caches.appendingPathComponent("zk-circuit-\(filename)")

    let circuitData: Data
    if let cached = try? Data(contentsOf: cacheURL) {
      circuitData = cached
    } else {
      circuitData = LongfellowNatives.generateCircuit(jzkSpec: nativeSpec)
      try? circuitData.write(to: cacheURL)
    }

    guard let entry = try? CircuitEntry(circuitFilename: filename, circuitData: circuitData) else {
      print("\(tag) ❌ CircuitEntry construction failed")
      return nil
    }

    print("\(tag) ✅ Longfellow ZK system ready — \(filename) (\(circuitData.count) bytes)")
    return ZkSystemRepository(systems: [LongfellowZkSystem(circuits: [entry])])
  }
}
