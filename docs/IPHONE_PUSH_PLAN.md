# iPhone notifications (Web Push) — plan, on hold

Status (2026-11-26): not started, on purpose. The user wants it, but fears too many notifications once it is on.
Decide again before building; the main open question is "which notifications are worth a buzz", not the technique.

## Why Web Push

The iPhone page is already a Home Screen web app over `https://<mac>.ts.net/` (real certificate, secure context).
iOS 16.4+ gives such apps standard Web Push: free, no third-party server, no Apple Developer account, no new app.
The Mac sends to Apple's push server itself; the phone gets it through APNs, so it arrives with the page closed
and with Tailscale off on the iPhone. Tailscale is needed only to subscribe and to open the chat from the alert.

Rejected for now: ntfy (extra app, public server, topic name is the secret, tap does not open the page),
Pushover (paid, third party), a native iOS app + APNs ($99/year, a new app).

## How it would work

1. Phone page (Home Screen icon only, not a Safari tab): "알림 켜기" in a tap → `Notification.requestPermission()`
   → `pushManager.subscribe({userVisibleOnly: true, applicationServerKey})` → `POST /api/push/subscribe`
   (endpoint, p256dh, auth, a device name).
2. Mac (AIRemote): keeps the subscriptions; a VAPID key pair made once. Sending is RFC 8291 (aes128gcm) +
   RFC 8292 (VAPID ES256 JWT, `exp` < 24 h, `sub` mailto), `TTL` header, all with CryptoKit; no dependency.
   410/404 from Apple removes that subscription.
3. `sw.js`: `push` → `showNotification` (+ `setAppBadge`); `notificationclick` → open `/#chat/<id>`.
4. Events come from what Unread and Inbox already decide (7cd60c4); detection in AIChat, wiring in App.
5. Each iPhone/iPad subscribes on its own; each Mac (its own origin) sends only for work it ran.

## Traps found while planning

- Key: the page authenticates with `?k=` saved in `localStorage` (`RemotePage.swift` ~524). A manifest with
  `start_url: "/"` would open the Home Screen app without the key. Serve the manifest with the key, or leave
  `start_url` out. `sw.js` and `/api/push/*` need the key too.
- Today there are only `apple-mobile-web-app-*` meta tags, no manifest and no service worker. After adding them the
  Home Screen icon may need to be removed and added again (check on a real iPhone).
- No silent push: every push must show an alert or iOS may drop the subscription. So the Mac decides whether to send
  (e.g. not when that device is polling that chat in the foreground: poll requests would carry a device id).
- Payload about 4 KB: title, a short preview, chat id. Never the whole answer.
- Tests: subscription file under `AI_ILLUMINATI_TEST_HOME`; crypto checked against RFC 8291 Appendix A.
- iOS 18.4+ also has Declarative Web Push (no service worker needed); the service-worker path stays the default.

## Against too many notifications (the reason it is on hold)

Ideas to weigh when this comes back; pick the smallest set that keeps it useful:
- Off by default; only "needs you" (approvals, TODO decisions, `<needs-you>`) at first, never every answer.
- "Finished" only when asked: a per-chat or per-TODO "알림 받기" bell, not for all chats.
- Never while the user is at the Mac (recent input) or has that chat open on a phone.
- Bundle: several events within a few minutes become one alert ("3 chats finished"); one alert per chat until read.
- Quiet hours, and iOS Focus already applies.
- Per device on/off and kinds in the Mac's iPhone window.

## Steps when it is picked up

1. Manifest, service worker, subscribe, VAPID + encryption, a "테스트 알림" button; confirm on a real iPhone.
2. Connect events (starting with "needs you"), with the foreground and at-the-Mac checks.
3. Device list in the Mac's iPhone window, kinds per device, badge, bundling.
