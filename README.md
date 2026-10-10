# Shelf

Ian's read-later app for iPhone. Share articles, posts and links to Shelf from any app and read them later as clean, plain text, even offline. A **For You** tab shows articles Claude picks each morning.

## How it's built

- Native SwiftUI app (iOS 17+) with a Share extension and Home Screen / Lock Screen widgets. The Xcode project is generated from `project.yml` with XcodeGen.
- Articles are cleaned up with Mozilla's [Readability](https://github.com/mozilla/readability) (Apache 2.0) inside a hidden web view with the page's scripts switched off.
- GitHub Actions builds it and sends it to TestFlight, using the same Apple secrets and `Match-Secrets` certificate store as Trio. It rebuilds on the 1st of each month so it never expires.
- `feed/recommendations.json` holds the daily For You picks; the app reads it from GitHub.

## Workflows

1. **Set up with Apple**: `check` the secrets, create the `identifiers`, then `certificates`.
2. **Check build and screenshots**: runs on every push; builds for the simulator, tests extraction on live news sites and saves screenshots to the `screenshots` branch.
3. **Build Shelf**: builds and uploads to TestFlight. Runs monthly and on demand.
