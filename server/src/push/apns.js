import apn from '@parse/node-apn';

// Ported from the standalone `digdir-wallet-messaging-backend` prototype,
// with one deliberate change: the original sent `alert: { title, body }` in
// cleartext as part of the push payload. That leaks message content to
// Apple's push servers, which defeats the entire point of the E2EE scheme
// in this repo. This version sends a CONTENT-FREE silent push — "you have
// mail", nothing else — and the app fetches + decrypts the real content
// itself over the authenticated `/messages/fetch` endpoint.
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

export async function sendSilentWakeUpPush(deviceToken) {
  if (!deviceToken) return;

  const notification = new apn.Notification();
  notification.topic = process.env.APNS_BUNDLE_ID || '';
  notification.contentAvailable = true;
  // No `alert`, `sound`, or `badge` — a pure background wake-up. Apple
  // recommends priority 5 (not 10) for content-available-only pushes.
  notification.priority = 5;
  notification.pushType = 'background';
  notification.payload = { type: 'new-message' };

  const result = await getProvider().send(notification, deviceToken);
  for (const failure of result.failed) {
    console.error('[APNs] push failed', failure.device, failure.response || failure.error);
  }
}
