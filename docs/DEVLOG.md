# HeatBar devlog

Notes on what we built, what broke and what we learned. Newest at the bottom.

## 2026-11-19: 2.0, every Mac watches every Mac

HeatBar started as a quick way to check a Mac mini's chip temperature from a laptop. Version 1.1 had two modes: an agent that served readings and a remote viewer. In 2.0 there is only one mode. Every Mac runs the same app, serves its own readings on its Tailscale address, and finds the other copies with `tailscale status --json`.

Things macOS made harder than expected:

- **No public temperature API.** Apple Silicon only exposes degrees through the private `IOHIDEventSystemClient` calls. Stats, iStat Menus, TG Pro and Macs Fan Control use private calls or the SMC too, which is why none of them are on the Mac App Store. `ProcessInfo.thermalState` is public but has no degrees. It reports nominal, fair, serious or critical, which is still the best signal of real throttling.
- **The Tailscale CLI inside the app bundle** only acts as a CLI when `SHLVL` is set. launchd doesn't set it, so HeatBar sets it before running the command.
- **Network.framework's NWListener**, bound to the Tailscale IP, never completed a TCP handshake for connections from the same Mac. The server now uses plain BSD sockets. Accepted sockets inherit `O_NONBLOCK` from the listener, which caused "network connection lost" errors until reads were made blocking again.
- **App Transport Security** blocks plain `http://` to other machines with error -1022, even inside a WireGuard tunnel. `curl` isn't subject to ATS, which hid the problem during early testing. The app needs `NSAllowsArbitraryLoads`.
- **A Mac can't reach its own Tailscale IPv6 address**, so discovery uses IPv4.

Presence comes from HeatBar's own 5-second status polls, not from Tailscale. A Mac is stale after 3 missed polls and offline after 2 minutes.

## 2026-11-20: 2.1, simpler and quieter

**Tailscale only.** 2.0 fell back to listening on all interfaces when Tailscale was missing. We considered a LAN mode with a switch, but finding Macs on a LAN means Bonjour, a Local Network permission prompt, and readings visible to anyone on the same Wi-Fi. We dropped both the idea and the fallback. HeatBar now binds only to its Tailscale addresses and refuses any connection that doesn't come from one. macOS delivers packets for a bound IP that arrive on other interfaces too, so the bind alone isn't enough.

**Alerts on the Mac you're using.** The log showed a laptop that went to sleep a dozen times one night, and every sleep produced an "unreachable" alert on a headless Mac mini. Each Mac now adds `user_idle`, the seconds since the last keyboard or mouse input, to its status. Every Mac still evaluates every alert, but only the online Mac with the most recent input shows it. The others write "ALERT (shown on X)" to their log. This needs no push channel, only the polling HeatBar already does.

**Long lists.** Other Macs are sorted hottest first, with offline ones last. With more than three Macs, each one collapses into a single line with a submenu. The menu bar can show this Mac or the hottest Mac.

### Why the alerts were silent

"Send test alert" did nothing on either Mac. There were three separate causes:

1. **The app was in front.** Clicking a menu item makes a menu-bar app the active app, and macOS doesn't show banners for the active app unless its `UNUserNotificationCenterDelegate` asks for them in `willPresent`. We added the delegate.
2. **Screen Sharing.** On the Mac mini, the system log said the banner was "muted by display state", reason "display shared". macOS hides all banners while the screen is shared unless "Allow notifications when mirroring or sharing the display" is on.
3. **Notifications turned off.** On the laptop the log said `notificationsAllowed: false`, and every alert was handled "as none". HeatBar now checks this at launch and shows "Notifications are off — Open Settings…" in the menu.

Lesson: `log show --predicate 'process == "usernoted" OR process == "NotificationCenter"'` tells you exactly what macOS did with a notification and why. We should have looked there first.

### The icon that wouldn't show

HeatBar got an app icon, drawn in code by `scripts/make-icon.swift`. It doesn't use SF Symbols, because their licence excludes app icons. On macOS 15 it showed up everywhere after re-registering the app (`lsregister -f`) and restarting `usernoted`. On macOS 26 the permission prompt showed it, but banners and System Settings kept a blank placeholder.

What we tried, in order:

- Cleared the icon caches and restarted the notification daemons. No change.
- Unregistered every other copy of the app in LaunchServices, because another project traced the same symptom to dead copies. No change.
- Added a compiled asset catalog (`Assets.car`) with `CFBundleIconName`, since macOS 26 takes app icons from there. Compiling it needs Xcode's `actool`, so it runs on a GitHub macOS runner: see `.github/workflows/icon.yml`. This should be worth keeping for Finder and the Dock on macOS 26, but it didn't fix the notifications.

The system log finally named the problem: `Unable to find notifier for identifier com.<name>.heatbar, fallback to: …/HeatBar.app/`. That was the personal bundle ID of a 1.x build. On macOS 26, notification settings and history no longer live in `com.apple.ncprefs`. They live in `~/Library/Group Containers/group.com.apple.usernoted/` (a preferences plist and a database), and both still referred to the old ID for the same app path. Cleaning that up is the next step.

Lesson: changing a bundle ID leaves old records behind in notification settings, keyed by path. Pick the final bundle ID before anyone installs the app.

### Releases

- v2.1 is published with the zip attached. The v2.0 pre-release, which still described the fallback, was removed.
- 2.1.1 (the `Assets.car` icon catalog) is built and waits on the notification-icon fix.
