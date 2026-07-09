import apn from '@parse/node-apn';

// Ported from the standalone `digdir-wallet-messaging-backend` prototype,
// with one deliberate change: the original sent `alert: { title, body }` in
// cleartext as part of the push payload. That leaks message content to
// Apple's push servers, which defeats the entire point of the E2EE scheme
// in this repo. This version sends a GENERIC alert — the same fixed text
// for every message, regardless of sender or content — so the user still
// sees a visible banner without Apple (or anyone intercepting the push)
// learning anything case-specific. The actual title/body is only ever
// fetched and decrypted locally over the authenticated `/messages/fetch`
// endpoint.
let provider;

function getProvider() {
  if (provider) return provider;
  provider = new apn.Provider({
    token: {
      key: process.env.APNS_KEY_PATH || '',
      keyId: process.env.APNS_KEY_ID || '',
      teamId: process.env.APNS_TEAM_ID || '',
    },
    production: process.env.APNS_ENVIRONMENT === 'production',
  });
  return provider;
}

const GENERIC_ALERT = {
  title: 'Ny melding i lommeboken',
  body: 'Du har fått en ny melding. Åpne appen for å se den.',
};

export async function sendSilentWakeUpPush(deviceToken) {
  if (!deviceToken) return;

  const notification = new apn.Notification();
  notification.topic = process.env.APNS_BUNDLE_ID || '';
  notification.alert = GENERIC_ALERT; // same text every time — never derived from the actual message
  notification.sound = 'default';
  notification.contentAvailable = true; // also wake the app in the background to pre-fetch, if it can
  notification.priority = 10; // required for a visible alert to be delivered promptly
  notification.pushType = 'alert';
  notification.payload = { type: 'new-message' };

  const result = await getProvider().send(notification, deviceToken);
  for (const failure of result.failed) {
    console.error('[APNs] push failed', failure.device, failure.response || failure.error);
  }
}
