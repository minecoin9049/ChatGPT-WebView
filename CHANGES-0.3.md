# 0.3 (3) — iOS 16 mobile experience

Uses the real-system Safari user agent confirmed working by the iOS 16.1.1 tester. No manual mode switch is required. This remains a WKWebView app; it does not implement the App Store app's native rendering engine or promise identical voice/background behavior.

## Interaction and recovery
- Browser swipe-back/forward is disabled. ChatGPT's own navigation remains available.
- Interactive keyboard dismissal, immediate outer-scroll touch delivery, no outer-page rubber banding, and matching light/dark native margins.
- Removed the startup diagnostic alert and shake gesture. Hold two fingers on the page for 1.5 seconds to open the app menu.
- Last regular chat is restored on cold launch (up to 7 days). A live page is kept when returning from background; connectivity changes never force-reload a streaming reply.
- Use WebKit's existing persistent website store and normal HTTP cache policy. No force-caching of authentication or conversation API responses. WebKit already provided this cache in earlier builds; this release adds bounded offline text snapshots, not an invented larger HTTP cache.
- Web content process recovery is limited to 2 reloads per 5 minutes to avoid a crash loop. No message submissions are replayed.
- Tapped external article links open in a system browser sheet. Downloads supported by WKDownload open the system share/save panel.

## Automatic offline cache
- Enabled by default: at most 20 recent regular `/c/<UUID>` chats, 7 days, 10 MB total; each file at most 200 KB. Each snapshot includes at most the last 80 loaded user/assistant text blocks, up to 12,000 characters per block.
- Captures loaded text after the page has been quiet for roughly 1.8 seconds; streaming updates are coalesced. Backgrounding also requests a snapshot. Data that has not loaded or has not yet been saved is unavailable offline.
- No prefetching of conversation history, images or attachments. Composer drafts and temporary-chat URLs are excluded. Offline snapshots are read-only plain text and can be incomplete; they are not injected into the online page and cannot send messages offline.
- Open via the offline/error banner or two-finger long-press menu. The menu also disables and clears the cache.
- Snapshots stay in the app's protected Application Support directory, use iOS complete file protection and are excluded from backups. No cookies, credentials or network response bodies are copied into snapshots. Cache reads/writes run on a serial background queue.
- Recognized logout links/requests clear snapshots and the last-chat route. This is a device-local cache, not a complete account-sync system: server-side deletions or account changes in another app do not synchronize to it. Clear local copies when handing over the device or switching accounts if the website did not use a recognized logout route.

## Artwork and validation
The package script extracts icon metadata, PNG artwork and Assets.car from the upstream IPA already in this repository. It does not reuse its executable or entitlements. The original MIT license remains in the repository.

Automated checks cover cache bounds, expiry, updates, clearing, invalid IDs, temporary-chat exclusion, extraction bounds, logout, deduplication, and route settling. CI compiles the iOS 16 device target and checks version, bundled script, original artwork and IPA layout. Actual keyboard feel, scrolling speed, account login, file downloads and screen layout still require iPhone testing; no performance benchmark improvement is claimed.
