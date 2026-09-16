# Matrix 3D X

Matrix rain + rotating 3D object as a macOS screensaver, in Swift/Metal.
Universal Binary (Intel + Apple Silicon). Primary testing on Intel Mac.

Current release: **1.0 (29)**.

*[Deutsche Version weiter unten](#matrix-3d-x-deutsch)*

## Download

Pre-built, notarized release (macOS 13+):

**[Matrix3DSaverX.dmg](https://github.com/R8lle/macos-screensaver3dx/releases/latest)** — double-click the `.saver` inside, choose
"Install for me" or "Install for all users", then select **Matrix 3D X** in
**System Settings → Screen Saver**.

## Scope

Developed in stages: (1) core (rain + one rotating object), (2) multiple
models + full options UI + multi-monitor, (3) volumetric 3D rain + physics
characters, (4) custom 3D text, (5) GLB/USDZ import. All phases complete.

### Done

- Xcode project (`Matrix3DSaverX.xcodeproj`, generated from `project.yml`
  via [XcodeGen](https://github.com/yonaskolb/XcodeGen)) as a real `.saver`
  bundle target.
- Matrix rain (screen-space, katakana/alphanumeric character set) as a
  Metal renderer.
- Three bundled 3D models (R@lle logo, spaceship, Utah teapot) via
  ModelIO/MetalKit — including multi-material classification
  (chrome/flat-colored/textured per submesh, detected from material names)
  and texture loading from the `.mtl`.
- A real `.metal` shader file (`Shaders/Shaders.metal`, including
  chrome/color/textured mesh variants) instead of a string compiled at
  runtime — Xcode checks syntax/types at build time.
- Full options UI: screen selection + "Reset" (multi-monitor overrides),
  variant, model, rain/physics/speed sliders, tilt + rotation axes per
  axis, static axis diagram.
- Multi-monitor scoping (every setting overridable per monitor, otherwise
  falls back to "All Screens"). The options dialog ALWAYS starts at "All
  Screens" and never auto-preselects the caller's monitor -- avoids an
  unnoticed single-screen scope when opened from the real full-screen
  instance.
- Volumetric 3D rain (`WorldRain.swift`): camera-facing billboards with
  real world depth (`glyph3d_vs` in `Shaders/Shaders.metal`), rendered
  additively and depth-tested against the object (rain behind the object
  is correctly occluded). For "Matrix 3D (with object)"/"Matrix 3D (rain
  only)"; the "Matrix Rain (2D)" variant deliberately stays with the flat
  screen-space rain (`MatrixRainSimulation`).
- Physics characters (`PhysicsField.swift`): a bounded character pool
  falls under gravity, bounces off the object surface, and slides down the
  slope as the tilt increases, until it falls out of frame at the bottom.
  Collision runs through a dedicated Metal compute raycaster
  (`GpuRaycaster.swift` + `raycast_kernel` in `Shaders/Shaders.metal`)
  against the triangles of whichever model is loaded (read directly from
  its already-loaded rendering mesh, no second OBJ parser needed). Only
  active for "Matrix 3D (with object)" -- with no visible object there's
  nothing to land on. Visually verified: characters visibly accumulate on
  the object surface, clearly distinguishable from the falling background
  rain.
- Custom 3D text (`TextMeshGenerator.swift`): arbitrary text is turned at
  runtime into an extruded 3D model from a TrueType font (Core Text
  supplies the glyph outlines as `CGPath`) -- caps (chrome material) + side
  walls (blue base material), cached in Application Support. Triangulation
  of the caps (including hole letters like B/8/@/%) is a **custom**
  ear-clipping implementation with hole-stitching via bridge edges
  (`EarClipTriangulator.swift`) -- deliberately without an external
  package. A lesson learned worth flagging: the stitched-together polygon
  inevitably contains duplicate bridge points; a naive ear test then
  discards large parts of the cap (details in the file comment of
  `EarClipTriangulator.swift`). Result after verification: no missing cap
  surfaces, no overlaps, visually clean including all hole letters
  (B/a/8/g/e/Q/@/%).

- GLB import (`GlbMesh.swift`): a user-chosen .glb file is converted at
  runtime into a cached OBJ+MTL -- the binary GLB container is parsed
  entirely by hand (Foundation: Data/JSONSerialization, no external
  package; ModelIO can't natively handle glTF/GLB). Includes edge-case
  handling: KHR_materials_pbrSpecularGlossiness fallback, external/data:
  URI textures. Verified against a complex test file (moon.glb): correct
  vertex/UV/face counts, no geometry errors.
- USDZ import (`UsdzImport.swift`): .usdz/.usd/.usda is loaded natively by
  ModelIO (MDLAsset); attribute domains are only unified where needed,
  textures come from the MDLTexture or, via a mini ZIP reader, directly
  out of the USDZ archive (ModelIO's "file.usdz[inner/path]" syntax). USD
  UVs (origin bottom-left) are flipped to glTF convention for the shared
  pipeline.
- Real PBR shading for both (`MeshAtlas.swift` + the `mesh_pbr_fs` shader
  in `Shaders.metal`) -- considerably more detailed than a blanket
  chrome/non-chrome triangle split based on metalness/roughness MASKS:
  every material gets four shared texture atlases (BaseColor,
  Occlusion/Roughness/Metallic, Emissive, Normal -- the same cell layout
  for all four) and is shaded PER PIXEL via Cook-Torrance/GGX, including
  tangent generation (`MDLMesh.addTangentBasis`) for real normal mapping.
  Triggered by a visible bug in the old approach: on a multi-material
  spaceship, whole parts (engine nacelles) incorrectly flipped entirely
  into the uniform chrome shader and lost both texture AND color --
  immediately visible in a side-by-side comparison with Xcode's own
  (native, physically correct) USD preview. A further correction was still
  needed: some asset packs (moon/Mars photo textures) supply a high
  `metallicFactor` for completely non-metallic surfaces AND a low-contrast,
  more AO-like metallic texture -- without a cross-check
  (`MeshAtlas.channelHasRealContrast`), the per-pixel shading would
  incorrectly make such surfaces look glossy-metallic (verified via a
  SceneKit reference render of Apple's own PBR pipeline: a comparable moon
  asset stays completely matte there).
- Shared building blocks in `MeshAtlas.swift`: atlas layout computed once
  and reused for all four textures, UVs are remapped per FACE corner
  (including seam-unwrapping `unwrapTriangleUV` against triangles smeared
  across texture seams). File selection in the options dialog uses a
  security-scoped bookmark, so the sandboxed screensaver process can still
  read the file later.
- Process-wide mesh cache (`TeapotMesh.cached`): macOS re-instantiates the
  preview view in System Settings on practically every interaction --
  without a cache, every instance of a large imported model would have
  cost 1-2 seconds of re-parsing (a noticeably sluggish preview).

### Added afterward

- The anti-leak exit (deliberately restarting the process after it stops):
  `legacyScreenSaver.appex` generally does not reliably release processes
  after Settings previews (a ViewBridge-hosting quirk of macOS itself) --
  confirmed via diagnostics (see `Matrix3DSaverView.swift`: heartbeat for
  the external `legacyss-cleanup` watchdog, `willstop`/`didstop`
  observation + delayed `exit(0)`).
- Also added: single-display detection (`ScreenRegistry.isSingleDisplay()`),
  instance retirement without an infinite loop (`retireSilently()`),
  thumbnail placeholder size, plus a process-wide sheet-pause mechanism
  (multiple instances in the same process must pause while an options
  sheet is open, otherwise the host stops presenting any further sheet).

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
`project.yml` ships with placeholder Team IDs and bundle identifiers. For a
signed release, copy `tools/local-signing.env.example` to
`tools/local-signing.env` (gitignored) and fill in your Developer ID team
and bundle id. For an unsigned local build, append
`CODE_SIGNING_ALLOWED=NO` to the `xcodebuild` commands below.

```sh
xcodegen generate   # generates/updates Matrix3DSaverX.xcodeproj from project.yml
```

### Release (maintainers)

Full signed + notarized release in one step:

```sh
./tools/release.sh
```

Builds the `.saver`, submits it to Apple Notary Service, staples the ticket,
creates a versioned DMG, notarizes and staples the DMG, and bumps the build
number in `project.yml`. Requires `tools/local-signing.env` and a stored
notarytool keychain profile (see `tools/release.sh`).

### Legacy `.saver` (kept in parallel)

```sh
xcodebuild -scheme Matrix3DSaverX -configuration Release -derivedDataPath build/DerivedData build
```

### Appex (host app + extension, macOS 14+)

```sh
xcodebuild -scheme Matrix3DSaverXApp -configuration Debug -derivedDataPath build/DerivedData build
```

After changes to `project.yml`, `xcodegen generate` must be run again.

## Installing/Testing

### `.saver`

```sh
cp -R build/DerivedData/Build/Products/Debug/Matrix3DSaverX.saver ~/Library/Screen\ Savers/
```

### Appex

Pick **one** install source (DerivedData **or** `/Applications`, never
both — otherwise `pluginkit` stays stuck on the old path):

```sh
# Recommended for testing: copy to /Applications once
cp -R build/DerivedData/Build/Products/Debug/Matrix3DSaverX.app /Applications/
open -a /Applications/Matrix3DSaverX.app   # Install button, or:
pluginkit -a /Applications/Matrix3DSaverX.app/Contents/PlugIns/Matrix3DSaverXExtension.appex
```

Afterward it shows up under **System Settings → Screen Saver** as
**Matrix 3D X**. Console filter:

```
subsystem:de.r8lle.screensaver.matrix3dx
```

The Appex extension's prefs use
`de.r8lle.screensaver.matrix3dx.app.Extension` (one-time migration from the
old `.saver` module `de.r8lle.screensaver.matrix3dx`). Private ScreenSaver
API — Developer ID/notarization possible, no Mac App Store. `killall`/
anti-leak `exit(0)` is not needed for Appex (its own extension process).

## Sample models

`SampleModels/` contains three demo assets (Earth.usdz, mastertux-cpu-311.glb,
spaceship/spaceship.usdz) for trying out the custom GLB/USDZ import in the
options dialog ("Custom GLB file"/"Custom USDZ file") without needing your
own 3D model on hand.

## Known limitation: monitor arrangement above/below

If an external monitor is placed ABOVE or BELOW the built-in display in the
screen arrangement, it stays black in the real screensaver. The cause is a
Y-coordinate bug in Apple's host (legacyScreenSaver.appex places the
full-screen window using an unconverted CG Y coordinate, off into
nowhere); not fixable from within the saver process (details in the
comment in `Sources/Matrix3DSaverView.swift`). Appex can mitigate this host
problem, but Apple-side dual-monitor bugs may partially persist regardless.

**Workaround:** arrange the external monitor to the LEFT or RIGHT of the
built-in display in System Settings -- then everything works.

## Known limitation: Options button only works once per Settings session

Clicking **Options...** in System Settings → Screen Saver opens the options
sheet the first time; a second click does nothing until System Settings is
fully quit and reopened. This is a documented Apple bug in the
`legacyScreenSaver.appex` hosting layer itself, not something this app
controls — `configureSheet` (`Sources/Matrix3DSaverView.swift`) builds a
fresh sheet on every call with no internal lock of its own, but the host
sometimes simply never invokes it a second time. Reported by multiple
third-party screensaver developers across macOS Ventura through Tahoe
(Apple Feedback FB10103112, FB17895600; see also the
[Aerial screensaver issue tracker](https://github.com/JohnCoates/Aerial/issues/1250)
and the [Apple Developer Forums thread on Sonoma screensaver instability](https://developer.apple.com/forums/thread/738547)).

**Workaround:** fully quit and reopen System Settings between Options
sessions.

---

# Matrix 3D X (Deutsch)

Matrix-Regen + rotierendes 3D-Objekt als macOS-Bildschirmschoner, in
Swift/Metal.
Universal Binary (Intel + Apple Silicon). Primaer getestet auf Intel-Mac.

Aktuelles Release: **1.0 (29)**.

## Download

Fertiges, notarisiertes Release (macOS 13+):

**[Matrix3DSaverX.dmg](https://github.com/R8lle/macos-screensaver3dx/releases/latest)** — `.saver` per Doppelklick oeffnen,
"Nur fuer mich" oder "Fuer alle Benutzer" waehlen, dann **Matrix 3D X** unter
**Systemeinstellungen → Bildschirmschoner** auswaehlen.

## Umfang

Schrittweise entwickelt: (1) Kern (Regen + ein rotierendes Objekt), (2)
Mehrfachmodelle + volle Options-UI + Mehrfachbildschirm, (3) volumetrischer
3D-Regen + Physik-Zeichen, (4) eigener 3D-Text, (5) GLB-/USDZ-Import. Alle
Phasen abgeschlossen.

### Fertig

- Xcode-Projekt (`Matrix3DSaverX.xcodeproj`, per [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  aus `project.yml` erzeugt) als echtes `.saver`-Bundle-Target.
- Matrix-Regen (Bildschirmraum, Katakana/alphanumerischer Zeichensatz) als
  Metal-Renderer.
- Drei mitgelieferte 3D-Modelle (R@lle-Logo, Raumschiff, Utah-
  Teekanne) via ModelIO/MetalKit — inkl. Multi-Material-Klassifizierung
  (chrom/einfarbig/texturiert je Submesh, an Materialnamen erkannt) und
  Textur-Laden aus dem `.mtl`.
- Echte `.metal`-Shader-Datei (`Shaders/Shaders.metal`, inkl. Chrom-/Farb-/
  Textur-Mesh-Varianten) statt zur Laufzeit kompiliertem String — Xcode
  prueft Syntax/Typen beim Build.
- Volle Options-UI: Bildschirm-Auswahl + "Zuruecksetzen" (Mehrfachbildschirm-
  Overrides), Variante, Modell, Regen-/Physik-/Geschwindigkeits-Regler,
  Neigung + Rotations-Achsen je Achse, statisches Achsen-Diagramm.
- Mehrfachbildschirm-Scoping (jede Einstellung pro Monitor ueberschreibbar,
  faellt sonst auf "Alle Bildschirme" zurueck). Der Options-Dialog startet
  IMMER bei "Alle Bildschirme" und waehlt nie automatisch den Monitor des
  Aufrufers vor -- vermeidet einen unbemerkten Einzelbildschirm-Scope beim
  Oeffnen von der echten Vollbild-Instanz aus.
- Volumetrischer 3D-Regen (`WorldRain.swift`): kamera-ausgerichtete
  Billboards mit echter Welttiefe (`glyph3d_vs` in `Shaders/Shaders.metal`),
  additiv gerendert und mit Tiefentest gegen das Objekt (Regen hinter dem
  Objekt wird korrekt verdeckt). Fuer "Matrix 3D (mit Objekt)"/"Matrix 3D
  (nur Regen)"; die Variante "Matrix Rain (2D)" bleibt bewusst beim flachen
  Bildschirmraum-Regen (`MatrixRainSimulation`).
- Physik-Zeichen (`PhysicsField.swift`): ein begrenzter Zeichen-Pool faellt
  unter Schwerkraft, prallt an der Objekt-Oberflaeche ab und rutscht bei
  zunehmender Neigung den Hang hinab, bis es unten aus dem Bild faellt.
  Kollision laeuft ueber einen eigenen Metal-Compute-Raycaster
  (`GpuRaycaster.swift` + `raycast_kernel` in `Shaders/Shaders.metal`) gegen
  die Dreiecke des jeweils geladenen Modells (direkt aus dessen bereits
  geladenem Rendering-Mesh gelesen, kein zweiter OBJ-Parser noetig). Nur
  bei "Matrix 3D (mit Objekt)" aktiv -- ohne sichtbares Objekt gibt es
  nichts zum Landen. Visuell verifiziert: Zeichen sammeln sich sichtbar
  auf der Objekt-Oberflaeche an, deutlich unterscheidbar vom fallenden
  Hintergrundregen.
- Eigener 3D-Text (`TextMeshGenerator.swift`): beliebiger Text wird zur
  Laufzeit aus einer TrueType-Schrift (Core Text liefert die Glyphenkonturen
  als `CGPath`) zu einem extrudierten 3D-Modell -- Deckel (Chrom-Material) +
  Seitenwaende (blaues Grundmaterial), gecacht in Application Support. Die
  Triangulierung der Deckel (inkl. Loch-Buchstaben wie B/8/@/%) ist eine
  **eigene** Ohren-Abschneide-Implementierung mit Loch-Einnaehen per
  Bruecken-Kante (`EarClipTriangulator.swift`) -- bewusst ohne externes
  Package. Achtung, gelernte Lektion: das zusammengenaehte Polygon enthaelt
  zwangslaeufig doppelte Brueckenpunkte; ein naiver Ohr-Test verwirft dann
  grosse Deckel-Teile (Details im Datei-Kommentar von
  `EarClipTriangulator.swift`). Ergebnis nach Verifikation: keine fehlenden
  Deckelflaechen, keine Ueberlappungen, visuell sauber inkl. aller
  Loch-Buchstaben (B/a/8/g/e/Q/@/%).

- GLB-Import (`GlbMesh.swift`): eine vom Nutzer gewaehlte .glb-Datei wird
  zur Laufzeit in ein gecachtes OBJ+MTL konvertiert -- der binaere GLB-
  Container wird dabei komplett selbst geparst (Foundation:
  Data/JSONSerialization, kein externes Package; ModelIO kann kein
  glTF/GLB nativ). Inklusive Edge-Case-Behandlungen:
  KHR_materials_pbrSpecularGlossiness-Fallback, externe/data:-URI-Texturen.
  Verifiziert an einer komplexen Testdatei (moon.glb): korrekte
  Vertex-/UV-/Face-Zahlen, keine Geometriefehler.
- USDZ-Import (`UsdzImport.swift`): .usdz/.usd/.usda laedt ModelIO nativ
  (MDLAsset); Attribut-Domaenen werden nur bei Bedarf vereinheitlicht,
  Texturen kommen aus dem MDLTexture bzw. per Mini-ZIP-Leser direkt aus dem
  USDZ-Archiv (ModelIOs "datei.usdz[innerer/pfad]"-Syntax). USD-UVs
  (Ursprung unten-links) werden fuer die gemeinsame Pipeline nach glTF-
  Konvention gespiegelt.
- Echtes PBR-Shading fuer beide (`MeshAtlas.swift` + `mesh_pbr_fs`-Shader
  in `Shaders.metal`) -- deutlich detaillierter als ein pauschaler
  Chrom/Nicht-Chrom-Dreiecks-Split anhand von Metalness-/Roughness-MASKEN:
  jedes Material bekommt vier gemeinsame Textur-Atlanten (BaseColor,
  Occlusion/Roughness/Metallic, Emissive, Normal -- dieselbe Zellaufteilung
  fuer alle vier) und wird PRO PIXEL per Cook-Torrance/GGX schattiert, inkl.
  Tangenten-Erzeugung (`MDLMesh.addTangentBasis`) fuer echtes
  Normal-Mapping. Ausloeser war ein sichtbarer Fehler des alten Ansatzes:
  bei einem Mehr-Material-Raumschiff kippten ganze Bauteile
  (Triebwerksgondeln) faelschlich komplett in den einheitlichen
  Chrom-Shader und verloren Textur UND Farbe -- im direkten Vergleich mit
  Xcodes eigener (nativer, physikalisch korrekter) USD-Vorschau sofort
  sichtbar. Eine Korrektur war trotzdem noetig: manche Asset-Pakete
  (Mond-/Mars-Fototexturen) liefern fuer komplett nicht-metallische
  Oberflaechen einen hohen `metallicFactor` UND eine kontrastarme, eher
  AO-artige Metallic-Textur -- ohne Gegenpruefung
  (`MeshAtlas.channelHasRealContrast`) wuerde das per-Pixel-Shading solche
  Oberflaechen faelschlich glaenzend-metallisch machen (per SceneKit-
  Referenzrender von Apples eigener PBR-Pipeline verifiziert: ein
  vergleichbares Mond-Asset bleibt dort komplett matt).
- Gemeinsame Bausteine in `MeshAtlas.swift`: Atlas-Layout einmal berechnet
  und fuer alle vier Texturen wiederverwendet, UVs werden pro
  FLAECHEN-Ecke umgerechnet (inkl. Naht-Entpackung `unwrapTriangleUV` gegen
  quer verschmierte Dreiecke an Textur-Naehten). Datei-Auswahl im
  Options-Dialog mit Security-Scoped-Bookmark, damit der sandboxte
  Screensaver-Prozess die Datei spaeter noch lesen darf.
- Prozessweiter Mesh-Cache (`TeapotMesh.cached`): macOS instanziiert die
  Vorschau-View in den Systemeinstellungen bei praktisch jeder Interaktion
  neu -- ohne Cache waere jede Instanz eines grossen importierten Modells
  1-2 Sekunden Neu-Parsen faellig gewesen (spuerbar traege Vorschau).

### Nachtraeglich ergaenzt

- Der Anti-Leak-Exit (Prozess nach Beenden gezielt neu starten): 
  `legacyScreenSaver.appex` gibt Prozesse nach Settings-Vorschauen generell
  nicht zuverlaessig frei (eine ViewBridge-Hosting-Eigenheit von macOS
  selbst) -- per Diagnose bestaetigt (siehe `Matrix3DSaverView.swift`:
  Heartbeat fuer den externen `legacyss-cleanup`-Watchdog,
  `willstop`/`didstop`-Beobachtung + verzoegerter `exit(0)`).
- Ebenfalls ergaenzt: Einzelbildschirm-Erkennung
  (`ScreenRegistry.isSingleDisplay()`), Instanz-Stilllegung ohne
  Endlosschleife (`retireSilently()`), Miniatur-Platzhaltergroesse, sowie
  ein prozessweiter Sheet-Pause-Mechanismus (mehrere Instanzen im selben
  Prozess muessen waehrend eines offenen Options-Sheets pausieren, sonst
  praesentiert der Host kein weiteres Sheet mehr).

## Bauen

Erfordert Xcode und [XcodeGen](https://github.com/yonaskolb/XcodeGen).
`project.yml` enthaelt Platzhalter fuer Team-IDs und Bundle-IDs. Fuer ein
signiertes Release `tools/local-signing.env.example` nach
`tools/local-signing.env` (gitignored) kopieren und eigene Developer-ID-
Daten eintragen. Fuer einen unsignierten lokalen Testbuild
`CODE_SIGNING_ALLOWED=NO` an die `xcodebuild`-Aufrufe unten anhaengen.

```sh
xcodegen generate   # erzeugt/aktualisiert Matrix3DSaverX.xcodeproj aus project.yml
```

### Release (Maintainer)

Vollstaendiger signierter + notarisierter Release in einem Schritt:

```sh
./tools/release.sh
```

Baut den `.saver`, reicht ihn bei Apple Notary Service ein, stapelt das Ticket,
erstellt ein versioniertes DMG, notarisiert und stapelt das DMG und erhoeht
die Build-Nummer in `project.yml`. Erfordert `tools/local-signing.env` und
ein gespeichertes notarytool-Keychain-Profil (siehe `tools/release.sh`).

### Legacy `.saver` (parallel behalten)

```sh
xcodebuild -scheme Matrix3DSaverX -configuration Release -derivedDataPath build/DerivedData build
```

### Appex (Host-App + Extension, macOS 14+)

```sh
xcodebuild -scheme Matrix3DSaverXApp -configuration Debug -derivedDataPath build/DerivedData build
```

Nach Aenderungen an `project.yml` muss `xcodegen generate` erneut laufen.

## Installieren/Testen

### `.saver`

```sh
cp -R build/DerivedData/Build/Products/Debug/Matrix3DSaverX.saver ~/Library/Screen\ Savers/
```

### Appex

**Eine** Installationsquelle waehlen (DerivedData **oder** `/Applications`, nie beides — sonst haengt `pluginkit` am alten Pfad):

```sh
# Empfehlung zum Testen: einmal nach /Applications kopieren
cp -R build/DerivedData/Build/Products/Debug/Matrix3DSaverX.app /Applications/
open -a /Applications/Matrix3DSaverX.app   # Install-Button oder:
pluginkit -a /Applications/Matrix3DSaverX.app/Contents/PlugIns/Matrix3DSaverXExtension.appex
```

Danach in **System Settings → Screen Saver** als **Matrix 3D X** sichtbar. Console-Filter:

```
subsystem:de.r8lle.screensaver.matrix3dx
```

Prefs der Appex-Extension nutzen `de.r8lle.screensaver.matrix3dx.app.Extension`
(einmalige Migration aus dem alten `.saver`-Modul `de.r8lle.screensaver.matrix3dx`).
Private ScreenSaver-API — Developer-ID/Notarisierung moeglich, kein Mac App Store.
`killall`/Anti-Leak-`exit(0)` ist fuer Appex nicht noetig (eigener Extension-Prozess).

## Beispielmodelle

`SampleModels/` enthaelt drei Demo-Dateien (Earth.usdz, mastertux-cpu-311.glb,
spaceship/spaceship.usdz) zum Ausprobieren des eigenen GLB-/USDZ-Imports im
Options-Dialog ("Eigene GLB-Datei"/"Eigene USDZ-Datei"), ohne dass ein
eigenes 3D-Modell zur Hand sein muss.

## Bekannte Einschraenkung: Monitor-Anordnung oben/unten

Ist ein externer Monitor in der Bildschirm-Anordnung OBERHALB oder UNTERHALB
des eingebauten Displays platziert, bleibt er beim echten Bildschirmschoner
schwarz. Ursache ist ein Y-Koordinaten-Bug in Apples Host
(legacyScreenSaver.appex platziert das Vollbild-Fenster mit unkonvertierter
CG-Y-Koordinate ins Leere); aus dem Saver-Prozess heraus nicht behebbar
(Details im Kommentar in `Sources/Matrix3DSaverView.swift`). Appex kann
dieses Host-Problem mindern, aber Apple-seitige Dual-Monitor-Bugs koennen
teilweise weiterbestehen.

**Workaround:** den externen Monitor in den Systemeinstellungen LINKS oder
RECHTS neben dem eingebauten Display anordnen -- dann funktioniert alles.

## Bekannte Einschraenkung: Options-Button funktioniert nur einmal pro Einstellungen-Sitzung

Ein Klick auf **Optionen…** in den Systemeinstellungen → Bildschirmschoner
oeffnet das Options-Fenster beim ersten Mal; ein zweiter Klick tut nichts
mehr, bis die Systemeinstellungen komplett beendet und neu geoeffnet werden.
Das ist ein dokumentierter Apple-Bug in der Host-Schicht
`legacyScreenSaver.appex` selbst, nicht etwas, das diese App steuert --
`configureSheet` (`Sources/Matrix3DSaverView.swift`) baut bei jedem Aufruf
ein frisches Sheet ohne eigene interne Sperre auf, aber der Host ruft es
manchmal einfach kein zweites Mal auf. Von mehreren Drittanbieter-
Screensaver-Entwicklern quer durch macOS Ventura bis Tahoe gemeldet (Apple
Feedback FB10103112, FB17895600; siehe auch den
[Aerial-Screensaver-Issue-Tracker](https://github.com/JohnCoates/Aerial/issues/1250)
und den
[Apple-Developer-Forums-Thread zur Sonoma-Screensaver-Instabilitaet](https://developer.apple.com/forums/thread/738547)).

**Workaround:** die Systemeinstellungen zwischen Options-Sitzungen komplett
beenden und neu oeffnen.
