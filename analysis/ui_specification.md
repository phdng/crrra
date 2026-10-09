# UI Specification

Source-independent description of every UI surface the original exposes, with
an evidence class per property. Where a property is not recoverable it says so
rather than guessing.

**Nothing here is measured from a screenshot.** No screenshot, recording or UI
dump exists in this repository. See `tests/ui_comparison.md` for the
measurement status.

Evidence classes: **CONFIRMED_STATIC** (from plists, binaries or decompilation),
**CORROBORATED**, **INFERRED**, **UNKNOWN**.

## 1. UI surface inventory

| Surface | Host | Class | Evidence |
|---|---|---|---|
| Settings entry row | Settings → Crane | `PSLinkCell` via PreferenceLoader | CONFIRMED_STATIC |
| Root settings pane | Settings | `CRPRootListController` | CONFIRMED_STATIC |
| Applications pane | Settings | `CRPApplicationConfigurationListController` | CONFIRMED_STATIC |
| Container configuration pane | Settings | `CRPContainerConfigurationListController` (60 methods) | CONFIRMED_STATIC |
| Active Container sheet | Settings | `CRPActiveContainerListItemsController` | CONFIRMED_STATIC |
| Backup/restore panes | Settings | `CRPNewBackupListController`, `CRPBackupRestoreController`, `CRPRestoreContainerMatchController`, `CRPMultiBackup*` (11 controllers total) | CONFIRMED_STATIC |
| Game Center accounts pane | Settings | `CRPGameCenterAccountsController` | CONFIRMED_STATIC |
| Progress alert | Settings | `CRPBackupRestoreProgressAlertController` (30 methods) | CONFIRMED_STATIC |
| Credits + 2 license panes | Settings | `CRPCreditsController` + 2 subclasses | CONFIRMED_STATIC |
| Custom cells | Settings | `CRPDestructiveTableCell`, `CRPRightAlignedEditableTableCell`, `CRPNonBlueButtonTableCell`, `CRPInfoTableCell`, `CRPPresetSelectionCell`, `CRPMultiBackupContainerSelectionCell` | CONFIRMED_STATIC |
| SpringBoard container menu | App long-press / 3D Touch | `SBUIActionView` subclassing + `UIMenu` subclass | CORROBORATED |
| Badge action | App icon long-press | `CRBadgeAction : UIAction` | CONFIRMED_STATIC |
| Subtitle menu | container menu rows | `CRSubtitleMenu : UIMenu` | CONFIRMED_STATIC |
| Error alerts | SpringBoard | `CRErrorAlert`, `CRNewContainerAlert` (`SBAlertItem` subclasses) | CONFIRMED_STATIC |
| Activator entries | Activator | `CraneActivatorManager` | CONFIRMED_STATIC |
| Shortcut actions | Shortcuts | 5 intents (modern) / 1 (legacy) | CONFIRMED_STATIC |

## 2. Global visual system

| Property | Value | Evidence |
|---|---|---|
| Screen size / orientation | Settings renders in Settings' own containers | UNKNOWN |
| Status bar, nav bar, safe area | system-drawn by the Preferences framework | UNKNOWN |
| Typography | system font via `PSSpecifier` labels; Crane adds no font | UNKNOWN |
| Row heights | Preferences defaults except custom cells | UNKNOWN |
| Corner radii, borders | none recoverable; only `CRPDestructiveTableCell` is known to be styled differently | UNKNOWN |
| Separators | Preferences defaults | UNKNOWN |
| Dark mode | no `Appearance` keys, no `.dark` assets, no color assets anywhere in the package | INFERRED: follows the system automatically |
| Dynamic type | no evidence of `UIFontMetrics` or custom text styles | INFERRED: follows the system |
| Localization coverage | 10 languages for Crane UI; Settings itself is system-localized | CONFIRMED_STATIC |
| RTL support | none recoverable; Crane ships no `.lproj`-independent directionality handling | UNKNOWN |

**Dark mode deserves a specific note.** The package contains **no** `.colorset`,
`.imageset` with dark variants, `Info.plist` `UIUserInterfaceStyle`, or
`Appearance` key. That is consistent with the UI being entirely system-drawn,
which is the case for a Preferences-framework settings bundle. It is an
inference from absence, not a measurement.

## 3. Settings → Crane (root pane)

Source: `Root.plist` + `PreferenceLoader/Preferences/CranePrefs.plist`.
Cell kinds are the Preferences ones: `PSLinkListCell`, `PSSwitchCell`,
`PSButtonCell`, `PSGroupCell`, `PSLinkCell`.

| # | Group | Rows |
|---|---|---|
| 0 | — | `Crane` (`PSLinkCell`, icon `Icon.png`, `isController`) |
| 1 | `APPLICATIONS` | link to the applications list |
| 2 | `APP_SHORTCUTS` (footer `APP_SHORTCUT_DESCRIPTION`) | 6 switches |
| 3 | `NOTIFICATIONS` (footer `NOTIFICATIONS_SUPPORT_FOOTER`) | 2 switches |
| 4 | `REPLACE_WITH_SUGGESTIONS` | empty group; populates the suggestion cells |
| 5 | `BACKUP_RESTORE` | 2 buttons |
| 6 | `OTHER` (footer `© 2020-2024 Lars Fröder (opa334)`) | 1 button + 1 link |
| 7 | — | `CREDITS_AND_LICENSES` link |

### 3.1 The six `APP_SHORTCUTS` switches

| Label key | Prefs key | Default |
|---|---|---|
| `APP_SHORTCUT_ENABLED` | `applicationShortcutEnabled` | ON |
| `LAUNCH_APPLICATION_ON_CONTAINER_SELECTION` | `launchApplicationOnContainerSelectionEnabled` | OFF |
| `EXPAND_CONTAINERS_SHORTCUT` | `expandContainersShortcutEnabled` | OFF |
| `SHOW_NEW_CONTAINER_OPTION` | `newContainerShortcutEnabled` | ON |
| `ONLY_SHOW_IF_CONTAINERS_EXIST` | `onlyShowIfContainersExistEnabled` | ON |
| `SHOW_CONTAINER_NOTIFICATION_BADGES` | `showContainerNotificationBadgesEnabled` | ON |

`applicationShortcutEnabled` carries `nestedEntryCount = 5`, matching the 5
sub-toggles below it.

### 3.2 The `NOTIFICATIONS` group

| Label key | Prefs key | Default | Note |
|---|---|---|---|
| `NOTIFICATIONS_SUPPORT_ENABLED` | `notificationsSupportEnabled` | ON | `set = setNotificationsSupportEnabled:specifier:` — a bespoke setter, `nestedEntryCount = 1` |
| `SHOW_CONTAINER_IN_TITLE` | `showContainerInNotificationTitleEnabled` | ON | — |

### 3.3 Suggestions group

Empty in the plist; the suggestion cells are generated at runtime from
`CRPRootPageSuggestionProvider` and are driven by which optional components are
present. Four suggestion families are identifiable from the localization table:

| Suggestion | Shown when | Localization keys |
|---|---|---|
| Choicy | Choicy installed | `CHOICYLOADER_SUGGESTION_TITLE/MESSAGE`, `INJECTION_ERROR_MESSAGE_CHOICY` |
| libSandy | `libSandy_works()` false | `LIBSANDY_NOT_WORKING_ERROR_MESSAGE`, `LIBSANDY_CHOICY_NOTICE` |
| Shortcuts | the app is installed | `SHORTCUTS_INFO_SUGGESTION_TITLE/MESSAGE` |
| Activator | `libactivator.dylib` present | `ACTIVATOR_INFO_SUGGESTION_TITLE/MESSAGE` |

INFERRED from the string keys; the exact presentation is UNKNOWN.

### 3.4 `OTHER` group

| Label | Action | Note |
|---|---|---|
| "Crack by Repo BVN" | `openTwitter` | This build. Upstream ships `FOLLOW_ME_ON_TWITTER` = "Follow me on Twitter". The action still opens `twitter://user?screen_name=%@` and `https://twitter.com/%@`. |
| `CREDITS_AND_LICENSES` | link `CRPCreditsController` | — |

## 4. Applications list

Source: `Root.plist` row 1 + `CRPApplicationListSubcontrollerController`
(3 methods).

| Property | Value | Evidence |
|---|---|---|
| Detail controller | `CRPApplicationListSubcontrollerController` | CONFIRMED_STATIC |
| Sub-controller class | `CRPApplicationConfigurationListController` | CONFIRMED_STATIC |
| Section predicate | `crane_isSupported == YES`, `sectionType = Custom`, `sectionName = APPLICATIONS` | CONFIRMED_STATIC |
| Alphabetic indexing | ON (`alphabeticIndexingEnabled`) | CONFIRMED_STATIC |
| Search bar | ON (`useSearchBar`) | CONFIRMED_STATIC |
| Subtitles | `shouldShowSubtitles` returns YES; the subtitle comes from `subtitleForApplicationWithIdentifier:` | CONFIRMED_STATIC (the method names) |
| Preview string | `previewStringForApplicationWithIdentifier:` exists — the row has a right-hand preview value | CONFIRMED_STATIC (the method exists) |
| Row content | UNKNOWN — which of icon / name / subtitle / badge is shown per row was not recovered | UNKNOWN |

`shouldShowSubtitles` and `previewStringForApplicationWithIdentifier:` being
present means the list shows a subtitle line and a trailing preview value. That
is a structural fact; the content of either is UNKNOWN.

## 5. Per-application configuration pane

Source: `Root.plist` + `CranePrefs` 0x8D00. Row order and conditions are exact.

| # | Row | Key / value | Default | Conditional |
|---|---|---|---|---|
| 1 | `ACTIVE_CONTAINER` | `activeContainer`, detail `CRPActiveContainerListItemsController` | — | always |
| 2 | `ALWAYS_ASK_ON_APP_LAUNCH` | `alwaysAskBeforeLaunchEnabled` | — (`enabled = YES`) | always |
| 3 | group `CONTAINERS` | — | — | always |
| 4 | one row per container | per-container identifier | — | always |
| 5 | `ADD` | `addButtonPressed` | — (`enabled = YES`) | always |
| 6 | group + footer `SEPARATE_NOTIFICATION_REGISTRATIONS_FOOTER` | — | — | `notificationsSupportEnabled` unset **or** true |
| 7 | `SEPARATE_NOTIFICATION_REGISTRATIONS` | `separateNotificationRegistrationsEnabled` | `enabled = YES`, `default = YES` | same as 6 |
| 8 | group + footer `SEPARATE_SYSTEM_ACCOUNTS_FOOTER` | — | — | always |
| 9 | `SEPARATE_SYSTEM_ACCOUNTS` | `separateSystemAccountsEnabled` | `enabled = YES` | always |
| 10 | `GAME_CENTER_SUPPORT` | `gameCenterSupportEnabled` | `enabled = YES` | **appended only if row 9 is ON** |
| 11 | group + footer `CONTAINER_PROTECTION_FOOTER` | — | — | always |
| 12 | `CONTAINER_PROTECTION` | `containerProtectionEnabled` | `enabled = YES` | always |
| 13 | group + footer `PREVENT_SANDBOX_LOOKUPS_FOOTER` | — | — | always |
| 14 | `PREVENT_SANDBOX_LOOKUPS` | `spoofSandboxLookupsEnabled` | `enabled = YES` | always |

Two behavioural details worth calling out, both CONFIRMED_STATIC:

- **Rows 9, 10, 12 and 14 are `enabled = YES` but have no `default`.** That
  means the switch is drawn enabled (not greyed out) while its value comes
  straight from the stored per-app settings, which are `NO` when unset.
- **Row 10's asymmetry:** the specifier object is always constructed and cached
  in `self.gameCenterSupportEnabledSpecifier`, but is only added to the list when
  row 9 is on. This is why `setSeparateSystemAccountsValue:specifier:` must call
  `reloadSpecifier:` on that cached object — turning row 9 on can make row 10
  appear without a full pane rebuild.

Beyond row 14, `CRPContainerConfigurationListController` (60 methods) adds rows
for Game Center account assignment, device identifier, notifications and
keychain. Their labels exist in the localization table
(`GAME_CENTER_SECTION_HEADER`, `DEVICE_IDENTIFIER_DESCRIPTION`,
`NOTIFICATIONS_FOOTER`, `KEYCHAIN_MIGRATION`, …) but the row order and
conditions were not recovered. UNKNOWN.

## 6. Container configuration pane

`CRPContainerConfigurationListController` — 60 instance methods, the largest
class in `CranePrefs`. Recovered method names group it as:

| Group | Methods |
|---|---|
| Active container | `setActiveContainer:specifier:`, `readActiveContainer:`, `reloadActiveContainer`, `reloadContainerNames` |
| Container rows | `getSpecifiersForContainers`, `newSpecifierForContainerWithIdentifier:`, `containerNameForContainerIdentifier:`, `renameContainerWithIdentifier:toName:`, `removeContainerWithIdentifier:` |
| Add | `addButtonPressed` |
| Per-container toggles | `setSeparateNotificationRegistrationsValue:specifier:`, `setSeparateSystemAccountsValue:specifier:`, `setGameCenterSupportValue:specifier:`, `setPreferenceValue:specifier:` |
| Reads | `readPreferenceValue:`, `readPreferenceValueForKey:` |
| Table editing | `tableView:canEditRowAtIndexPath:`, `editingStyleForRowAtIndexPath:`, `canMoveRowAtIndexPath:`, `targetIndexPathForMoveFromRow:toProposedIndexPath:`, `moveRowAtIndexPath:toIndexPath:`, `commitEditingStyle:forRowAtIndexPath:`, `performDeletionActionForSpecifier:` |
| Integrity checks | `checkForUnknownContainers`, `checkForSlices`, `viewWillDisappear:` |

The table-editing group CONFIRMS that container rows are **reorderable** and
**deletable via swipe** (`editingStyleForRowAtIndexPath:` returning
`UITableViewCellEditingStyleDelete`, and `commitEditingStyle:` forwarding to
`performDeletionActionForSpecifier:`). Row order and edit-button visibility are
UNKNOWN.

## 7. Active Container sheet

Source: `CRPActiveContainerListItemsController` — 2 methods
(`applicationIdentifier`, `tableView:didSelectRowAtIndexPath:`), plus the
`valuesDataSource` / `titlesDataSource` wiring on the specifier.

| Property | Value | Evidence |
|---|---|---|
| Rows | one per container | CONFIRMED_STATIC |
| Row title | `containerNamesForApplication` | CONFIRMED_STATIC |
| Selection | `tableView:didSelectRowAtIndexPath:` sets the active container | CONFIRMED_STATIC |
| Active-row indicator | a checkmark | INFERRED — the asset `SelectedContainerCheckmark.png` exists and `REPLACE_WITH_SUGGESTIONS`-independent evidence is the presence of a dedicated checkmark asset |
| Row count includes `DEFAULT` | UNKNOWN — `containerIdentifiersOfApplication` may or may not include it | UNKNOWN |
| Empty state | UNKNOWN | UNKNOWN |
| Search | UNKNOWN | UNKNOWN |

## 8. Container selection menu (app long-press / 3D Touch)

Source: 17 `SBUIActionView` hooks + 1
`SBUIAppIconForceTouchControllerDataProvider` hook + 2 `UIMenu` initialiser
variants + `CRBadgeAction`/`CRSubtitleMenu`.

| Property | Value | Evidence |
|---|---|---|
| Entry points | `SBUIAppIconForceTouchControllerDataProvider.applicationShortcutItems` (iOS 14.0–15.x) and the `SBUIActionView` path (iOS 16+) | CONFIRMED_STATIC |
| Menu identifier | `com.opa334.crane.containers` | CONFIRMED_STATIC |
| Gate | `applicationShortcutEnabled` | CONFIRMED_STATIC |
| Row identifier | `com.opa334.crane-container.%@` | CONFIRMED_STATIC |
| "New Container" row | `com.opa334.crane.new-container-action`, gated by `newContainerShortcutEnabled` | CONFIRMED_STATIC |
| Separator row | `com.opa334.crane.separator`, `crane_isSeparator` | CONFIRMED_STATIC |
| Settings row | `com.opa334.crane.open-preferences` | CONFIRMED_STATIC |
| Expand submenu | `expandContainersShortcutEnabled`, `EXPAND_CONTAINERS_SHORTCUT` | CONFIRMED_STATIC |
| Hide for apps with no containers | `onlyShowIfContainersExistEnabled` | CONFIRMED_STATIC |
| Launch after selection | `launchApplicationOnContainerSelectionEnabled` | CONFIRMED_STATIC |
| Confirm before launch | `alwaysAskBeforeLaunchEnabled` → `SET_ACTIVE_CONTAINER_DESCRIPTION` = `Set Active Container to "%@"` | CONFIRMED_STATIC |
| Row layout, order, subtitle text, checkmark style | UNKNOWN | UNKNOWN (U-05) |
| Icon set | `ContainersIcon`, `AddIcon`, `SelectedContainerCheckmark`, `SettingsIcon` (@2x and @3x, byte-identical to the original) | CONFIRMED_STATIC |

The **menu is built by string identifier, not by class**, which makes those
identifiers part of the observable contract: an external Choicy configuration or
Shortcut that references `com.opa334.crane.new-container-action` would break if
the identifiers changed. They are reproduced verbatim in
`reconstruction/sources/common/CRPaths.h`.

## 9. Badge view

Source: `initCRBadgeContextMenuActionView` (0x7F58) — 3 hooks on
`SBApplicationIcon` (`updateConstraints`, `layoutSubviews`,
`valueForUndefinedKey:`) and 6 added properties
(`associatedApplicationID`, `badgeView`, `text`).

| Property | Value | Evidence |
|---|---|---|
| Badge text | per container, via `badgeCountStore*` | CONFIRMED_STATIC |
| Store | `/var/mobile/Library/Crane/BadgeStore.plist` | CONFIRMED_STATIC |
| Gate | `showContainerNotificationBadgesEnabled` | CONFIRMED_STATIC |
| Notification title prefix | `showContainerInNotificationTitleEnabled`; the container name comes from `containerNameToDisplayInNotificationWithUserInfoOrContext:ofApplicationWithIdentifier:` | CONFIRMED_STATIC |
| The badge view's constraints | UNKNOWN — `crane_updateConstraints` / `crane_rebuildConstraints` exist but the maths was not read | UNKNOWN |
| Whether the badge replaces or augments the stock icon badge | UNKNOWN | UNKNOWN |

## 10. Backup and restore UI

Source: 11 backup/restore controllers + `CRPBackupRestoreProgressAlertController`
(30 methods) + the localization table's status vocabulary.

### 10.1 Progress alert states

`setStatus:` drives the title; `setProcessedFile:`, `setProcessedContainer:`,
`setProcessedIdentifier:`, `setTotalSuboperationsCount:`,
`setCurrentSuboperationIndex:`, `setAmountOfOperations:`,
`setCurrentOperationIndex:` drive the body; `setShowsCancelButton:` /
`showsCancelButton` / `cancelHandler` control the cancel button;
`updateAlertContent` / `updateAlertContentOnMainThread` / `updateProgress` /
`updateProgressOnMainThread` are the refresh pair (main-thread dispatch is
explicit in the method names).

Recovered status vocabulary, from `status`-related localization keys:

| State key | Meaning |
|---|---|
| `PREPARING` | enumerating |
| `BACKING_UP` | writing |
| `UNARCHIVING` | reading |
| `RESTORING` | applying |
| `CHECKING` | validating |

| Terminal key | Meaning |
|---|---|
| `SUCCESS` + `RESTORE_SUCCESS_MESSAGE` / `MULTI_RESTORE_SUCCESS_MESSAGE` | done |
| `BACKUP_ERROR`, `RESTORE_ERROR`, `BACKUP_INVALID` | failure |
| `BACKUP_NOT_ENOUGH_FREE_SPACE_ERROR`, `RESTORE_NOT_ENOUGH_FREE_SPACE_ERROR` | refused, with the required size interpolated as `%@` |
| `APP_ID_MISMATCH_ERROR` | refused — the source app's identifier differs from the target's |
| `GROUP_ID_MISMATCH_WARNING` | warned, proceedable |
| `NOT_A_BACKUP_ERROR_MESSAGE`, `NOT_A_MULTI_CONTAINER_BACKUP_ERROR_MESSAGE` | wrong file |
| `NO_APPS_INSTALLED_ERROR` | none of the backup's apps are installed |
| `NO_PASSWORD_ERROR` | encryption on, password empty |
| `PREVIOUS_PASSWORD_WRONG_MESSAGE` | wrong password, retryable |
| `RESTORE_WARNING_MESSAGE` | overwrite confirmation |
| `SEP_ITEMS_OMMITED_WARNING_MESSAGE` | secure-enclave items omitted |
| `LITE_IMPORT_MESSAGE` / `LITE_IMPORT_TITLE` | Crane Lite containers found |
| `SLICES_FOUND_MESSAGE` | slices found for the selected app |
| `UNKNOWN_CONTAINERS_FOUND_MESSAGE` | orphan directories found |

### 10.2 Options

| Option | Key | Notes |
|---|---|---|
| Encrypt backup | `encryptBackupEnabled` | `ENABLE_ENCRYPTION`, `PASSWORD`, `CONFIRM_PASSWORD`, `PROTECT_USING_BIOMETRICS`; footers warn that a lost password means lost data |
| Include keychain | `includeKeychainEnabled` | `INCLUDE_KEYCHAIN_FOOTER` warns it is unsafe unencrypted |
| Presets | `presets` (per-app) | `PRESETS`, `NEW_PRESET`, `NEW_PRESET_MESSAGE`, `SAVE_SELECTION_INTO_PRESET`, `INCLUDED_CONTAINERS` |

### 10.3 Unknown

Row order, field order, per-row validation, and the archive layout are all
UNKNOWN (U-06). `CRPBackupOperation` (41 methods) and `CRPNewBackupListController`
(42 methods) exist in the export and would resolve most of this by reading.

## 11. Credits and licenses

Source: `Credits.plist`. 24 buttons and 2 links.

| Item | Detail |
|---|---|
| ZipArchive | button `zipArchiveLink` (→ `https://github.com/ZipArchive/ZipArchive`) + link `CRPCreditsZipArchiveController` (`ZipArchiveLicense.plist`) |
| MiniZip | button `miniZipLink` (→ `https://github.com/nmoinvaz/minizip`) + link `CRPCreditsMiniZipController` (`MiniZipLicense.plist`) |
| 11 localization credits | grouped by language: vi, zh_CN, zh_TW, ar, ru, he, pt_BR, tr, fr, de |

The Credits pane also carries an `OPEN_REPO` entry → `https://opa334.github.io`
(seen in `CranePrefs` strings at 0x21AC0).

All credit button labels are literal handles (`@Trithuc16`, `@nvbik584`,
`@Sn0wl3r0ker`, `@Torrekie`, `@CySxL`, `@nzar1988`, `@BwntyHntr`,
`@Vitalik2187836`, `@guezomri`, `@ian_dxx`, `rdaraujo`, `@frknvkilic`,
`@RedenticDev`). CONFIRMED_STATIC.

## 12. Error alerts

Source: `InitFunc_0` (0x9684) and `InitFunc_1` (0x9E08).

### `CRErrorAlert : SBAlertItem`

Properties: `errorTitle` (`NSString`), `errorMessage` (`NSString`),
`actions` (`NSArray`), `crane_reappearsAfterUnlock` (`BOOL`).
Hooks: `configure:requirePasscodeForActions:` and `reappearsAfterUnlock`.

### `CRNewContainerAlert : SBAlertItem`

Properties: `applicationID` (`NSString`).
Hook: `configure:requirePasscodeForActions:`.

| Behaviour | Value | Evidence |
|---|---|---|
| Presentation | via `SBAlertItem`'s SpringBoard alert flow | CORROBORATED |
| Passcode requirement | supported (the hook exists) — whether any error alert actually sets it is UNKNOWN | CONFIRMED_STATIC (mechanism) |
| Reappear after unlock | supported via `crane_reappearsAfterUnlock` | CONFIRMED_STATIC |
| Which alerts exist | 5 `crane_present*` methods on `UNSUserNotificationServerConnectionListener` | CONFIRMED_STATIC |
| Alert text and button layout | keys exist in the localization table; exact strings recovered | CONFIRMED_STATIC |
| Alert title | `CRANE_ERROR`, `BACKUP_ERROR`, `RESTORE_ERROR`, `WARNING`, `ERROR` | CONFIRMED_STATIC |

## 13. Resource inventory (UI)

| Path | Contents | SHA-256 recorded |
|---|---|---|
| `Crane.bundle/Icons/AddIcon@{2,3}x.png` | "add container" glyph | `analysis/package_inventory.md` |
| `Crane.bundle/Icons/ContainersIcon@{2,3}x.png` | "containers" row icon | same |
| `Crane.bundle/Icons/SelectedContainerCheckmark@{2,3}x.png` | active-container checkmark | same |
| `Crane.bundle/Icons/SettingsIcon@{2,3}x.png` | settings row icon | same |
| `Crane.bundle/{ar,de,en,fr,he,pt_BR,ru,tr,vi,zh_CN,zh_TW}.lproj/Localizable.strings` | 204 keys (en) | same |
| `CranePrefs.bundle/Icon@{2,3}x.png` | Settings entry icon | same |
| `CranePrefs.bundle/{Root,Credits,ZipArchiveLicense,MiniZipLicense}.plist` | pane definitions | same |
| `CraneApplication.app/Assets.car` | app icon set | same |
| `Applications/*/Base.lproj/{Main,LaunchScreen}.storyboardc` | Xcode template scenes, no Crane UI | same |

All 10 loose PNGs are reused **byte-identically** in the reconstruction. No
vector assets, no colour assets, no font files, no `.stringsdict` (so **no
pluralisation rules** — an observable gap for any row whose count varies, such as
`SLICES_FOUND_MESSAGE` with `%u`).

## 14. Summary of what is and is not known

| Aspect | Known | Unknown |
|---|---|---|
| Screen inventory | 14 surfaces, all named | — |
| Row labels and their localization keys | all 204 keys recovered | — |
| Row order in the settings panes | exact for root and per-application | container pane beyond row 14; backup panes |
| Conditional visibility rules | exact for all 6 global-gated rows | — |
| Defaults | exact for all 8 global switches | per-app keys without a `default` (inferred NO) |
| Artwork | 10 PNGs, byte-identical | pixel dimensions, intended sizes |
| Icons used per row | partially (containers/add/checkmark/settings exist) | which row uses which icon |
| Typography, colours, insets, sizes | nothing | everything |
| Menu layout | identifiers and gates | arrangement |
| Alert layout | mechanism and text | arrangement |
| Dark mode | inferred: follows the system | — |
| Localization | 10 languages, 204 keys, no `.stringsdict` | translation completeness per language |