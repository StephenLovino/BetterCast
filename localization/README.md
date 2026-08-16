# Localization

BetterCast's macOS app follows the system language. UI strings live in
`localization/<code>.lproj/Localizable.strings`; `make_app.sh` copies these
folders into `BetterCast.app/Contents/Resources`, where both SwiftUI's
automatic `LocalizedStringKey` lookup and the `tr()` helper
(`Sources/BetterCastSender/Constants.swift`) resolve them via `Bundle.main`.

## Current languages

| Code | Language |
|---|---|
| `en` | English (source of truth — every key lives here) |
| `zh-Hans` | Simplified Chinese |
| `ja` | Japanese |
| `ko` | Korean |
| `de` | German |
| `fr` | French |

## Contributing a translation

1. Copy `en.lproj/Localizable.strings` to `<code>.lproj/Localizable.strings`
   (ISO 639-1 code, e.g. `es`, `it`, `pt-BR`).
2. Translate only the right-hand values. **Keys must stay byte-identical to the
   English source** — they are the lookup keys used by the app.
3. Keep format placeholders (`%@`, `%lld`, `%.1f`) intact and in the same order.
4. Keep "BetterCast" and technical terms (USB, ADB, TCP, HiDPI, Mbps, FPS…)
   untranslated unless your language has an established convention.
5. Validate: `plutil -lint <code>.lproj/Localizable.strings` must print `OK`.
6. Add the language code to `CFBundleLocalizations` in
   `BetterCastSender-Info.plist`, and to the table above.
7. Open a pull request.

## Updating an existing language

When new UI strings land, they are added to `en.lproj` first. Untranslated keys
simply fall back to English at runtime, so partial translations never break the
app — but PRs topping up missing keys are very welcome. To find them, diff the
key sets:

```sh
grep -o '^"[^"]*"' localization/en.lproj/Localizable.strings | sort > /tmp/en.keys
grep -o '^"[^"]*"' localization/ja.lproj/Localizable.strings | sort > /tmp/ja.keys
comm -23 /tmp/en.keys /tmp/ja.keys   # keys missing from ja
```

## For developers: adding new UI strings

- String literals inside SwiftUI views (`Text("…")`, `Button("…")`,
  `Toggle("…")`, `.navigationTitle("…")`, …) localize automatically — just add
  the English literal as a key to every `.lproj` file.
- Strings in plain `String` contexts (status variables, enum display names,
  `NSWindow.title`, anything built outside a SwiftUI view initializer) do NOT
  auto-localize: wrap them with `tr("…")` (or `tr("… %@ …", arg)` for
  interpolation), then add the key to the `.lproj` files.
- Testing a language without changing your system:
  `defaults write com.bettercast.sender AppleLanguages '(ja)'` (and delete the
  key afterwards), or run the app with `-AppleLanguages "(ja)"`.

Not localized on purpose: release-note highlights in the "What's New" section
(`LogManager.swift`), log output, and the mostly-numeric resolution names.
