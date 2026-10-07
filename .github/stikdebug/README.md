# StikDebug for visionOS that closes itself

[StikDebug for visionOS](https://github.com/rebelancap/StikDebug-visionos) by
[rebelancap](https://github.com/rebelancap) (based on [StikDebug](https://github.com/StikDebug/StikDebug)),
built with one change: StikDebug's own *quit after enabling JIT* option
(`autoQuitAfterEnablingJIT`, which the app has no switch for) is on. When AstroQuest asks for JIT,
StikDebug runs the script, waits for AstroQuest to say it is done, and closes; AstroQuest keeps its
executable memory.

- `autoquit.patch` is the whole change, applied to the commit named in
  `.github/workflows/stikdebug-visionos.yml`.
- It is built with the bundle identifier of the original StikDebug, `com.stik.stikdebug`.
- The unsigned app is in the release `stikdebug-visionos` (`StikDebug-visionOS-autoquit.ipa`).

StikDebug is AGPL-3.0; this patch is under the same license.
