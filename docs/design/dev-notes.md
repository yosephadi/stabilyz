# Dev notes — resetting app state

Notes for developing against the simulator. Nothing here describes shipped
behaviour; the in-app reset exists only in DEBUG builds.

## What "a user exists" actually means

`AppRouter.resolve()` derives the launch phase from stored state alone — there
is no "has onboarded" flag. Two artifacts decide it, and **both** have to go to
get back to Welcome:

| State | Location in the app container | Written by |
|---|---|---|
| Profile | `Library/Application Support/default.store` (+ `-wal`, `-shm`) | SwiftData |
| Onboarding draft | `Library/Preferences/com.adi.Stabilyz.plist`, key `com.stabilyz.onboarding.draft` | `UserDefaultsOnboardingDraftStore` |

Clearing only the store leaves the draft behind, and the app resumes the wizard
mid-flow instead of showing Welcome.

Deleting `default.store` on its own is **not** a reset: SQLite replays the
`-wal` sidecar on next open. Any file-level delete takes all three.

## Resetting from the command line

Bundle id is `com.adi.Stabilyz`. `booted` targets the running simulator; swap in
a UDID from `xcrun simctl list devices` if more than one is up.

### Full reset — the default

```
xcrun simctl uninstall booted com.adi.Stabilyz
```

Removes the app and its whole container, so the store and the preferences plist
go together. Press **Cmd+R** in Xcode afterwards to reinstall and land on
Welcome.

Use this unless you have a reason not to. It is the only one of the three that
cannot leave a half-cleared state.

### Container wipe — keep the app installed

```
xcrun simctl terminate booted com.adi.Stabilyz
rm -rf "$(xcrun simctl get_app_container booted com.adi.Stabilyz data)"/{Library,Documents}/*
```

For when reinstalling is inconvenient — a long build, or an attached debugger
you want to keep. Terminate first: `cfprefsd` caches preferences and will write
the draft back out from memory if the app is still running.

### Draft only — keep the profile

```
xcrun simctl spawn booted defaults delete com.adi.Stabilyz
```

Clears the onboarding draft and leaves the store alone. This is the one for
testing resume behaviour — quit mid-wizard, clear the draft, confirm the next
launch starts over rather than resuming.

## Resetting from inside the app

Five taps on the **Home** title erases everything and returns to Welcome.

DEBUG builds only, no confirmation, no recovery. It clears the store and the
app's whole `UserDefaults` domain, then re-resolves the router — the phase is a
function of stored state, so reading the emptied store is what proves the reset
worked.

- `Debug/DebugResetGesture.swift` — the gesture. Lives outside `Features/`
  deliberately, so it sits outside the design-token and terminology scans that
  exist for user-facing UI.
- `Persistence/DebugDataReset.swift` — the erase, in the layer allowed to import
  SwiftData.
- `DebugIsolationGuardTests` — holds that both files are wrapped in `#if DEBUG`
  and that no release code names their symbols.

Home is still `RootPlaceholder` until Task 8.3.1; the gesture moves with it.

### One thing not to reach for

`ModelContainer.deleteAllData()` is the obvious one-liner and does not work
here. Against a container whose `@ModelActor`s already hold live contexts —
which is any running app that has read a profile once — it crashes the process.
`StoreWriter.eraseAllData()` deletes through the store's normal write path
instead, which is why a reset is visible to `StoreReader` immediately.
