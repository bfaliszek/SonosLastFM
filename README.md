# Sonos → Last.fm (macOS)

A native macOS menu-bar app. Every 15 seconds it checks the currently playing track through the Sonos Cloud Control API, sends a “Now Playing” update to Last.fm, and scrobbles the track after at least half of it has been played (up to 240 seconds).

## Running the app

macOS 13+ and Xcode are required for compilation.

```sh
swift build -c release
.build/release/SonosLastFM
```

The ready-to-run application bundle is also available at [`Releases`](https://github.com/bfaliszek/SonosLastFM/releases/tag/1.0).

## Sonos setup

The app reads playback data through the official Sonos Control API. You need three values: **Sonos Key**, **Sonos Secret**, and a **Sonos Refresh Token**.

### 1. Create an integration and credentials

1. Sign in to the [Sonos Developer Portal](https://developer.sonos.com/) and create a **Direct Control Integration**.
2. In **Client Credentials**, create a credential key (`Key`).
3. Set an exact, publicly reachable HTTPS address as the **Redirect URI**, for example `https://example.com/sonos-callback`.
4. Save the **Key** and **Secret** from that same Client Credentials section.

> `Key` is the value used as the OAuth Client ID. Do not use the “Your Client ID” field in the integration header. The Redirect URI must match exactly in both Sonos configuration and the OAuth request.

Documentation: [creating Sonos credentials and OAuth](https://docs.sonos.com/docs/authorize), [Sonos Control API](https://docs.sonos.com/docs/control).

### 2. Sign in to Sonos and obtain an OAuth code

Open the following address in a browser, substituting your **Key** and URL-encoded Redirect URI:

```text
https://api.sonos.com/login/v3/oauth?client_id=YOUR_KEY&response_type=code&state=sonoslastfm&scope=playback-control-all&redirect_uri=YOUR_URL_ENCODED_REDIRECT_URI
```

Example for the Redirect URI `https://example.com/sonos-callback`:

```text
https://api.sonos.com/login/v3/oauth?client_id=YOUR_KEY&response_type=code&state=sonoslastfm&scope=playback-control-all&redirect_uri=https%3A%2F%2Fexample.com%2Fsonos-callback
```

After approving access, Sonos redirects the browser to your address with a `code` parameter. Copy only its value.

### 3. Exchange the code for a Refresh Token

Run the command below in Terminal. Do not enter the Secret or OAuth code into chat or a file.

```sh
KEY="YOUR_KEY"
read -s "SECRET?Paste the Sonos Secret: "
echo
read "CODE?Paste the OAuth code: "
REDIRECT_URI="https://example.com/sonos-callback"

curl -sS -X POST "https://api.sonos.com/login/v3/oauth/access" \
  -H "Content-Type: application/x-www-form-urlencoded;charset=utf-8" \
  -H "Authorization: Basic $(printf '%s:%s' "$KEY" "$SECRET" | base64)" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "redirect_uri=$REDIRECT_URI"
```

The JSON response contains `refresh_token`. Enter the following in the app:

| App field | Value |
|---|---|
| Sonos Key (OAuth Client ID) | `Key` from Client Credentials |
| Sonos Secret (OAuth Client Secret) | `Secret` from the same Client Credentials entry |
| Sonos Refresh Token | `refresh_token` from the OAuth response |

Click **Save**, then **Test Sonos connection**. An Event Callback URL is not needed by this version of the app, since it polls the API rather than subscribing to events.

### Mac media keys

Enable **Use Mac media keys to control Sonos** in the **Mac Media Keys** section of Settings. Grant the app Accessibility permission in **System Settings → Privacy & Security → Accessibility**; the app includes an **Open Accessibility Settings** link for this purpose. After granting access, return to the app and enable the switch again. The global Play/Pause key pauses or resumes the same Sonos group, while Previous and Next skip tracks in that group.

## Launch at login

Enable **Launch Sonos → Last.fm when you log in** in the **Startup** section of Settings. macOS may ask you to approve the app as a login item.

## Last.fm setup

1. Create an application on the [Last.fm API account page](https://www.last.fm/api/account/create).
2. Copy its **API Key** and **Shared Secret**.
3. Enter those values in the app’s Last.fm section.
4. Click **Connect Last.fm**. The app opens a browser, requests consent, and retrieves the **Session Key** automatically.
5. Click **Save**.

The Last.fm session uses the standard desktop flow: `auth.getToken` → user consent → `auth.getSession`. Documentation: [Last.fm Desktop Authentication](https://www.last.fm/api/desktopauth), [Last.fm Scrobbling API](https://www.last.fm/api/scrobbling).

## Security

All API data — Sonos Key, Secret, and Refresh Token, plus Last.fm API Key, Shared Secret, and Session Key — is stored locally in the **macOS Keychain** under the `pl.sonoslastfm.app` service. It is not stored in the repository or in plain-text files.

Do not share Secrets, OAuth codes, Refresh Tokens, or Session Keys. If any of them are exposed, create new credentials in the relevant portal and authorize the app again.

### Limitation of the local version

Sonos recommends performing Client Secret exchanges and token refreshes on a server. This app performs them locally for private use on the user’s own Mac. A public release should move OAuth and token handling to a secure backend.
