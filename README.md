# LinkScanner — Cloudflare Workers Free + Telegram

This package contains the Flutter Android app and a small Cloudflare Worker that forwards one fixed startup event to your Telegram chat. The Worker is designed for Cloudflare's Workers Free plan.

## What is included

- Flutter WebView app with the existing HTTPS exact-host allowlist.
- Startup notification remains **off until an HTTPS endpoint is configured** and still requires in-app user consent.
- A Cloudflare Worker at `worker/src/index.js` that calls Telegram's official `sendMessage` API.
- Telegram bot token and chat ID are read only from Cloudflare Worker secrets. They are not embedded in Flutter, the APK, this repository, or GitHub Actions.
- Payload size limit, strict event schema, fixed server-side message template, generic error responses, and a Cloudflare rate-limiting binding.
- Node.js tests for the Worker and existing Flutter URL-policy tests.

## 1. Rotate the Telegram token first

The previous bot token was pasted into a chat and must be treated as exposed. Revoke it through Telegram's BotFather and issue a **new** token. Do not paste the replacement token into ChatGPT, Flutter source, GitHub, or this ZIP.

Open your bot's chat in Telegram and send `/start` before testing private-chat messages. Keep the chat ID available for the Cloudflare secret setup below.

## 2. Deploy the free Cloudflare Worker

You need a Cloudflare account, Node.js/npm, and a terminal. The Worker is deployed separately from the Flutter APK.

From a terminal, enter the `worker` folder:

```bash
cd worker
npm install
npx wrangler login
```

Set the two secrets. Wrangler prompts for each value; enter them in the terminal prompt, not in a source file:

```bash
npx wrangler secret put TELEGRAM_BOT_TOKEN
npx wrangler secret put TELEGRAM_CHAT_ID
```

Deploy:

```bash
npm run deploy
```

Wrangler prints a `workers.dev` URL. Copy it. The app endpoint must be that URL followed by `/api/notify`, for example:

```text
https://YOUR-WORKER.YOUR-SUBDOMAIN.workers.dev/api/notify
```

Do not include angle brackets in the real URL.

Check the health route in a browser:

```text
https://YOUR-WORKER.YOUR-SUBDOMAIN.workers.dev/health
```

It should return a small JSON health response. It does not reveal your secrets.

### Test the Telegram delivery

Run this from a terminal, replacing the URL with your Worker URL:

```bash
curl -i -X POST "https://YOUR-WORKER.YOUR-SUBDOMAIN.workers.dev/api/notify" \
  -H "Content-Type: application/json" \
  -d '{"event":"app_started","application":"LinkScanner","version":"1.1.0"}'
```

A successful response is `200` with `{"ok":true}` and a message should appear in your Telegram chat. This test sends a real notification.

## 3. Connect the Flutter app

The app reads its endpoint at build time. The endpoint URL is not a secret; the Telegram token and chat ID remain on Cloudflare.

### Local build

From the Flutter project root (not the `worker` folder):

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define=NOTIFICATION_ENDPOINT=https://YOUR-WORKER.YOUR-SUBDOMAIN.workers.dev/api/notify
```

If you omit `NOTIFICATION_ENDPOINT`, startup notifications stay disabled.

### GitHub Actions build

In your GitHub repository, open **Settings → Secrets and variables → Actions → Variables**, create a repository variable named:

```text
NOTIFICATION_ENDPOINT
```

Set its value to your complete HTTPS Worker endpoint ending in `/api/notify`.

Push to `main` or manually run the `LinkScanner Android Build` workflow. The workflow passes this variable to Flutter at build time. Do not add the Telegram token or chat ID to GitHub.

## 4. Security and privacy boundaries

- The app asks for consent before sending the startup event. It sends only `event`, the fixed app name, and the app version. It does not send visited URLs, page contents, account details, or device identifiers.
- The Worker rejects other event names, extra JSON fields, malformed versions, non-JSON content, and bodies larger than 1 KiB. The Telegram message text is created on the server; arbitrary text from the client is never forwarded.
- Cloudflare's rate-limit binding is set to approximately 3 accepted notifications per minute per source IP **per Cloudflare location**. The limit is approximate rather than a strict global quota. Users sharing a mobile-carrier/NAT IP can share that allowance. Cloudflare necessarily processes the incoming network connection and source IP; this Worker does not persist or log the IP itself.
- Because the mobile app is distributed to users, its public Worker URL cannot prove that a request truly came from your APK. A determined person can call a public endpoint directly. The strict fixed event and rate limit reduce abuse but are **not equivalent to user authentication** and cannot guarantee zero spam. Do not use this endpoint for sensitive commands or arbitrary message forwarding.
- Cloudflare Workers Free currently documents 100,000 requests per day and a 10 ms CPU-time limit per invocation. Limits and availability can change; check Cloudflare's current documentation before relying on a production quota.
- The Worker does not store Telegram credentials in source. Keep the new token private and rotate it immediately if it is ever exposed.

To disable app notifications, remove the `NOTIFICATION_ENDPOINT` GitHub variable (or omit the Dart define in local builds). To stop Telegram delivery at the server, delete the Worker secrets or remove the Worker.

## 5. Tests

Worker tests use Node's built-in test runner and do not require a Telegram connection:

```bash
cd worker
npm test
```

Flutter tests:

```bash
cd ..
flutter pub get
flutter analyze
flutter test
```

## 6. Android build/signing note

The GitHub workflow builds a Release APK, but it does not sign it with a private publishing keystore. Configure a private Android keystore and GitHub Actions secrets before official distribution. Never commit `.jks`, keystore passwords, bot tokens, or chat IDs.

The project source and Worker tests can be checked here, but a Flutter/Android SDK build was not run in this environment. Run the workflow and test on a real Android device before release. No software can honestly be guaranteed free of every vulnerability.
