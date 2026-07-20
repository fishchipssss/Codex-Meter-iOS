# Codemagic IPA and TestFlight setup

The root [`codemagic.yaml`](codemagic.yaml) contains two workflows:

- `codex-meter-ipa` runs on pushes to `master` and produces `xtool/CodexMeter.ipa` without Apple distribution signing.
- `codex-meter-testflight` is manual and generates an Xcode workspace, signs the app and WidgetKit extension, and uploads the IPA to TestFlight.

The artifact-only IPA can be downloaded from the completed Codemagic build. It must be re-signed before installation on a normal device; the TestFlight workflow produces the distributable build.

## 1. Prepare Apple identifiers

The identifiers below are the upstream defaults. Fork maintainers must replace
them throughout the project with identifiers owned by their Apple Developer team.
In Apple Developer, create or confirm:

- App ID: `com.picklemike.codexmeter`
- Widget App ID: `com.picklemike.codexmeter.widget`
- App Group: `group.com.picklemike.codexmeter`

Enable the **App Groups** capability for both App IDs and attach the App Group to both. Profiles fetched before the App Group is attached must be regenerated.

In App Store Connect, create the Codex Meter app record using `com.picklemike.codexmeter`. The workflow uses marketing version `1.0.0`. Its app build number is Codemagic's monotonically increasing `PROJECT_BUILD_NUMBER` plus a one-time `1000` migration offset, preventing collisions with build numbers uploaded before automatic versioning was configured.

## 2. Store signing identities in Codemagic

Under **Team settings → codemagic.yaml settings → Code signing identities**:

- Add or reuse an Apple Distribution certificate under **iOS certificates**.
- Add App Store provisioning profiles for `com.picklemike.codexmeter` and
  `com.picklemike.codexmeter.widget` under **iOS provisioning profiles**.
- Configure an App Store Connect integration in Codemagic and update the
  `app_store_connect` integration name in `codemagic.yaml`.

The profiles must include the shared App Group entitlement. If the App Group was
enabled after profile creation, regenerate the profiles before adding them to
Codemagic.

The `ios_signing` block selects these stored identities by distribution type and
main bundle ID. Codemagic also matches the widget profile because its bundle ID
uses the main app prefix. No certificate or private key environment variable is
used, and Codemagic installs the selected certificate automatically.

## 3. Run and distribute

Pushes to `master` automatically start **Codex Meter — IPA artifact**. Start **Codex Meter — TestFlight** manually when the distribution signing credentials are ready.

On success, Codemagic uploads the IPA to App Store Connect and requests TestFlight beta processing. Configure internal or external tester groups in App Store Connect. External friends require Apple’s TestFlight beta review; internal App Store Connect users do not.

If automatic profile creation reports an App Group mismatch, confirm the group is assigned to both App IDs, delete the stale profiles in Apple Developer, and rerun the workflow.
