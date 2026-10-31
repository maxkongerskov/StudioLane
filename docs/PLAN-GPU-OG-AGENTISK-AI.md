# Plan: GPU-ydeevne og agentisk styring af StudioLane

Dette er en plan. Den ændrer ingen featurekode. Anbefalingerne er læst ud af repoet, som det står: SwiftUI/AppKit/AVFoundation, ét app-target i `Package.swift`, ingen Metal-, Core Image-, VideoToolbox-, Accelerate- eller FFmpeg-afhængighed.

## Resumé

**Topanbefaling.** Gør den stdio-MCP, der allerede kører inde i appen, til den stabile måde en agent styrer StudioLane på, og fjern de CPU-stier der i dag gør preview, scrub og eksport langsomme. En egen Metal-compositor og en indlejret lokal model er senere skridt. De løser ikke det, koden mangler nu: målinger, observation tilbage til agenten, og et kald der kan køre uden det sidste autosave-vindue.

AVPlayer og AVPlayerLayer viser allerede billedet gennem systemets dekoder og GPU. Appen sætter ingen shader, ingen `CIContext` og ingen `customVideoCompositorClass`. De dyre steder er præcis seek på hvert scrub-sample, et fuldt `replaceCurrentItem` ved næsten hver klipperettelse, serielle filmstrip-frames, et Swift-loop pr. lydsample, writer-eksport der tvinger 32BGRA tilbage til CPU, og stillbilleder der kodes som 30 ens H.264-frames. GPU-arbejdet der batter, er at lade VideoToolbox blive på hardwaren og at stoppe de readbacks. En egen compositor bliver aktuel, når video skal ligge i rigtige lag. I dag klappes overlappende videoklip sammen på ét kompositionsspor.

MCP-fladen er længere fremme end arkitekturdokumentet antyder, og samtidig ikke klar til at en agent kan køre et klip færdigt. `MCPServer` læser JSON-RPC på stdin når appen startes med `--mcp`. Der er tools til import, trim, flyt, split, slet, gain, spor-volumen, mute, fades, crossfade, batch, eksport, annullering og tomt projekt. Der er ingen test, ingen headless-tilstand, intet renderet frame tilbage, og `tools/call` svarer med `id: null`. `batch_edit` ruller ikke tilbage. `mcpRevision` flytter sig kun på MCP-kald, så en UI-redigering ikke giver den konflikt, `ARCHITECTURE_MCP.md` beskriver. De fleste MCP-redigeringer lægger heller ikke et undo-trin.

Lokale modeller (Ollama, llama.cpp, Apple Foundation Models) skal være klienter til den samme MCP. De skal ikke bo inde i editoren. En lille model kan køre “trim, fade, eksport”, når state, frame og fejl er deterministiske. Den kan ikke vurdere billedet, før `render_frame` findes.

**De fem vigtigste skridt**

1. Mål scrub, rebuild, filmstrip, bølgeform og eksport, før nogen GPU-omskrivning.
2. Ret de dyreste stier der allerede er i koden: seek-tolerance under scrub, vDSP-peaks, filmstrip-cache, hardware-encode uden BGRA-readback, og ét hold-frame for stills.
3. Gør MCP observerbar og til at tale med: korrekt JSON-RPC-id, revision på alle mutationer, filsti og playhead i state, og et `--mcp`-kald der starter tomt.
4. Luk agent-løkken: frame og bølgeform tilbage, play/seek, atomisk batch, undo, og en test der kører import → trim → fade → eksport.
5. Lad Ollama, llama.cpp og Foundation Models kalde den flade. Byg først en Metal-compositor, når lagdeling er et produktkrav og målingen viser at system-compositoren ikke slår til.

Indsats: **S** er ét afgrænset sted, **M** krydser model, MCP og test, **L** er et nyt undersystem.

---

## Udgangspunkt i koden

### Preview, komposition og effekter

| Sti | Hvad koden gør | Hvor |
| --- | --- | --- |
| Preview | `AVPlayer` i `EditorModel`, vist med `AVPlayerLayer` (`videoGravity = .resizeAspect`). Ingen Metal-view. | `StudioView.swift` (`PlayerSurface`, `PlayerNSView`), `EditorModel.player` |
| Komposition | `AVMutableComposition`. Video lægges på ét spor med `preferredTrackID: 1`. Lyd får ét spor pr. klip, så hvert klip kan have egne fades. | `rebuildComposition()` |
| Overlap | `renderSegments()` springer det dækkede stykke over. Et klip der ligger helt under et tidligere, kommer hverken i mixet eller i instruktionerne. Flere videospor i modellen deler altså ét billede. | `renderSegments()`, `makeVideoComposition()` |
| Effekter | Opacity- og transform-ramper på `AVMutableVideoCompositionLayerInstruction`. Pro: scale, position, rotation, opacity, keyframes, dissolve, slide, zoom. Ingen `CIFilter`, ingen blur, ingen farve. System-compositoren kører ramperne. | `configureVideoLayer()`, `applyTransition()`, `ProFeatures.swift`, `VideoCompositionPlan.swift` |
| Hvornår composition sættes | Kun ved video-fade eller Pro-effekter. Mix-only (gain, spor-volumen, pan, ducking, lyd-fade) kalder `applyFades(refreshingVideo: false)` og rører ikke `videoComposition`, fordi et skift river previewet ned. | `applyFades()`, `makeVideoComposition()` |
| Rebuild | Hvert struktur-kald bygger et nyt mix og kalder `player.replaceCurrentItem`. Arbejdet er `@MainActor`. Asset-loads er `await`, men commit og seek sker på main. | `scheduleRebuild()`, `rebuildComposition()` |

`VideoCompositionPlan` er ren tidsmatematik (slots og opacity-ramper). Den er GPU-fri og allerede dækket af `Tests/StudioLaneCoreTests/VideoCompositionPlanTests.swift`. `PlaybackPreviewTests` tjekker at composition dækker hele itemet, også når lyd er længere end billedet.

### Bølgeform, filmstrip og stills

`scheduleWaveform` kører `Waveform.peaks` i en detached task: `AVAudioFile`, 720–8192 punkter over hele kilden, derefter et Swift-loop der læser hvert sample og tager max. Ingen `vDSP`. `Waveform.peaksFromAsset` læser hele PCM-bufferen ind i et `[Float]` og bruges ingen steder. Peaks gemmes i `.salproject` når de er under 8192 (`MediaClip.maximumPersistedWaveformPoints`). Trim tegner kun et vindue (`WaveformView` i `TimelineView.swift`).

`scheduleFilmstrip` kører `Filmstrip.generate`: op til 64 frames (`filmstripFrameCount`, ca. 2 pr. sekund, loft 64), `AVAssetImageGenerator.copyCGImage` i en serie, `maximumSize` 160×268, tolerance 0,05 s. Ingen disk-cache. Filmstrips ligger kun i `filmstrips: [UUID: CGImage]` og regenereres efter genstart (`regenerateMissingVisuals`). `FilmstripLane` tegner dem i en SwiftUI `Canvas` og laver et nyt `NSImage` pr. celle pr. draw.

Stills caches som en 1-sekunds film (`StillImage.movieURL`). `writeMovie` tegner billedet med `CGContext` til 32BGRA og skriver 30 identiske H.264-frames med `AVAssetWriter`, med `Thread.sleep` mens input ikke er klar. `place` strækker det sekund med `scaleTimeRange`. Thumbnails kommer fra ImageIO (`StillImage.thumbnail`, max 320 px).

### Scrub, afspilning og lyd

`seek(to:)` kalder `player.seek` med `toleranceBefore: .zero` og `toleranceAfter: .zero`. Tidslinjens drag kalder det på hvert sample (`TimelineView.seekGesture`). Nul-tolerance tvinger en præcis frame og slår den hurtige scrub fra, som AVPlayer ellers kan.

Afspilning observeres 30 gange i sekundet på main (`installTimeObserver`) og skriver `currentTime`, som SwiftUI læser. Loop søger også med nul-tolerance.

Pro-lyd er en `MTAudioProcessingTap` (`ProAudioProcessor.swift`): equal-power pan og en hård limiter, sample for sample, på lydtråden. Den er billig i dag. Ducking er en konstant faktor 0,22 når et lydklip overlapper noget video (`duckingGain`, `duckFactor`), ikke et sidechain-envelope.

### Eksport

`startExportSnapshot` vælger sti:

- **Session** (`AVAssetExportSession`) for almindelig video, når `prefersWriterPipeline` er falsk. Presets i `ExportSettings.exportPresetName()`: H.264 Low/Medium/Highest, HEVC 1920×1080 eller Highest, ProRes 422/4444. Det er den sti, der på Apple-silicon typisk bliver på VideoToolbox uden at appen beder om det. MCP-eksport lander her, fordi den lader `audioBitrate` være `.match` og `videoBitrateMbps` være 0.
- **Writer** (`performWriterExport`) når brugeren sætter eksplicit AAC eller bitrate, eller Pro-mode har sample rate forskellig fra 48 kHz. Reader beder om `kCVPixelFormatType_32BGRA`. Der er intet `AVVideoEncoderSpecification`, intet hardware-flag og intet `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`. BGRA er et CPU-læsbart format. Compositoren renderer, bufferen kopieres tilbage, og encoderen skal konvertere igen.
- **GIF** (`performGIFExport`) henter ét `CGImage` ad gangen og skriver ImageIO. Rent CPU. Op til fire forsøg for at holde filen under 15 MB.
- **X Loop** koder først H.264/AAC via writeren, og gentager derefter med `AVAssetExportPresetPassthrough`.

Der er ingen FFmpeg-bro. `rg` finder ingen `ffmpeg` / `Process` der starter et eksternt encode-binært. Formater AVFoundation ikke kan læse, er et separat problem. De er ikke en GPU-sti.

### Hvor langt agent-laget er

`App.startMCPIfNeeded` starter `MCPServer` ca. 200 ms efter vinduet, kun når `--mcp` er med. `init` har en tom `if` på samme flag. Appen åbner altid UI, kører `model.start()` → `loadDefaults()` → `restoreAutosave()`, og lytter på tastatur. Der er ingen headless-tilstand.

`MCPServer.readLoop` læser stdin én byte ad gangen og sover 50 ms når linjen er tom. Den læser `isRunning` fra en baggrundskø, mens klassen er `@MainActor`. Ved EOF returnerer `readLine()` nil, løkken fortsætter, og processen bliver hængende. `tools/call` lægger svaret på `arguments["__id"]`, som ingen sætter, så JSON-RPC-`id` bliver `null`. Progress-token er samme værdi. En rigtig MCP-klient kan derfor ikke koble svar og progress på kaldet.

Tools der faktisk er registreret i `toolDefinitions`: `get_project_state`, `get_export_status`, `add_clip`, `trim_clip`, `move_clip`, `split_clip`, `delete_clip`, `set_clip_volume`, `set_track_volume`, `toggle_mute`, `set_fade_in`, `set_fade_out`, `clear_fades`, `batch_edit`, `export_project`, `cancel_export`, `crossfade_clips`, `create_project_template`.

`ARCHITECTURE_MCP.md` beskriver derudover `get_schema_docs` og et `job_id`. De findes ikke. Arkitekturen lover atomisk batch og revision-konflikt mod UI-redigeringer. Koden gør dette i stedet:

- `mcpRevision` tælles kun i `MCPHandlers`, `resetForTemplate` og `cancel_export`. UI-kald til `pushHistory` rører den ikke.
- `batch_edit` kører ops i rækkefølge og fortsætter efter fejl. Ingen snapshot, ingen rollback. `add_clip`, `split_clip`, `delete_clip` og `set_track_volume` er ikke med.
- `add_clip` returnerer `status` og `revision`, ikke det nye klips id.
- `trim` / `move` / `split` / fade / gain kalder ikke `pushHistory`. `delete_clip` gør, via `deleteClip`, men tæller revision op *før* sletningen, også når id ikke findes, og svarer stadig `deleted`.
- `get_project_state` har spor, klip, tider, fade, gain, mute, fader, `is_playing`, `is_exporting`. Den mangler fil-URL, playhead, `sourceDuration`, render-størrelse, fps, layout, ducking, Pro-transform og valgt klip. Projektfilen på disk (`ProjectDocument`) har URL’er og playhead. Agenten ser en smallere model end filen.
- Ingen tools til play, pause, seek, undo, redo, åbn projekt, nyt spor, eller et frame.
- Ingen MCP-tests under `Tests/`.

Undo i UI er en privat stak (`history` / `future`, loft 100). `IMPROVEMENT-LOG.md` beskriver at menulistens Undo stadig er død, fordi `registerUndo` ikke kommer tilbage. En agent skal kalde et tool mod den private stak. Den kan ikke stole på menulinjen.

Playlist-layout (default) rippler og lægger automatiske crossfades på ved import og slet (`applyPlaylistCrossfades`). En agent der lægger lyd i forlængelse, får fades den ikke bad om. Videolag bliver stille klappet sammen. Begge dele skal stå i skemaet, ellers planlægger modellen et klip, koden ikke kan vise.

---

## Fase 1 — Quick wins

Måling først, derefter de stier der allerede er dyre, og de MCP-fejl der gør enhver klient upålidelig.

### 1.1 Baseline for CPU, GPU og main thread

- **Hvad.** Et fast klip der kan køres igen: 1080p30 H.264, 4K30 HEVC, 3 min og 30 min stereo, plus et stillbillede. Mål med `os_signpost` omkring `seek`, `rebuildComposition`, `Filmstrip.generate`, `Waveform.peaks`, `performWriterExport`, `performGIFExport` og `StillImage.writeMovie`. Læs Time Profiler, og i Instruments Metal System Trace / VideoToolbox om session-eksport og preview faktisk rammer hardwaren.
- **Hvorfor.** Uden tal er “mere GPU” et gæt. Preview bruger allerede systemets dekoder. Baseline skal vise om smerten er seek, rebuild, thumbnail, peaks eller BGRA-readback.
- **Filer.** Nyt målespor, ikke i editorens hot path. Naturlige kroge: `EditorModel.swift` (de funktioner ovenfor), `StillImage.swift`. Et lille fixture-program kan følge mønstret i `Tests/StudioAudioLaneTests/PlaybackPreviewTests.swift` (`writeVideo` / `writeAudio`).
- **Indsats.** M.
- **Afhænger af.** Ingen.
- **Succes.** Ét ark med p50/p95 for: scrub-seek på 1080p og 4K, rebuild med 1, 8 og 30 klip, filmstrip til første frame og til fuld stribe (60 s og 10 min), waveform for 3 min og 30 min, 60 s 1080p H.264 session vs. writer, GIF for 5 s, still-import. GPU-kolonnen er “VT hardware encode ja/nej” og “BGRA-readback ja/nej”, ikke et løst procenttal.

### 1.2 Scrub med grov tolerance, præcis frame ved slip

- **Hvad.** Under drag: `seek` med en tolerance på omkring en halv frame (eller `toleranceBefore/After` ud fra `frameDuration`). Ved slip og ved indtastet tidskode: behold nul-tolerance. Playhead-teksten må godt følge den grove seek.
- **Hvorfor.** `seekGesture` kalder `seek(to:)` med nul-tolerance på hvert drag-sample. Det er den klassiske årsag til at scrub hakker, også når dekoderen er hardware. Preview-laget er allerede GPU. Tolerancen er den konkrete knob.
- **Filer.** `EditorModel.seek(to:)`, `TimelineView.seekGesture`, playhead-editoren samme fil.
- **Indsats.** S.
- **Afhænger af.** 1.1, så før/efter er det samme klip.
- **Succes.** p95 for seek-completion under et 2-sekunders drag hen over 60 s 1080p er under 50 ms, og den frame man slipper på, matcher nul-tolerance-seek inden for én frame. 4K måles og rapporteres for sig. Main-thread stalls over 16 ms under drag tælles og skal falde mod baseline.

### 1.3 Bølgeform med vDSP

- **Hvad.** Erstat sample-loopet i `Waveform.peaks` med `vDSP_maxmgv` (eller `vDSP_vabs` + max) pr. bucket, stadig i den detached task, stadig fuld-kilde-peaks så trim kun masker. Slet eller lad `peaksFromAsset` være, men kald den ikke: den samler alle samples i ét array.
- **Hvorfor.** Et 30-minutters spor er millioner af Swift-iterationer på CPU. Accelerate er den rigtige enhed her. GPU hjælper ikke et 1-dimensionelt peak-kort, og kortet tegnes bagefter som 2D-rectangles i `WaveformView`.
- **Filer.** `Waveform` i `EditorModel.swift`. Tegningen i `TimelineView.swift` kan vente.
- **Indsats.** S.
- **Afhænger af.** 1.1.
- **Succes.** Samme punktantal (720–8192). Max-afvigelse pr. bucket under 1e-4 mod det gamle loop på en kendt fixture. 30 min stereo under den tid 1.1 sætter som mål efter måling. UI må ikke regenerere peaks ved trim (`scheduleWaveform` kører kun når mappet er tomt).

### 1.4 Filmstrip-cache og parallel generering

- **Hvad.** Gem de små JPEG/PNG-frames ved siden af still-cachen (`StillImage.cacheFile` hasher allerede sti, størrelse og mtime). Ved hit: load fra disk. Ved miss: `AVAssetImageGenerator.images(for:)` / async generering i stedet for seriel `copyCGImage`, stadig max 64 og 160×268. Genbrug det billede `FilmstripLane` allerede har, i stedet for et nyt `NSImage` pr. celle pr. draw.
- **Hvorfor.** Hver genstart og hvert nyt klip dekoder op til 64 frames på CPU-siden af generatoren, også når kilden er den samme. Tegningen gentager arbejdet på main.
- **Filer.** `Filmstrip` i `EditorModel.swift`, `FilmstripLane` i `TimelineView.swift`. Cache-mappe kan spejle `StillImage.cacheFile`.
- **Indsats.** M.
- **Afhænger af.** 1.1.
- **Succes.** Cache-hit under 50 ms til striben er synlig. Cache-miss for 60 s 1080p er mindst 3× hurtigere end den serielle baseline, målt til fuld stribe. Et ændret fil-mtime laver en ny nøgle. Trim skifter ikke frames, kun vinduet, som i dag.

### 1.5 Writer-eksport på hardware, uden BGRA-readback

- **Hvad.** Når output er H.264 eller HEVC og der ikke er en bruger-shader: bed readeren om `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (eller lad output settings være `nil` og lad writerens input tage compressed frames, hvis composition er nil). Sæt encoder-specifikationen så VideoToolbox foretrækker hardware (`EnableHardwareAcceleratedVideoEncoder`), og log om sessionen faktisk fik den. Behold 32BGRA kun hvis en senere custom compositor kræver det. Lad ProRes blive på session-presetet (`AVAssetExportPresetAppleProRes422LPCM` / `4444`), som den allerede gør når writeren ikke er valgt.
- **Hvorfor.** `performWriterExport` tvinger 32BGRA. Det er et readback: compositor → CPU-buffer → encoder. Session-stien er allerede den bedre default for MCP. Writer-stien bruges så snart bitrate eller sample rate afviger, inklusive Pro-mode ved andet end 48 kHz. Den sti skal ikke være den langsomme.
- **Filer.** `performWriterExport`, `startExportSnapshot`, `ExportSettings.prefersWriterPipeline` i `ExportSheet.swift`.
- **Indsats.** M.
- **Afhænger af.** 1.1. Ændr ikke session-stien før baseline er skrevet ned.
- **Succes.** 60 s 1080p H.264 med fade: writer-tiden inden for 15 % af session-presetet på samme maskine, og Instruments viser hardware-encode. Output afspilles i QuickTime. En kendt fixture holder varighed inden for én frame. Annullering sletter stadig partialen (`cancelExport`).

### 1.6 Ét hold-frame for stillbilleder

- **Hvad.** Skriv et kort MOV med ét frame (eller få frames) og en duration på 1 sekund, i stedet for 30 identiske appends med sleep. Behold hash-cachen og `scaleTimeRange` i `place`.
- **Hvorfor.** `writeMovie` bruger CPU-bitmap, venter i en løkke, og koder 30 gange det samme billede, for bagefter at strække sekundet. Import af billeder blokerer den detached task længere end selve billedet kræver.
- **Filer.** `StillImage.writeMovie`, `StillImage.place`. Tester i `Tests/StudioAudioLaneTests/StillImageTests.swift`.
- **Indsats.** S.
- **Afhænger af.** Ingen, ud over at de eksisterende still-tests bliver ved med at placere et billede.
- **Succes.** Import af en 12 MP JPEG er hurtigere end baseline fra 1.1. Det placerede klip kan stadig trimmes og fades, og `renderSize` følger billedets orientering som i dag. Cachen genbruges når filen ikke har ændret sig.

### 1.7 JSON-RPC-id, revision og de svar agenten ikke kan bruge

- **Hvad.** Lad `tools/call` svare med klientens JSON-RPC-`id`, og brug samme id som progress-token. Tæl `mcpRevision` op i `pushHistory` (ét trin pr. UI-gestus, ikke pr. slider-sample), så en MCP-klient med `expected_revision` ser UI-ændringer. Returnér nyt klip-id fra `add_clip`. Lad `delete_clip` svare fejl når id mangler, og tæl kun revision når noget blev slettet. Stop stdin-løkken ved EOF. Læs linjer i blokke, ikke én byte plus 50 ms sleep. Flyt `isRunning` ud af et MainActor-hop pr. byte (atomisk flag).
- **Hvorfor.** Uden id kan en klient ikke matche svar. Uden revision på UI-edits er konflikt-tjekket i `checkRevision` kun et tjek mod agenten selv, stik imod flowet i `ARCHITECTURE_MCP.md`. Uden klip-id skal agenten gætte efter `get_project_state`. Byte-læsning og den hængende EOF-løkke gør `--mcp` skrøbelig som underproces.
- **Filer.** `MCPServer.swift` (`handleMessage`, `callTool`, `readLoop`, `FileHandle.readLine`), `MCPHandlers.swift` (`addClip`, `deleteClip`), `EditorModel.pushHistory` / `bumpMCPRevision`.
- **Indsats.** M.
- **Afhænger af.** Ingen.
- **Succes.** En test sender `initialize`, `tools/list` og `tools/call` på stdin og læser svar med samme `id`. Et UI-`pushHistory` øger revision. `add_clip` på en fixture returnerer et id der findes i state. Ukendt `delete_clip` returnerer `clip_not_found` og samme revision. Lukket stdin afslutter læseløkken.

### 1.8 State agenten faktisk kan planlægge ud fra

- **Hvad.** Udvid `get_project_state` med `playhead`, `source_duration`, `file_path`, `render_size`, `fps`, `audio_layout` (`playlist` / `layer`), `ducking`, og `project_path` når en fil er gemt. Compact mode kan stadig udelade defaults. Læg `source_in` med, også når den er 0, hvis compact er slået fra (det gør den allerede i den gren).
- **Hvorfor.** Agenten kan i dag ikke se hvilken fil et klip kom fra, hvor playhead står, eller at playlist vil lægge crossfade på. Den viden ligger i `MediaClip.url`, `currentTime` og `ProjectDocument`, men ikke i MCP-svaret.
- **Filer.** `MCPHandlers.getProjectState`, `MCPSchema.swift` (`MCPProjectState` / `MCPClip`, som i dag ikke er den sti serveren faktisk sender).
- **Indsats.** S.
- **Afhænger af.** 1.7, så svaret har et id.
- **Succes.** Efter `add_clip` indeholder state den absolutte sti, kildevarighed og playhead. Et projekt gemt med `saveProjectDirect` og genindlæst matcher de felter. Compact-svar er stadig mindre end fuld state.

---

## Fase 2 — Agenten kan køre et klip færdigt

Her bliver MCP den løkke en model kan gentage: se state, rette, se et frame, eksportere, og kunne fortryde.

### 2.1 Headless `--mcp` uden det forrige autosave

- **Hvad.** `--mcp` starter serveren uden at kalde `restoreAutosave`, uden save-panel og uden at aktivere filer i Finder når eksport er færdig (`finishExport` kalder `NSWorkspace.activateFileViewerSelecting` når `reveal` er true). Vinduet må gerne eksistere, så AVFoundation og AppKit stadig har en proces. Et tomt projekt er starttilstanden. `create_project_template` og en ny `open_project` er måden at fylde det på.
- **Hvorfor.** `loadDefaults` lægger sidste session ind under agenten. To kørsler er ikke ens. Eksport der stjæler fokus, duer ikke når en agent kører i baggrunden. Arkitekturen siger at `--mcp` “lytter på stdio”. I dag åbner den også studioet med den gamle tidslinje.
- **Filer.** `App.swift` (`startMCPIfNeeded`, den tomme `init`-gren), `EditorModel.loadDefaults` / `start`, `finishExport`.
- **Indsats.** M.
- **Afhænger af.** 1.7.
- **Succes.** To `--mcp`-kørsler i træk starter begge med tom tidslinje og revision 0, også når Application Support har en autosave. Almindelig launch uden flag genskaber sessionen som i dag. Eksport via tool skriver filen og lader Finder være.

### 2.2 `render_frame` og bølgeform tilbage til agenten

- **Hvad.** Et tool `render_frame(time, max_edge)` der søger (eller bruger `AVAssetImageGenerator` på det aktuelle mix + `videoComposition`) og returnerer et PNG, enten som base64 i MCP-content eller som en sti under en temp-mappe med `content: [{type: image}]` hvis klienten kan det. Et tool `get_waveform(clip_id, max_points)` der returnerer de peaks der allerede ligger på klippet, nedsamplet. Ingen ny decode hvis mappet findes.
- **Hvorfor.** En agent der kun ser JSON, kan ikke vide om faden, transformen eller det kollapsede overlap ser rigtigt ud. Peaks er allerede beregnet. Frames er den observation lokale og store modeller begge mangler. Generator-stien findes i GIF-eksporten (`AVAssetImageGenerator` + `videoComposition`). Den skal genbruges ved ét tidspunkt, ikke som en ny renderer.
- **Filer.** `MCPServer.swift`, `MCPHandlers.swift`, `EditorModel` (adgang til `player.currentItem`, `makeVideoComposition`, `mix`). Generator-indstillinger kan deles med `Filmstrip.generate` og `performGIFExport`.
- **Indsats.** M.
- **Afhænger af.** 1.7, 1.8, og at rebuild er færdig (`waitForRebuildsToSettle` findes allerede og bruges af eksport).
- **Succes.** På `PlaybackPreviewTests`-fixturen giver `t = 0` et PNG med de forventede dimensioner, og et tidspunkt inde i en fade har en anden gennemsnitsluminans end et tidspunkt uden fade. Kald under igangværende rebuild venter og svarer på den færdige composition. Svar-tiden for et 720 px-frame på 1080p-kilden måles og lægges ved baseline.

### 2.3 Transport, projektfil og spor

- **Hvad.** Tools: `play`, `pause`, `seek(time)`, `open_project(path)`, `save_project(path, overwrite)`, `add_track(kind, name)`, `set_audio_layout(playlist|layer)`, `set_ducking(bool)`. `seek` bruger nul-tolerance. `open_project` går gennem `applyProjectDocument`. `save_project` gennem `saveProjectDirect`.
- **Hvorfor.** Uden play/seek kan agenten ikke bruge det frame-tool ved playhead, og den kan ikke stoppe afspilning før et rebuild. Uden åbn/gem er `.salproject` kun noget UI’en kan. Uden spor-tool kan `create_project_template` lave spor, men ikke tilføje ét. Layout-toollet er måden at slå den automatiske playlist-crossfade fra, før agenten placerer lyd.
- **Filer.** `MCPServer.swift`, `MCPHandlers.swift`, `EditorModel` (`togglePlay`, `seek`, `applyProjectDocument`, `saveProjectDirect`, `addLane`, `setAudioLayoutMode`, `setDuckingMusic`).
- **Indsats.** M.
- **Afhænger af.** 2.1, så `open_project` ikke kæmper med autosave.
- **Succes.** En sekvens seek → `render_frame` rammer det tidspunkt state bagefter viser som playhead, inden for én frame. `save_project` + `open_project` bevarer klip-id, URL, fades og playhead. `set_audio_layout(layer)` gør at en efterfølgende `add_clip` ikke rippler.

### 2.4 Atomisk batch og undo på samme stak som UI

- **Hvad.** `batch_edit` tager et snapshot (`currentSnapshot`), validerer alle ops, anvender dem, og ved første fejl kalder `restore` og svarer med fejlene og den gamle revision. Medtag `split_clip`, `delete_clip` (kræver stadig `confirmed`), `set_track_volume` og `crossfade_clips`. `add_clip` bliver ude af batchen indtil import er synkron nok til at kunne rulles tilbage, eller den får sin egen “allerede importeret”-op. Hvert MCP-kald der ændrer tidslinjen, kalder `pushHistory` én gang. Nye tools `undo` og `redo` kalder de metoder der findes. UI-sliderens `beginEdit` bliver ved med at være ét trin for hele draget.
- **Hvorfor.** `ARCHITECTURE_MCP.md` siger at batch er atomisk, og at mutationer arver history. `batchEdit` gør ingen af delene. En agent der splitter og derefter rammer en fejl, efterlader et halvt klip. Uden undo kan den ikke prøve en fade og gå tilbage. Den private stak er den rigtige; menulinjens Undo er stadig den fejl loggen beskriver, og den skal ikke være agentens vej.
- **Filer.** `MCPServer.batchEdit`, `MCPHandlers` (trim/move/split/fade/gain), `EditorModel.pushHistory` / `undo` / `redo` / `restore`.
- **Indsats.** M.
- **Afhænger af.** 1.7.
- **Succes.** En batch med en ugyldig op til sidst ændrer ingen klip og ingen revision. `undo` efter `trim_clip` genskaber varighed og in-point. 100 trin er stadig loftet. En test dækker konflikt: `expected_revision` der er for gammel, returnerer `revision_conflict` og rører ikke tidslinjen.

### 2.5 Saml rebuilds, og bland kun lyd når billedet er det samme

- **Hvad.** Behold den kø `scheduleRebuild` allerede er (den annullerer in-flight). Lad MCP-kald der kun ændrer gain, mute, spor-volumen eller lyd-fade, blive på `applyFades(refreshingVideo: false)`. Lad trim/move/split på *video* stadig rebuilde, men debounce korte serier (batch = ét rebuild til sidst, ikke ét pr. op). Mål main-thread-tiden i `rebuildComposition` efter asset-loads, isoleret fra decode.
- **Hvorfor.** `replaceCurrentItem` er den store stall ved klipperettelser. Den er nødvendig når sporstrukturen ændrer sig. Den er allerede undgået for mix. MCP-trim kalder altid `scheduleRebuildPublic`, også for et lydklip hvor et nyt mix faktisk skal til, men en batch af ti trims må ikke starte ti player-udskiftninger. Det er også det, der får previewet til at blinke under playback (`PlaybackPreviewTests` vogter netop at mix-only ikke skifter composition-objektet).
- **Filer.** `MCPHandlers` (trim/move/split/fade), `EditorModel.scheduleRebuild`, `rebuildComposition`, `applyFades`.
- **Indsats.** M.
- **Afhænger af.** 1.1 og 2.4 (batch skal vide hvornår den rebuilder).
- **Succes.** En batch med 10 lyd-trims laver ét rebuild. Gain under afspilning beholder samme `videoComposition`-objekt (den test der findes, skal blive ved med at bestå). p95 for rebuild af 8 klip i 1080p falder mod baseline, eller stalls over 16 ms på main efter I/O er færdig, er talt og lavere.

### 2.6 End-to-end-test uden at klikke

- **Hvad.** Én test, eller et lille stdio-script i testtarget, der starter handlerne mod en `EditorModel` med fixtures: `add_clip` video, `add_clip` lyd, `trim_clip`, `set_fade_in`, `seek`, `render_frame`, `export_project` til en temp-mp4, `get_export_status` til `progress == 1`. Ingen save-panel.
- **Hvorfor.** Det er definitionen på “AI kan køre StudioLane”. Uden den test driver den næste ændring i `EditorModel` agent-fladen i stykker. Der er i dag nul MCP-tests. Der er fixtures-mønster i `PlaybackPreviewTests` og export-dækning i `ExportOptionsTests`.
- **Filer.** Nyt `Tests/StudioAudioLaneTests/MCPAgentLoopTests.swift`. Handlere i `MCPHandlers.swift`. Eksport via `beginExportDirect`.
- **Indsats.** M.
- **Afhænger af.** 1.7, 1.8, 2.2, 2.3.
- **Succes.** Testen er grøn på en maskine med AVFoundation. Output-filen er over 1024 bytes (samme gulv som `finishExport`), varighed inden for én frame af tidslinjen, og frame-PNG’en har de ventede pixelmål. Testen rører ikke brugerens autosave.

---

## Fase 3 — Lag, compositor og lokale modeller

Først når fase 1 er målt, og fase 2’s løkke er grøn. Ellers bygges der GPU og model oven på en agent der ikke kan se billedet.

### 3.1 Sig højt hvad tidslinjen ikke kan

- **Hvad.** Implementér `get_schema_docs`, som arkitekturen allerede lover. Teksten skal sige: ét kompositionsspor, overlap klappes sammen, playlist lægger crossfades, stills er et strakt sekund, Pro-transform kræver Pro-mode, GIF har ingen lyd, MCP-eksport bruger original opløsning og session-stien medmindre codec/quality siger andet. Opdatér `ARCHITECTURE_MCP.md`, så den matcher tools, id-svar og at batch først er atomisk efter 2.4.
- **Hvorfor.** En model fylder hullerne med DaVinci-antagelser. Den lægger B-roll ovenpå og tror det er med i eksporten. `renderSegments` smider det væk uden fejl. Skemaet er billigere og ærligere end en compositor, og det er det, lokale modeller med kort kontekst kan holde i hovedet.
- **Filer.** `MCPServer.toolDefinitions`, ny handler, `ARCHITECTURE_MCP.md`.
- **Indsats.** S.
- **Afhænger af.** 2.6, så skemaet beskriver den flade testen faktisk kører.
- **Succes.** `get_schema_docs` nævner overlap-reglen og playlist-crossfaden. En agent-test der lægger to videoklip oven i hinanden, får i state begge klip, og `render_frame` i det dækkede interval matcher det øverste (tidligste) klip. Det er dokumenteret, ikke en stille overraskelse.

### 3.2 Pro-værktøjer på den samme flade

- **Hvad.** Tools til det Pro allerede kan i UI: `set_transform`, `add_transform_keyframe`, `clear_transform_keyframes`, `set_transition` (none/dissolve/slide/zoom), `set_pan`, `set_pro_mode`. De kalder `setSelectedTransform`, `addTransformKeyframeAtPlayhead`, `applyTransition`-stien via de eksisterende mutators, med `pushHistory`.
- **Hvorfor.** Effekterne kører allerede på system-compositoren som ramper. En agent skal kunne sætte dem uden en ny renderer. De er usynlige i `get_project_state` i dag, så 1.8 skal have transform, keyframes, transition og pan med, før toolsene giver mening at bruge.
- **Filer.** `MCPHandlers.swift`, `MCPServer.swift`, `EditorModel` Pro-metoder, `ProFeatures.swift`, `get_project_state`.
- **Indsats.** M.
- **Afhænger af.** 1.8, 2.4, 3.1.
- **Succes.** `set_transform` med scale 0,5 giver et `render_frame` hvis ikke-baggrunds-pixels fylder mindre end identitetstransformen på samme fixture. Undo fjerner transformen. Med Pro slået fra afvises kaldet med en tydelig fejl, fordi `setSelectedTransform` allerede returnerer med det samme når `isProMode` er falsk.

### 3.3 VideoToolbox til filmstrip, hvis cachen ikke rækker

- **Hvad.** Hvis 1.4’s miss stadig er langsommere end afspilning af samme kilde: decode thumbnails med `AVAssetReader` + VideoToolbox (`VTDecompressionSession`) til en lille mål-størrelse, stadig loft 64, stadig disk-cache. Gør det ikke for preview. `AVPlayer` dekoder allerede.
- **Hvorfor.** `AVAssetImageGenerator.copyCGImage` er den langsomme, præcise vej. En hardware-decode til 160 px er den rigtige optimering, hvis cachen ikke fjerner ventetiden. Den er et større stykke kode end 1.4 og skal ikke bygges “for en sikkerheds skyld”.
- **Filer.** `Filmstrip` i `EditorModel.swift`. Ny lille type ved siden af, så `EditorModel` ikke vokser med session-kode.
- **Indsats.** L.
- **Afhænger af.** 1.1 og 1.4. Start kun hvis miss-tiden stadig er synlig (over ~300 ms for 60 s 1080p, eller det 1.1 viser er slemt).
- **Succes.** Samme cache-nøgle og samme visuelle loft. Miss-tid mindst 2× under generator-baseline på 4K. Frames er stadig orienteret rigtigt (`appliesPreferredTrackTransform` ækvivalent). Fejl falder tilbage til generatoren.

### 3.4 Egen Metal- eller Core Image-compositor, kun til rigtige lag

- **Hvad.** En `AVVideoCompositing` der implementerer `startRequest`, tager source-`CVPixelBuffer`s og skriver et output-buffer, med `CIContext(mtlDevice:)` eller et lille Metal-render-pass. Først når produktet skal vise to videospor samtidig (B-roll, pip, blend). Indtil da bliver `renderSegments` den ærlige model, og systemets layer-instructions bliver ved med at køre fades og Pro-ramper.
- **Hvorfor.** Der er intet at GPU-composite ud over det, AVFoundation allerede gør: én billedkilde, opacity, affine. En custom compositor skal også holde `instructionsCoveringPlayback` (huller får AVPlayer til at droppe hele previewet) og exportens reader. Det er et L-projekt med regressionsrisiko for den bug `PlaybackPreviewTests` vogter. Core Image på Metal er den korte vej, hvis effekterne er farve, blur eller blend. Ren Metal er vejen, hvis der skal være et fast graph pr. frame.
- **Filer.** Ny fil under `Sources/StudioAudioLane/` eller `StudioLaneCore`. `makeVideoComposition` sætter `customVideoCompositorClass`. `renderSegments` skal udvides til flere spor i stedet for at klappe sammen. Export i `performWriterExport` skal bruge et pixelformat compositoren og encoderen er enige om.
- **Indsats.** L.
- **Afhænger af.** 1.5 (pixelformat), 3.1 (agenter skal vide at lag nu er ægte), og en bevidst produktbeslutning om overlap. Ikke af en lokal model.
- **Succes.** To overlappende 1080p-klip er begge synlige i `render_frame` og i en 10 s eksport. Afspilning holder 30 fps på den maskine 1.1 brugte, med Metal System Trace der viser compositor-passet og stadig hardware-decode. Den eksisterende fade-test (`instructionsCoveringPlayback`) er grøn. Et hul i tidslinjen giver sort, ikke et dødt preview.

### 3.5 Lokale modeller som klienter, ikke som motor

- **Hvad.** Dokumentér ét MCP-kald: `StudioAudioLane --mcp` på stdio, protokol `2024-11-05`, de tools fase 2 efterlader. Ollama og llama.cpp taler tool-calls, ikke MCP. En tynd bro (uden for app-targetet) mapper deres tool-JSON til én linje på stdin og læser én linje svar. Apple Foundation Models (`FoundationModels` på macOS 26) kan kalde de samme tools fra en værtsproces på maskinen, med kort kontekst og `get_schema_docs` som det første kald. Ingen model linkes ind i `Package.swift`. Ingen netværks-MCP. Stdio er lokal og har ingen auth. En TCP-port senere kræver en token og localhost.
- **Hvorfor.** Appen er allerede en in-process server, som `ARCHITECTURE_MCP.md` ønskede, bare som minimal JSON-RPC i stedet for `swift-mcp-sdk`. Det er den rigtige kontrakt for Cursor, en cloud-agent og en on-device model. At lægge Ollama eller llama.cpp ind i editoren giver en anden livscyklus, en anden GPU-kamp med VideoToolbox, og ingen ekstra redigeringsevne. Foundation Models kan klare “læg 0,4 s fade på det valgte klip” når state er lille. De kan vurdere et billede, når `render_frame` giver et PNG, og kun hvis den konkrete model tager billeder. Indtil da er frame-filen til den ydre agent.
- **Filer.** Et kort afsnit i `ARCHITECTURE_MCP.md` eller `README.md` med kommandoen og tool-listen. Broen er et separat lille program, ikke en del af app-targetet, og først når 2.6 er grøn. Ingen ændring i `EditorModel` for modellens skyld.
- **Indsats.** M for bro og dokumentation. L hvis nogen alligevel vil indlejre en runtime.
- **Afhænger af.** 2.1, 2.2, 2.6, 3.1.
- **Succes.** Den samme agent-test kan køres af en scriptet klient og, manuelt, af en Ollama-tool-runde der kun ser tool-skemaet: import, trim, fade, frame, eksport. Modellens svar indeholder ikke tidsrum den ikke har læst i state. Et forkert `expected_revision` får den til at læse state igen, ikke til at skrive oveni.

### 3.6 Gyldne tests der ikke kræver bit-identisk encode

- **Hvad.** For GPU- og eksportændringer: sammenlign varighed, spor-antal, opløsning og et par samplede frames (gennemsnit pr. kvadrant, eller en lille perceptual hash), ikke fil-bytes. H.264/HEVC er ikke stabile på tværs af maskiner og VT-versioner. For agent-ændringer: JSON-state og revisionsnummer.
- **Hvorfor.** “Eksporter og diff filen” bliver rød uden at billedet er forkert, og grøn hvis en BGRA-sti og en 420-sti tilfældigvis rammer samme størrelse. Frame-samples fanger en fade der er væk, en rotation der er forkert, og et overlap der stadig klappes sammen.
- **Filer.** `Tests/StudioAudioLaneTests/`, ved siden af `PlaybackPreviewTests` og `ExportOptionsTests`.
- **Indsats.** M.
- **Afhænger af.** 1.5, 2.2, 2.6.
- **Succes.** Writer-ændringen i 1.5 og en session-eksport af samme fixture ligger inden for den aftalte frame-tolerance. Testen nævner maskine og codec i sit output, så et VT-fallback til software kan ses.

---

## Risici

- **System-GPU er usynlig i kildekoden.** At der ikke står Metal, betyder ikke at preview er ren CPU. `AVPlayerLayer` og session-presets bruger VideoToolbox når systemet kan. En plan der “tilføjer GPU” oven i det, kan flytte arbejde fra en hardware-dekoder til en langsommere egen pass. Derfor er 1.1 et krav for 1.5, 3.3 og 3.4.
- **Custom compositor kan vælte previewet.** `instructionsCoveringPlayback` findes, fordi et hul i `AVVideoComposition` får AVPlayer til at droppe billedet, også når lyden er længere. En Metal-compositor der ikke dækker hele itemet, genskaber den fejl. `PlaybackPreviewTests` skal med i enhver compositor-ændring.
- **BGRA føles som den nemme export-fix og kan være den langsomme.** Writeren bruger 32BGRA i dag, så fade og Pro-ramper virker. Et skift til 420 uden at tjekke fades kan give forkerte kanter eller et software-fallback. 3.6 er der for at fange det.
- **Revision og undo kan dobbelttælle.** Hvis både `pushHistory` og hver MCP-handler kalder `bumpMCPRevision`, hopper revision med 2, og `expected_revision` bliver ubrugelig. Én tæller pr. afsluttet mutation.
- **`--mcp` deler proces med UI.** En agent og et menneske i samme vindue vil kæmpe om playhead, selection og autosave. Headless start (2.1) plus revision-konflikt (1.7) er sikkerheden. Der er bevidst ingen “force overwrite”.
- **Playlist og overlap lyver for modellen.** Indtil 3.1 er i skemaet, vil agenter lave klip, eksporten ikke viser. Det er et produkt-spørgsmål, ikke et GPU-spørgsmål.
- **Stdio uden auth er kun sikkert som lokal underproces.** Serveren kan læse enhver sti brugeren må læse (`add_clip`) og skrive enhver sti (`export_project`, `save_project`). Den må ikke bindes til et netværk i denne plan.
- **Lokale modeller har kort kontekst og svag billedsans.** Foundation Models og små GGUF-modeller klarer tool-kald. De klarer ikke et 30-klips projekt i ét prompt, og de ser ikke previewet før 2.2. At indlejre dem i appen løser ingen af delene og konkurrerer med VideoToolbox om maskinen.
- **FFmpeg er ikke en genvej her.** Broen findes ikke. AVFoundation dækker H.264, HEVC, ProRes, GIF og de containere eksporten allerede har. En FFmpeg-proces ville duplikere writer-stien og flytte encode væk fra VideoToolbox, medmindre opgaven er et format AVFoundation ikke kan åbne. Det er uden for denne plan.
- **Undo-menuen er stadig i stykker.** `IMPROVEMENT-LOG.md` (26. sep 2026): `registerUndo` returnerer ikke, og menulinjen kan ikke tage den private stak. Agent-undo må gå gennem toollet. At reparere menulinjen er et separat UI-arbejde og ikke en forudsætning for MCP.
- **Målingerne kan kun køres på en Mac.** Repoet er macOS 14+. Linux-CI kan kompilere ren logik i `StudioLaneCore`, ikke `AVPlayer`, VideoToolbox eller et rigtigt frame. GPU-succeskriterierne hører til på den maskine, der også eksporterer.
