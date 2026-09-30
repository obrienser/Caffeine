## What and why

<!-- What does this change, and why? Link the issue it resolves, if there is one. -->

## Checklist

- [ ] `swift test --package-path Core` passes.
- [ ] Changes to the app or the service are tested with a signed build installed in /Applications.
- [ ] If the background service changed, `helperBuild` is higher (and `protocolVersion`, if the messages changed).
- [ ] README.md and SECURITY.md still describe the behavior.
