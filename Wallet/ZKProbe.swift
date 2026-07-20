/*
 * ZKProbe — Stage 0 isolation probe for Longfellow ZKP linking.
 *
 * Purpose: answer two questions ONLY, with no prove/verify logic:
 *   (a) Does the LongfellowZkp product (and its internal MdocZK xcframework) link?
 *   (b) What does getLongfellowZkSystemSpec(numAttributes: 1) actually return on v0.14.0?
 *
 * Import the PUBLIC product `LongfellowZkp` — never `import MdocZK` (that is an
 * internal binaryTarget and is not a product, so it cannot be imported by consumers).
 *
 * Must run on an iOS target (simulator or device). The MdocZK.xcframework ships only
 * ios-arm64 and ios-arm64_x86_64-simulator slices — there is NO macOS slice, so a
 * command-line `swift test` (which builds for macOS) can never link it.
 */
#if DEBUG
import Foundation
import LongfellowZkp
import MdocDataModel18013
import MdocDataTransfer18013
import MdocSecurity18013
import SwiftCBOR
import EudiWalletKit
import WalletStorage
import logic_core
import logic_assembly

enum ZKProbe {

  /// Logs the full Zk system spec for numAttributes = 1. Safe to call at launch.
  static func run() {
    let tag = "🧪 [ZKProbe]"
    print("\(tag) MdocZK linked, LongfellowZkp import OK — calling getLongfellowZkSystemSpec(numAttributes: 1)")

    let spec = LongfellowNatives.getLongfellowZkSystemSpec(numAttributes: 1)

    // The struct's stored properties are `internal`, but the type is Codable and its
    // CodingKeys emit the canonical DCQL field names (circuit_hash, num_attributes, …).
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(spec), let json = String(data: data, encoding: .utf8) {
      print("\(tag) spec (JSON):\n\(json)")
    } else {
      print("\(tag) WARNING: spec did not encode to JSON")
    }

    // Cross-check via the public toZkParams() accessor (independent of Codable).
    print("\(tag) toZkParams(): \(spec.toZkParams())")

    runProveP1()
  }

  /// P1: derive the circuit DIRECTLY from the native spec (single source of truth),
  /// so the circuit always matches what the native prover/verifier expects.
  ///
  /// NOTE: v0.14.0's native library reports circuit **version 7** (hash 8d079211…,
  /// block_enc 4151/4096), while the package's own Tests/Circuits folder ships an
  /// older **v6** file (137e5a75…, 4096/2945). Bundling the v6 file would make the
  /// native prover reject it ("invalid payload size"). We therefore ignore the
  /// bundled file and generate the matching circuit at runtime.
  static func runProveP1() {
    let tag = "🧪 [ZKProbe P1]"

    // Log what the (misaligned) bundled circuit is, for the record.
    let bundled = LongfellowZkSystem.enumerateLongfellowCircuits(bundle: .main)
    print("\(tag) bundled circuits (ignored): \(bundled.map { $0.circuitFilename })")

    // Circuit generation is heavy — run off the main thread.
    Task.detached(priority: .userInitiated) {
      let nativeSpec = LongfellowNatives.getLongfellowZkSystemSpec(numAttributes: 1)

      // Read spec fields via its Codable JSON (stored properties are internal).
      guard
        let data = try? JSONEncoder().encode(nativeSpec),
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let version = dict["version"] as? Int,
        let numAttr = dict["num_attributes"] as? Int,
        let blockEncHash = dict["block_enc_hash"] as? Int,
        let blockEncSig = dict["block_enc_sig"] as? Int,
        let circuitHash = dict["circuit_hash"] as? String
      else {
        print("\(tag) ❌ could not read native spec fields")
        return
      }

      // Circuit filename convention: <version>_<numAttr>_<blockEncHash>_<blockEncSig>_<hash>
      let filename = "\(version)_\(numAttr)_\(blockEncHash)_\(blockEncSig)_\(circuitHash)"
      print("\(tag) native spec → \(filename)")

      // Cache the generated circuit to disk: generation is ~11s and peaks ~99 MB,
      // but the compressed result is ~300 KB. Generate once, reuse thereafter.
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      let cacheURL = caches.appendingPathComponent("zk-circuit-\(filename)")
      let circuitData: Data
      if let cached = try? Data(contentsOf: cacheURL) {
        circuitData = cached
        print("\(tag) loaded cached circuit: \(circuitData.count) bytes (skipped generation)")
      } else {
        let started = ProcessInfo.processInfo.systemUptime
        circuitData = LongfellowNatives.generateCircuit(jzkSpec: nativeSpec)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try? circuitData.write(to: cacheURL)
        print("\(tag) generated circuit: \(circuitData.count) bytes in \(String(format: "%.2f", elapsed))s → cached")
      }

      guard let entry = try? CircuitEntry(circuitFilename: filename, circuitData: circuitData) else {
        print("\(tag) ❌ CircuitEntry construction failed")
        return
      }

      let system = LongfellowZkSystem(circuits: [entry])
      guard let match = system.getMatchingSystemSpec(zkSystemSpecs: system.systemSpecs, numAttributesRequested: Int64(numAttr)) else {
        print("\(tag) ❌ generated circuit did not match its own spec (unexpected)")
        return
      }
      print("\(tag) ✅ self-consistent v\(version) circuit ready — matching spec id=\(match.id)")

      // The decisive experiment: prove against the wallet's real issued mdoc.
      await proveWithIssuedMdoc(system: system, spec: match)

      // Del B — the real green path, driving the wallet's own signing machinery.
      await proveViaPresentation()
    }
  }

  /// The decisive experiment — locate the credential that actually carries
  /// `age_over_18` (the mDL, not the PID), prune it to that single attribute,
  /// and run the native prover.
  ///
  /// NOTE: this launch-time probe fabricates the holder `deviceSigned`, so it
  /// can only ever reach `MDOC_PROVER_DEVICE_SIGNATURE_FAILURE` (code 30) — a
  /// genuine device signature requires a real presentation. The probe's job is
  /// to confirm the credential + attribute are present and everything up to the
  /// device signature works; green PROVE comes from the presentation flow.
  static func proveWithIssuedMdoc(system: LongfellowZkSystem, spec: ZkSystemSpec) async {
    let tag = "🧪 [ZKProbe PROVE]"
    let controller = DIGraph.shared.resolver.force(WalletKitController.self)

    // Ground truth: enumerate ALL issued documents straight from storage, not
    // via docModels (which may not surface every credential). This tells us
    // whether the mDL is actually in this wallet instance.
    let rawDocs = ((try? await controller.wallet.loadDocuments(status: .issued)) ?? nil) ?? []
    print("\(tag) issued storage documents (\(rawDocs.count)):")
    for doc in rawDocs {
      print("\(tag)  • \(doc.docType)  [\(doc.docDataFormat)]  \(doc.data.count) bytes")
    }

    // Find the cbor mdoc that carries age_over_18, logging every element per doc.
    var target: (docType: String, ns: String, item: IssuerSignedItem, issuerSigned: IssuerSigned)?
    for doc in rawDocs where doc.docDataFormat == .cbor {
      guard let issuerSigned = try? IssuerSigned(data: doc.data.bytes) else {
        print("\(tag)  ⚠️ \(doc.docType): IssuerSigned did not decode")
        continue
      }
      for (ns, items) in issuerSigned.issuerNameSpaces?.nameSpaces ?? [:] {
        print("\(tag)   \(doc.docType)/\(ns): \(items.map { $0.elementIdentifier })")
        if target == nil, let hit = items.first(where: { $0.elementIdentifier == "age_over_18" }) {
          target = (doc.docType, ns, hit, issuerSigned)
        }
      }
    }

    guard let selected = target else {
      print("\(tag) ❌ no issued cbor mdoc carries `age_over_18` — the mDL is not in this wallet. Issue org.iso.18013.5.1.mDL first.")
      return
    }
    print("\(tag) ✅ found age_over_18 in \(selected.docType)/\(selected.ns) = \(selected.item.description)")

    do {
      // Prune to the single age_over_18 item; keep the original issuerAuth (MSO +
      // signature) so the item's digest still verifies. Attach a throwaway
      // deviceSigned (unsigned) purely so Document/DeviceResponse can encode.
      let prunedNameSpaces = IssuerNameSpaces(nameSpaces: [selected.ns: [selected.item]])
      let prunedIssuerSigned = IssuerSigned(issuerNameSpaces: prunedNameSpaces, issuerAuth: selected.issuerSigned.issuerAuth)

      let dummyCose = Cose(type: .sign1, algorithm: 6, payloadData: Data(), signature: Data(repeating: 0, count: 64))
      let deviceSigned = DeviceSigned(deviceAuth: DeviceAuth(coseMacOrSignature: dummyCose))
      let document = Document(docType: selected.docType, issuerSigned: prunedIssuerSigned, deviceSigned: deviceSigned)

      let (x, y) = try LongfellowZkSystem.getPublicKeyFromIssuerCert(document: document)
      print("\(tag) issuer pubkey extracted — x=\(x.prefix(12))… y=\(y.prefix(12))… (P-256 coords OK)")

      let started = ProcessInfo.processInfo.systemUptime
      let zkDoc = try system.generateProof(
        zkSystemSpec: spec,
        document: document,
        sessionTranscriptBytes: [],
        timestamp: Date()
      )
      let elapsed = ProcessInfo.processInfo.systemUptime - started
      print("\(tag) ✅ PROOF GENERATED — \(zkDoc.proof.count) bytes in \(String(format: "%.2f", elapsed))s")
    } catch {
      // Code 30 (DEVICE_SIGNATURE_FAILURE) is expected here — see method note.
      print("\(tag) ❌ prove failed: \(error)")
    }
  }

  /// Del B — the REAL green path. Drives the wallet's own presentation machinery
  /// (`getDeviceResponseToSend`), which signs `deviceAuth` with the credential's
  /// Secure-Enclave device key, and lets the already-wired ZK transform produce
  /// a genuine proof. No verifier required. May prompt biometrics to unlock the
  /// device key.
  static func proveViaPresentation() async {
    let tag = "🧪 [ZKProbe PRESENT]"
    let controller = DIGraph.shared.resolver.force(WalletKitController.self)

    // Ensure the ZK system is registered (idempotent) so the transfer params pick it up.
    if let repository = ZkSystemProvider.makeRepository() {
      controller.registerZkSystemRepository(repository)
    }

    do {
      let (params, _) = try await controller.wallet.prepareServiceDataParameters(format: .cbor)
      let info = try await params.toInitializeTransferInfo()
      guard let repository = info.zkSystemRepository else {
        print("\(tag) ❌ no zkSystemRepository in transfer info"); return
      }
      let zkSpecs = repository.getAllZkSystemSpecs()

      // Locate the mDL among the transfer documents (keyed by doc id).
      let mdlDocType = "org.iso.18013.5.1.mDL"
      guard let docId = info.idsToDocTypes.first(where: { $0.value == mdlDocType })?.key else {
        print("\(tag) ❌ mDL not in transfer set: \(info.idsToDocTypes)"); return
      }
      guard let raw = info.documentObjects[docId], let issuerSigned = try? IssuerSigned(data: raw.bytes) else {
        print("\(tag) ❌ could not load mDL IssuerSigned for docId \(docId)"); return
      }

      // Disclose only age_over_18 (num_attributes == 1).
      let selectedItems: RequestItems = [
        docId: ["org.iso.18013.5.1": [RequestItem(elementIdentifier: "age_over_18")]]
      ]

      // Unlock the Secure-Enclave device key (may prompt biometrics).
      var unlockData: [String: Data] = [:]
      if let key = info.privateKeyObjects[docId], let ud = try? await key.secureArea.unlockKey(id: docId) {
        unlockData[docId] = ud
      }

      // A minimal but structurally-valid transcript (no verifier handover for a self-test).
      let sessionTranscript = SessionTranscript(handOver: .null)

      let started = ProcessInfo.processInfo.systemUptime
      guard let resp = try await MdocHelpers.getDeviceResponseToSend(
        deviceRequest: nil,
        issuerSigned: [docId: issuerSigned],
        docMetadata: info.docMetadata,
        selectedItems: selectedItems,
        sessionEncryption: nil,
        eReaderKey: nil,
        privateKeyObjects: info.privateKeyObjects,
        sessionTranscript: sessionTranscript,
        dauthMethod: .deviceSignature,
        unlockData: unlockData,
        zkSpecsRequested: [mdlDocType: zkSpecs],
        zkSystemRepository: repository
      ) else {
        print("\(tag) ❌ getDeviceResponseToSend returned nil"); return
      }
      let elapsed = ProcessInfo.processInfo.systemUptime - started

      guard let zkDoc = resp.deviceResponse.zkDocuments?.first else {
        print("\(tag) ⚠️ no zkDocuments produced — documentIds=\(resp.documentIds), zkpDocIds=\(resp.zkpDocumentIds)")
        return
      }
      print("\(tag) ✅✅ REAL ZK PROOF via presentation — \(zkDoc.proof.count) bytes in \(String(format: "%.2f", elapsed))s (zkpDocIds=\(resp.zkpDocumentIds))")

      // Export exactly what Google's longfellow-zk verifier-service /zkverify expects:
      //   { "Transcript": <base64 transcript bytes>, "ZKDeviceResponseCBOR": <base64 DeviceResponse CBOR> }
      // Both are Go []byte fields (base64 in JSON). The transcript MUST be the identical
      // bytes the prover used — transformDeviceResponseWithZkp encodes it as
      // `sessionTranscript.encode(...)`, so we mirror that here.
      let transcriptBytes = Data(sessionTranscript.encode(options: CBOROptions()))
      let deviceResponseCBOR = Data(resp.deviceResponse.toCBOR(options: CBOROptions()).encode())
      let payload: [String: String] = [
        "Transcript": transcriptBytes.base64EncodedString(),
        "ZKDeviceResponseCBOR": deviceResponseCBOR.base64EncodedString()
      ]
      if let json = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("zkverify-post.json")
        try? json.write(to: url)
        print("\(tag) 📤 wrote /zkverify body (\(json.count) B) → \(url.path)")
        print("\(tag)    Transcript=\(transcriptBytes.count) B, ZKDeviceResponseCBOR=\(deviceResponseCBOR.count) B")
      }
    } catch {
      print("\(tag) ❌ presentation prove failed: \(error)")
    }
  }
}
#endif
