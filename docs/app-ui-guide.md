# Working on the Ebb iPhone app UI

The app is SwiftUI, in `app/`. You can restyle any screen freely; the data and
server logic live in `AppModel.swift` and should not need to change.

## 1. Get the code (once)

You need a Mac with Xcode 26 and access to the GitHub repo `jzps333/ebb`
(accept the collaborator invite email first, or ask Vineet to resend it).

```bash
git clone https://github.com/jzps333/ebb.git
cd ebb
open app/Ebb.xcodeproj
```

Xcode downloads the Supabase package the first time (a minute or two).

## 2. Run it

1. Xcode, top bar: pick an iPhone simulator, or plug in your iPhone.
2. Click the **Ebb** project in the left sidebar, then target **Ebb** >
   **Signing & Capabilities** > **Team**: pick your own Apple ID
   (Xcode > Settings > Accounts to add it). If it complains about the bundle
   id, change `com.jzps333.ebb` to something like `com.yourname.ebb`
   **locally only** (don't commit that change).
3. Press **Run** (the play button). On a real iPhone, the first time you need
   Developer Mode on (Settings > Privacy & Security) and to trust your Apple ID
   (Settings > General > VPN & Device Management).
4. Log in with the demo accounts (ask Vineet for the password):
   `parent.demo@ebb.test` or `teacher.demo@ebb.test`.

## 3. Where each screen is

| File | Screen |
|---|---|
| `app/Ebb/LoginView.swift` | Sign in / create account |
| `app/Ebb/HomeView.swift` | Child cards: watch status, Start calm / Stop, today's summary, alert banner |
| `app/Ebb/PairView.swift` | Scan the watch QR, pick or add a child |
| `app/Ebb/QRScannerView.swift` | Camera scanner (rarely needs styling) |
| `app/Ebb/AssessmentView.swift` | The calm-profile questions |
| `app/Ebb/CalmProfileView.swift` | Profile preview with the breathing circle, Approve |
| `app/Ebb/VoiceView.swift` | AI voice / record own voice, phrases, approve clips |
| `app/Ebb/EbbApp.swift` | App start, error popup |

**Check with Vineet before changing:** `AppModel.swift` (all server calls),
`Models.swift` (must match the database), `Config.swift`, `project.yml`.
If `project.yml` changes, run `xcodegen generate` (`brew install xcodegen`).

## 4. Seeing changes fast

- **Canvas preview:** open a screen file, then Editor > Canvas (Option-Cmd-Return).
- Screens read live data from `AppModel`, so a preview needs sample data;
  ask if you want preview data added.
- Otherwise just Run on the simulator or phone after each change.

## 5. Sharing your work without clashing

```bash
git checkout -b ui-redesign        # your own branch
# ...edit, run, check...
git add app/Ebb
git commit -m "Restyle home and login screens"
git push -u origin ui-redesign
```

Then open a Pull Request on GitHub into `main`. Pull `main` before you start
each session (`git pull origin main`) and avoid editing the same file as
someone else at the same time.
