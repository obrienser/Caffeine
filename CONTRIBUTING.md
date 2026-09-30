# Contributing to Caffeine

Thanks for your interest in Caffeine. Bug reports, ideas and pull requests are welcome.

## Bugs and ideas

- Use the issue templates. For a bug, attach the file from **Export Log…** in Caffeine's card: it shows what Caffeine did and why.
- Don't report security problems in public issues. See [SECURITY.md](SECURITY.md).
- For a larger change, open an issue first, so that the approach is agreed before you spend time on it.

## Building

You need Xcode 27 or later and a signing certificate issued by Apple. The app and its background service trust each other only through code signatures, so your build works with the service only after you change the Team ID and the identifiers as described in [Building from source](README.md#building-from-source). Keep those changes out of your pull request.

For work on the interface, the **Caffeine UI Preview** scheme runs the app with a simulated session. It works with any signature, including Sign to Run Locally, installs nothing and changes no power setting.

To try changes to the background service, install a signed build in /Applications, as described in [Build and run](README.md#build-and-run).

## Tests

```sh
swift test --package-path Core
```

The Core package holds the session logic, the service protocol, the sleep backend and logging, with their tests. GitHub Actions runs these tests and an unsigned build of the app for every push to `main` and every pull request.

## Changing the background service

The service runs as root, so changes to it get the most careful review.

- Every change to the service needs a higher `helperBuild` in `Core/Sources/CaffeineServiceProtocol/ServiceProtocol.swift` and, by convention, a higher build number in both targets. The app compares `helperBuild` with the running service to find an older one and offer to update it.
- A change to the messages (`ServiceRequest`, `ServiceReply`, `ServiceSnapshot`) also needs a higher `protocolVersion`.
- Keep the service's work fixed and small: it runs only `/usr/bin/pmset` with fixed arguments and accepts no paths or commands from clients. [SECURITY.md](SECURITY.md) describes the model; update it together with the code.

## Style

- Follow the surrounding code: Swift 6 language mode, SwiftUI for the interface, no third-party dependencies.
- Comments explain why rather than what, in short plain sentences. Keep them accurate when the code changes.
- Caffeine has no network code. Please don't add any: no analytics, no update checks.
- Update README.md and SECURITY.md when the behavior they describe changes.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
