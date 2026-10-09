# UI Comparison

**Status: NOT_TESTED — no original screenshots exist and no device is available.**

## 1. Why this file contains no metrics

UI comparison requires two renderings of the same screen under matched
conditions. This environment has neither:

- no screenshot, screen recording or UI dump of the original anywhere in the
  repository;
- no device on which either build can be launched;
- no image-difference tooling (no OpenCV/Pillow/SSIM available here).

Fabricating a mean-absolute-difference or an SSIM value would be inventing a
measurement. None is reported.

## 2. What the UI *is* known to be, statically

This is the substitute for a pixel comparison: the layout facts that were
recovered, with their evidence status.

### 2.1 Settings → Crane

Source of truth: `Library/PreferenceBundles/CranePrefs.bundle/Root.plist`,
`Credits.plist`, `PreferenceLoader/Preferences/CranePrefs.plist`, and the
recovered specifier construction in `CranePrefs` 0x8D00.

| Row | Cell | Detail / action | Default | Conditional on |
|---|---|---|---|---|
| Crane | `PSLinkCell` | `CRPRootListController` | — | PreferenceLoader |
| APPLICATIONS | `PSLinkListCell` | `CRPApplicationListSubcontrollerController` → `CRPApplicationConfigurationListController` | search bar + alphabetic index on; section predicate `crane_isSupported == YES` | always |
| APP_SHORTCUTS | `PSGroupCell` | footer `APP_SHORTCUT_DESCRIPTION` | — | always |
| App Shortcuts Enabled | `PSSwitchCell` | `applicationShortcutEnabled` | YES | always |
| Launch App on Container Selection | `PSSwitchCell` | `launchApplicationOnContainerSelectionEnabled` | NO | always |
| Expand Shortcuts | `PSSwitchCell` | `expandContainersShortcutEnabled` | NO | always |
| Show 'New Container' Option | `PSSwitchCell` | `newContainerShortcutEnabled` | YES | always |
| Only Show if Containers Exist | `PSSwitchCell` | `onlyShowIfContainersExistEnabled` | YES | always |
| Show Container Notification Badges | `PSSwitchCell` | `showContainerNotificationBadgesEnabled` | YES | always |
| NOTIFICATIONS | `PSGroupCell` | footer `NOTIFICATIONS_SUPPORT_FOOTER` | — | always |
| Notifications Support Enabled | `PSSwitchCell` | `notificationsSupportEnabled` + bespoke setter | YES | always |
| Show Container in Title | `PSSwitchCell` | `showContainerInNotificationTitleEnabled` | YES | always |
| REPLACE_WITH_SUGGESTIONS | `PSGroupCell` | empty: Choicy / libSandy / Shortcuts / Activator suggestions | — | always |
| BACKUP_RESTORE | `PSGroupCell` | — | — | always |
| Create Multi-Container Backup | `PSButtonCell` | `createMultiBackupTapped` | — | always |
| Restore Multi-Container Backup | `PSButtonCell` | `restoreMultiBackupTapped` | — | always |
| OTHER | `PSGroupCell` | footer `© 2020-2024 Lars Fröder (opa334)` | — | always |
| "Crack by Repo BVN" | `PSButtonCell` | `openTwitter` | — | always *(this build; upstream: FOLLOW_ME_ON_TWITTER)* |
| Credits & Licenses | `PSLinkListCell` | `CRPCreditsController` | — | always |

### 2.2 Per-application pane

Source: `CranePrefs` 0x8D00 (`-[CRPApplicationConfigurationListController specifiers]`).

| Order | Row | Key | Default | Conditional on |
|---|---|---|---|---|
| 1 | Active Container | `activeContainer` → `CRPActiveContainerListItemsController` | — | always |
| 2 | Always Ask on App-Launch | `alwaysAskBeforeLaunchEnabled` | YES | always |
| 3 | group `CONTAINERS` | — | — | always |
| 4 | one row per container | per-container identifier | — | always |
| 5 | `Add` | `addButtonPressed` | — | always |
| 6 | group + footer `SEPARATE_NOTIFICATION_REGISTRATIONS_FOOTER` | — | — | `notificationsSupportEnabled` unset **or** true |
| 7 | Separate Notification Registrations | `separateNotificationRegistrationsEnabled` | YES | same as 6 |
| 8 | group + footer `SEPARATE_SYSTEM_ACCOUNTS_FOOTER` | — | — | always |
| 9 | Separate System Accounts | `separateSystemAccountsEnabled` | enabled | always |
| 10 | Game Center Support | `gameCenterSupportEnabled` | enabled | **only if** row 9 is true |
| 11 | group + footer `CONTAINER_PROTECTION_FOOTER` | — | — | always |
| 12 | Container Protection | `containerProtectionEnabled` | enabled | always |
| 13 | group + footer `PREVENT_SANDBOX_LOOKUPS_FOOTER` | — | — | always |
| 14 | Prevent Sandbox Lookups | `spoofSandboxLookupsEnabled` | enabled | always |

The asymmetry in row 10 — the specifier is always *built* (and cached in
`self.gameCenterSupportEnabledSpecifier`) but only *appended* when row 9 is true —
is reproduced in the reconstruction.

### 2.3 Typography, colours, spacing

**UNKNOWN.** None of it is recoverable from the extracted package:

- `Root.plist` / `Credits.plist` carry labels, footers, cells and keys — no
  fonts, colours, insets or control sizes.
- The 5 artboard/storyboard nibs in each app bundle are the Xcode UIKit template
  and contain no Crane UI.
- The Settings UI is rendered by the Preferences framework itself, so its
  typography follows the system, not Crane. The only Crane-specific typography is
  whatever custom cells draw, and those cells were not read.

`PSSpecifier` property keys observed in the recovered code are
`key`, `enabled`, `default`, `footerText`, `detailControllerClass`,
`valuesDataSource`, `titlesDataSource` — all behavioural, none visual.

### 2.4 Artwork

Eight PNGs, reused verbatim from the original package (byte-identical, verified
in `tests/ci_build_results.md` S-05):

| Asset | @2x | @3x |
|---|---:|---:|
| `AddIcon.png` | 300 B | 432 B |
| `ContainersIcon.png` | 438 B | 672 B |
| `SelectedContainerCheckmark.png` | 793 B | 1056 B |
| `SettingsIcon.png` | 1238 B | 1832 B |

Plus `CranePrefs.bundle/Icon@2x.png` (1635 B) and `@3x.png` (2255 B).

**Icon sizes are unknown.** The @2x/@3x file sizes imply a small template
glyph, but the pixel dimensions were not measured. A build should read the
dimensions before hard-coding any.

### 2.5 Localization

`/Library/Application Support/Crane.bundle/en.lproj/Localizable.strings` with
**204 keys**, plus 9 further languages (ar, de, fr, he, pt_BR, ru, tr, vi, zh_CN,
zh_TW). Copied verbatim into the reconstruction layout.

Behaviour-relevant keys and what they imply about the UI:

| Key | Implied UI element |
|---|---|
| `ACTIVE_CONTAINER`, `CONTAINER`, `CONTAINERS`, `DEFAULT_CONTAINER`, `SYSTEM_DEFAULT` | the Active Container sheet's vocabulary |
| `CONTAINER_DELETE_CONFIRMATION_TITLE` / `_MESSAGE` | a destructive-action confirmation sheet |
| `SET_CUSTOM_IDENTIFIER_MESSAGE` | states the format `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`, hyphens ignored, 32 hex chars |
| `BACKUP_NOT_ENOUGH_FREE_SPACE_ERROR`, `RESTORE_NOT_ENOUGH_FREE_SPACE_ERROR` | free-space gating before backup/restore |
| `MIGRATION_SUCCEEDED_MESSAGE`, `KEYCHAIN_MIGRATION_MESSAGE` | a modal that must be dismissed before Crane works |
| `REGISTRATION_FAILED_MESSAGE`, `PLUGIN_REDIRECTION_FAILED_MESSAGE` | daemon-failure alerts naming `apsd` and `pkd` |
| `SEROTONIN_ROOTHIDE_INCOMPATIBILITY_MESSAGE` | an explicit "not compatible with Bootstrap" message |
| `LIBSANDY_NOT_WORKING_ERROR_MESSAGE` | the libSandy failure alert |

### 2.6 Alert presentation

`CRErrorAlert` and `CRNewContainerAlert` are runtime-created `SBAlertItem`
subclasses with `errorTitle`, `errorMessage`, `actions`, `applicationID` and
`crane_reappearsAfterUnlock`; `SBAlertItem.configure:requirePasscodeForActions:`
and `reappearsAfterUnlock` are hooked. That means alerts can require a passcode
re-entry and can be configured to survive lock/unlock — an observable UI
behaviour the reconstruction does not implement (D-19).

## 3. What a future comparison must exclude

When a comparison is eventually possible, these regions must be masked or
separately evaluated, because they change between runs regardless of the tweak:

- the status bar clock, battery, and carrier/wifi indicators;
- notification banners and their timestamps;
- the app-switcher scroll position and page indicator;
- Settings' own nav-bar back-button label when the pane is pushed from a
  different entry point;
- any "3 days remaining" / update-available banner from the jailbreak.

## 4. Metrics to record when possible

| Screen | Metric | Original | Reconstruction | Status |
|---|---|---|---|---|
| Settings → Crane | mean absolute pixel difference | — | — | NOT_TESTED |
| Settings → Crane | SSIM | — | — | NOT_TESTED |
| Per-application pane | mean absolute pixel difference | — | — | NOT_TESTED |
| Per-application pane | row-order match | — | — | NOT_TESTED (expected to differ: rows 4–5 implemented, 6–14 conditional logic implemented but not the per-container sub-panes) |
| Container sheet | row-order and checkmark match | — | — | NOT_TESTED |
| App long-press menu | mean absolute pixel difference | — | — | NOT_TESTED (expected to differ entirely — D-08) |
| Crane error alert | title/message/action match | — | — | NOT_TESTED (expected to differ — D-19) |

## 5. Summary

| Measure | Value |
|---|---|
| Screens with a reference specification | 3 (settings root, per-application pane, container sheet) |
| Screens with reference screenshots | **0** |
| Screens compared | **0** |
| Metrics computed | **0** |
| Colour / typography / spacing values recovered | **0 of N** |
| Artwork assets reused byte-identically | 10 of 10 |

The only UI claims this project can make are the ones in §2: the *structure* of
two settings panes and the *existence* of the artwork. Every claim about how
those screens actually look is UNKNOWN.