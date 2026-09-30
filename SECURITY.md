# Security Policy

## Reporting a vulnerability

Please don't report security problems in public issues. Use GitHub's private reporting instead: open the **Security** tab of this repository and choose **Report a vulnerability** ([direct link](../../security/advisories/new)).

Include the macOS and Caffeine versions, the steps to reproduce and the impact you see. A log from **Export Log…** in the card often helps; review its contents before you attach it. Please keep the details private until a fix is released.

## Supported versions

Security fixes go into the latest release only.

## Security model

Caffeine includes a component that runs as root. This section describes what it does and how it's protected.

### The background service

`CaffeineHelper` is a launchd daemon inside the app bundle: the executable is `Contents/MacOS/CaffeineHelper`, its plist is in `Contents/Library/LaunchDaemons`. The app registers it with `SMAppService`, and it runs only after the user turns Caffeine on in **System Settings → General → Login Items & Extensions**. It exits at once if it isn't running as root.

The service does only this:

- It holds two IOKit power assertions, against idle system sleep and idle display sleep.
- In Closed Lid Mode, it runs `/usr/bin/pmset -g`, `pmset -a disablesleep 1` and `pmset -a disablesleep 0`: a fixed path and fixed arguments, no shell, a minimal environment, a 5-second timeout and a 64 KiB output limit.
- It listens for sleep, wake and power source notifications, and releases its hold before it acknowledges that the Mac is going to sleep.
- It keeps one recovery record, `/Library/Application Support/com.serhiital.Caffeine/sleep-recovery.json`. The record must be a non-empty regular file with a single link, owned by root, with mode `0600`, at most 8 KiB and without extended ACLs. Its folder must belong to root with mode `0700`, and every folder above it must belong to root and not be writable by group or others. The service opens every path component without following symbolic links.
- While a recovery record of an older version (`cooling-recovery.json`) is present in the same folder, it starts no session.
- It writes its log to `/Library/Logs/Caffeine/CaffeineHelper.log` and to the unified log.

It has no network code and accepts no paths, commands or other free-form input from clients.

### The XPC interface

- The service listens on the Mach service `com.serhiital.Caffeine.Helper` and exports one method, `perform(_:withReply:)`, which takes a JSON-encoded request.
- Every client must satisfy the code signing requirement `anchor apple generic and identifier "com.serhiital.Caffeine" and certificate leaf[subject.OU] = "WQ33LA2JZ5"`. The system checks it before the service accepts the connection (`NSXPCListener.setConnectionCodeSigningRequirement`). Other processes, including scripts running as the logged-in user, can't connect.
- A request is at most 8 KiB, must carry the current protocol version and may only use the actions `status`, `start`, `update`, `heartbeat` and `stop`. A timer must be one of the fixed durations. A connection can have at most 16 requests in flight.
- Only the connection that started a session can change or stop it. The session ends when that connection closes, when its timer expires, or after 20 seconds of awake time without a renewal.
- The app requires the same kind of signature from the service (identifier `com.serhiital.Caffeine.Helper`), and it checks the signatures of the installed app and the bundled service before it registers the service.

### Updates

The service watches its own executable. When a complete, correctly signed replacement is installed, it exits as soon as no session or cleanup is pending, and launchd starts the new version. The app replaces an older service registration only after that service reports the same idle state.

### The app

The app runs as the logged-in user, with the Hardened Runtime and without the App Sandbox. Its one global shortcut, ⌃⌥⌘A, is registered with `RegisterEventHotKey`, so the app needs no Accessibility or Input Monitoring permission and receives no other keystrokes. Turn Off Screen on Close and Lock Screen on Close call private macOS functions: `SLSConfigureDisplayEnabled` in SkyLight and `SACLockScreenImmediate` in login.framework. The display change is an app-only configuration, which macOS reverts when the app exits. When the built-in display is the only one, the app runs `/usr/bin/pmset displaysleepnow` instead.

### Out of scope

- Attacks that already require administrator rights or root. Such a user can change power settings directly.
- Builds signed by someone else. They trust their signer's Team ID, not the one above.
