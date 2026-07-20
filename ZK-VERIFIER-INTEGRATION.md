# ZK-presentasjon (Longfellow) — verifier-integrasjon

Status per 2026-07-14: wallet-en produserer et **ekte** ZK-bevis av `age_over_18` fra mDL-en
ende-til-ende (målt: ~352 KB, ~0,4 s på enhet). Neste steg er å utløse dette via en **egen
verifier** over OpenID4VP.

## Kort: wallet-siden er ferdig — ingen kodeendringer trengs

`wallet.zkSystemRepository` registreres ved oppstart (se `Wallet/ZkSystemProvider.swift` +
`AppDelegate.registerZkSystem()` + `WalletKitController.registerZkSystemRepository`). Når en
OpenID4VP-forespørsel inneholder `zk_system_type` som matcher vår krets, kjører WalletKit
`MdocHelpers.getDeviceResponseToSend` → `transformDeviceResponseWithZkp` →
`LongfellowZkSystem.generateProof` automatisk, og svarer med en `DeviceResponse` v1.1 som
har `zkDocuments` i stedet for `documents`.

## Hva verifieren MÅ sende (DCQL)

```json
{
  "credentials": [
    {
      "id": "mdl_zk",
      "format": "mso_mdoc_zk",
      "meta": {
        "doctype_value": "org.iso.18013.5.1.mDL",
        "zk_system_type": [
          {
            "system": "longfellow-libzk-v1",
            "circuit_hash": "8d079211715200ff06c5109639245502bfe94aa869908d31176aae4016182121",
            "num_attributes": 1,
            "version": 7,
            "block_enc_hash": 4151,
            "block_enc_sig": 4096
          }
        ]
      },
      "claims": [
        { "path": ["org.iso.18013.5.1", "age_over_18"] }
      ]
    }
  ]
}
```

Kritisk:
- `zk_system_type` er en **array** i `meta` (parses i `Openid4VpUtils.zkSpecs`, linje ~172).
- Spec-feltene må matche vår krets **eksakt** (verdiene over er verifisert fra native spec).
  Feil `circuit_hash`/`version`/`num_attributes` ⇒ `findMatchedZkSystem` returnerer nil ⇒
  ingen zkDocuments (faller tilbake til vanlig disclosure eller feiler).
- `claims.path` = `[namespace, elementIdentifier]`. mDL-namespace er `org.iso.18013.5.1`
  (IKKE docType-strengen). For `age_over_18` og num_attributes=1: nøyaktig ÉN claim.
- Format `mso_mdoc` og `mso_mdoc_zk` mappes begge til `.cbor`; bruk `mso_mdoc_zk`.

## Verifier-trust (må ikke avvises)

Wallet validerer verifieren FØR ZK-steget, via `ClientIdScheme`. Standard aktiverte:
`[.x509SanDns, .x509Hash, .redirectUri]` (`OpenId4VpConfiguration.defaultClientIdSchemes`).
Enklest for test:
- **redirectUri** — matcher bare `redirect_uri`/response-mode (ingen sertifikat).
- **preregistered** — legg test-verifieren inn som kjent klient.
- **x509_san_dns** — self-signed sert med DNS-SAN; kjeden valideres mot
  `trustedReaderRootCertificates` (`OpenId4VpService.chainVerifier`).

Ingen ZK-spesifikk trust — ZK er transparent for verifikasjonen av forespørselen.

## Respons tilbake til verifieren

`vp_token` = base64url(CBOR(DeviceResponse)). Ved ZK settes `version = "1.1"` og
`zkDocuments`-feltet fylles (i stedet for `documents`). Verifieren må altså kunne parse
`DeviceResponse` v1.1 og verifisere Longfellow-beviset (samme krets/spec).

## UI/samtykke

Ingen egen ZK-UI: request-items-skjermen viser `age_over_18` som vanlig disclosure; selve
ZK-transformasjonen skjer stille etter samtykke (`generateCborVpToken`). Brukeren ser altså
«del age_over_18», ikke «bevis via ZK». Vurder å legge til en indikator senere.

## Åpne punkter for i morgen

1. Sett opp test-verifier som sender DCQL-en over (enklest: `redirectUri`-scheme).
2. Verifiser proof på verifier-siden med samme v7-krets (`circuit_hash` 8d079211…).
3. Bekreft at request-items-skjermen håndterer `mso_mdoc_zk`-forespørselen uten å kreve
   felter kretsen ikke dekker (kun 1 attributt for num_attributes=1).
4. Rydd DEBUG-stillaset: `ZKProbe` (kjører prove ved oppstart, kan trigge biometri) bør
   fjernes/gates før release. Regenerer Cuckoo `MockWalletKitController`
   (feature-common, feature-dashboard) for den nye protokollmetoden.

## Nøkkelfiler
- `Wallet/ZkSystemProvider.swift`, `Wallet/AppDelegate.swift` (registrering)
- `Modules/logic-core/Sources/Controller/WalletKitController.swift` (`registerZkSystemRepository`)
- WalletKit: `Services/Openid4VpUtils.swift` (`zkSpecs`, `parseDcqlFormats`),
  `Services/OpenId4VpService.swift` (`generateCborVpToken`),
  `MdocDataTransfer18013/MdocHelpers.swift` (`getDeviceResponseToSend`, `transformDeviceResponseWithZkp`)
