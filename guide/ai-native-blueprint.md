# FineTune: The AI-Native Audio Layer — An Unsparing Blueprint

> A dual-lens (venture + CoreAudio systems engineering) teardown of the plan to evolve FineTune
> from a menu bar audio utility into an AI-native audio runtime. Every claim below is grounded
> in the current codebase; file/line references point at the real implementation.

## 0. The VC Cold Open: What You Actually Have

You do not have a multi-billion-dollar company. You have a **$29 Mac utility** in a category whose terminal comp is Rogue Amoeba — a beloved, profitable, *25-year-old lifestyle business*. SoundSource already does per-app volume and EQ. Nobody has venture-scaled a menu bar audio mixer, ever, and the reason is structural: the macOS installed base is ~100M, the audiophile-tinkerer intersection is low single-digit millions, and willingness-to-pay collapses past $50 one-time.

What you *actually* have — and this is the only thing in the deck worth funding — is one of the few production codebases on Earth that runs a fully lock-free, allocation-free, Swift 6 strict-concurrency DSP chain inside the CoreAudio HAL I/O thread across arbitrary third-party process taps. The RT discipline in `ProcessTapController.swift` (word-atomic `nonisolated(unsafe)` state, deferred-destruction coefficient swaps, equal-power crossfade promotion, health watchdogs) is the asset. The mixer UI is a demo.

The thesis that survives diligence: **the real-time audio path is the last unowned I/O channel on personal computers.** Vision is owned (camera/Vision framework), text is owned (LLMs everywhere), but the system audio stream — every app's output, the user's acoustic environment, 8+ hours/day of signal — has no intelligence layer. The company is "the inference-coupled audio runtime," not "a volume app."

Now the engineering teardown, because the vision as stated contains three fatal errors.

---

## 1. The Real-Time AI Audio Pipeline — Critical Teardown

### 1.1 The non-negotiable physics

At 48 kHz with a 512-frame I/O buffer, the HAL gives you **10.67 ms** per render cycle; process-tap configurations routinely run 128–480 frames, i.e. **2.7–10 ms**. Miss the deadline once and `coreaudiod` glitches; miss repeatedly and the HAL evicts you. The codebase's own RT constraint block (`ProcessTapController.swift`, "RT SAFETY CONSTRAINTS") — no malloc, no locks, no ObjC messaging, no I/O — is correct and absolute.

**Fatal error #1 in the vision: "run AI models alongside the audio tap."** CoreML cannot be invoked from the RT thread. Ever. `MLModel.prediction()` traverses Espresso, may XPC to `aned`, stages tensors through IOSurface, takes internal locks, and can page-fault on weight access. ANE dispatch latency is non-deterministic (hundreds of µs to tens of ms under contention) and the ANE has **no preemption or QoS contract** — you share it with every other ANE client on the system, scheduled by firmware in batches. An ANE call in the IOProc is not "risky"; it is a guaranteed dropout generator.

**Fatal error #2: Swift 6 isolation does not buy RT safety.** Actors serialize through queues/locks under the hood — touching *any* actor from the IOProc is a priority-inversion trap. The codebase already knows this (the `@MainActor` controller exposes a `nonisolated` callback reading word-atomic fields). The AI layer must extend that exact discipline, not introduce `await` anywhere near the render path.

**Fatal error #3: "dual-thread" is underspecified.** A second thread is not an architecture. What matters is the *contract* between planes: what crosses the boundary, in which direction, with what staleness tolerance, and what happens when inference is late.

### 1.2 The correct architecture: Dual-Plane, Staleness-Tolerant Inference

Replace "dual-thread" with **dual-plane**:

```
┌─────────────────────────────────────────────────────────────────┐
│ SIGNAL PLANE — deterministic, HAL RT thread                     │
│   tap IOProc → gain ramp → per-app EQ → [AI HOOK] → AutoEQ      │
│   → loudness chain → soft limiter                               │
│   • Only handwritten vDSP/BNNS kernels with fixed cycle budgets │
│   • Reads parameter snapshots; never waits, never allocates     │
│   • Writes PCM feature frames into SPSC ring (non-blocking)     │
├─────────────────────────────────────────────────────────────────┤
│ CONTROL PLANE — asynchronous, ANE/GPU via CoreML                │
│   InferenceCoordinator (actor) drains feature rings,            │
│   runs models on ANE, publishes ParameterSnapshots              │
│   • Allowed to be late, throttled, evicted, or crashed          │
│   • Output = control signals valid over 10–100 ms horizons      │
└─────────────────────────────────────────────────────────────────┘
```

**The core invariant: AI may be late; audio may not.** Every design decision falls out of it:

1. **Boundary primitive — SPSC lock-free ring buffers.** The RT thread is the single producer of feature frames (downsampled PCM, band energies, peak/RMS vectors — data the callback already computes for the VU meter); the inference thread is the single consumer. Indices are word-atomic `UInt32`s with acquire/release ordering — the same hardware-atomicity contract the codebase already documents in `ProcessTapController.swift`. Ring full? Drop the frame. Never block.

2. **Parameter delivery — snapshot pointer swap with deferred destruction.** The control plane publishes immutable `ParameterSnapshot` blocks (EQ coefficient sets, gain masks, spatial params) by atomically swapping a pointer; the old snapshot is freed after a grace period exceeding worst-case buffer duration. This is *exactly* `BiquadProcessor.swapSetup()`'s 500ms deferred-destroy pattern, already proven in production. Generalize it into an `AIParameterBus` (triple-buffered: one being written, one published, one being read).

3. **Temporal decoupling — interpolate, don't jump.** The RT thread treats AI outputs as setpoints and slews toward them with the existing exponential `rampCoefficient` machinery. If the control plane stalls (thermal throttle, ANE contention, model reload), the RT thread keeps interpolating toward the last snapshot — graceful staleness, zero dropouts. A `snapshotHostTime` field lets the RT side detect staleness > 500ms and decay toward neutral.

4. **Thread plumbing — os_workgroup, not QoS guesswork.** Any *auxiliary deterministic* DSP thread (e.g., a lookahead block processor) must join the device's I/O workgroup (`kAudioDevicePropertyIOThreadOSWorkgroup` → `os_workgroup_join`) so the kernel's EDF scheduler treats it as part of the audio deadline chain. The *inference* thread must NOT join the workgroup — it is explicitly not deadline-bound. It runs `.userInitiated`, pinned to a dedicated thread to avoid cooperative-pool starvation under Swift Concurrency.

5. **Memory discipline.** `mlock` model weights and all ring/snapshot arenas at activation (mirroring the existing pre-allocation in `activate()`); a page fault on the RT thread is a dropout. Model compilation (`MLModel.compileModel`) and a warmup inference happen off-line before a model is eligible for the bus — same philosophy as the crossfade warmup phase.

6. **Failure containment.** One word-atomic `_aiBypass: Bool` (sibling to `_forceSilence`) hard-gates every AI contribution; the deterministic chain is always a complete, bit-exact fallback. Extend the existing health watchdog (`hasRecentAudioCallback`) with an inference-staleness monitor that trips bypass automatically. The AI layer must be a *guest* in the pipeline, evictable in one store instruction.

### 1.3 Signal-rate AI: the only three honest options

Control-rate AI (above) is solved. **Signal-rate** AI — a neural net *in* the sample path, which Neural High-Fi requires — is where everyone lies in their pitch decks. There are exactly three honest options on Apple Silicon:

- **(a) BNNSGraph on the RT thread.** macOS 15's `BNNSGraph` is Apple's sanctioned real-time inference path: pre-compiled graph, caller-provided workspace, single-threaded, zero allocation, zero locks — designed explicitly for audio render contexts (it is what powers AUv3 ML effects). Budget rule: model compute ≤ **30% of the buffer period on a base M1 under thermal throttle**, leaving headroom for the existing DSP chain. That caps you at roughly 50–200k parameter TCN/GRU-class models per tap at 48kHz/128 frames. Small — but speech bandwidth-extension and noise-shaping nets fit.
- **(b) Block processing with lookahead.** Buffer N frames, infer, emit — adds N frames of latency. +10–20 ms is acceptable for *playback* enhancement (music, video with lipsync margin), unacceptable for monitoring. Requires the latency to be reported honestly (aggregate device latency properties) or A/V desync complaints will bury you.
- **(c) Hybrid envelope synthesis (the sleeper).** ANE asynchronously predicts *spectral envelopes* (cheap, control-rate); the RT thread performs deterministic synthesis shaped by those envelopes — noise-fill high-band regeneration the way SBR works in HE-AAC, but with a learned predictor. 90% of the perceptual win of (a) at 5% of the RT cost. This is the architecture Neural High-Fi should actually ship on.

ANE in-loop is not an option and never will be; the ANE is for the control plane.

---

## 2. Native AI Features — Graded, Not Worshipped

### 2.1 Acoustic Generative Upscaling ("Neural High-Fi") — Grade: B+, with an asterisk the size of a lawsuit

The DLSS analogy flatters you. DLSS works because rendering has ground truth (the engine can supersample); audio BWE is *hallucination* of content the codec destroyed. Two sub-markets, wildly different honesty profiles:

- **Speech BWE (Zoom, Teams, old videos, phone audio): real, shippable, magical.** 8→48 kHz speech super-resolution with <200k-param GRU/TCN models is mature literature; speech is low-entropy in the high band. Pipeline: per-tap **source classifier** on the control plane (spectral rolloff fingerprinting — AAC-LC's ~15.8 kHz cutoff, Opus's 20 kHz, telephone 3.4 kHz — plus app bundle ID as a prior, which FineTune uniquely has via the process tap) → engage hybrid envelope synthesis (1.3c) or BNNS micro-model (1.3a). Insert at the AI hook between per-app EQ and AutoEQ in `processMappedBuffers`.
- **Music "remastering": placebo-merchant territory.** Users cannot ABX most of it; reviewers can, and they will destroy you. Ship only with a built-in blind A/B test harness in the UI. Counterintuitively, that honesty becomes marketing.

VC note: "make Zoom calls sound like FaceTime HD" is a demo that closes a seed round. "AI remasters your FLACs" is a demo that closes your credibility.

### 2.2 Cognitive Auditory Ducking & Load Shifting — Grade: A−, the actual company

This is the defensible one, because it requires a *cross-app behavioral signal fusion* position that Apple's privacy theater makes awkward for Apple itself and that no audio plugin (which sees only its own stream) can replicate.

- **Context engine (control plane, zero RT risk):** frontmost app + window title (Accessibility API), typing cadence and burst entropy (CGEventTap — yes, another TCC prompt; see §4), build/error state from IDE integrations, calendar state, display focus. Fuse into a 3–5 state classifier (deep-focus / collaborative / ambient / interrupted) — a tiny temporal model on the ANE, inference every 500 ms. This is *exactly* what the parameter bus was built for.
- **Actuation through machinery that already exists:** focus-state transitions drive per-app gain trims (`_volume` path), EQ coefficient morphs (`swapSetup`), and loudness profile changes — all slewed by the RT interpolator so a state flip is a 2-second seamless morph, never a jump cut. The crossfade state machine generalizes from "device switch" to "cognitive state switch."
- **The "transform music into a focus soundscape without changing the track" claim needs an honesty pass:** true stem separation at signal rate is a per-tap Demucs — computationally obscene. The shippable version is **multiband spectral reshaping + transient suppression + stereo field narrowing** (deterministic vDSP, parameterized by the focus classifier): vocals de-emphasized, transients softened, energy folded toward low-mids. 80% of the perceived effect, 5% of the cost, zero dropout risk. Market it as "Focus Render," not fake stem separation.

### 2.3 Biometric Hearing Twin — Grade: B for tech, A for moat, D for go-to-market naivety

- **Dosimetry is nearly free and you should be embarrassed it's not built yet.** The render callback already computes per-buffer peaks with EMA smoothing. Extending that into A-weighted LAeq integration + daily sound-dose accounting (WHO/ITU-T H.870 model) is a weekend of DSP and zero new permissions. It also creates the *longitudinal per-user dataset* the moat in §4 depends on.
- **Room acoustics via microphone is a trust cliff.** An unsandboxed audio utility that already holds the audio-capture TCC grant now wants ambient mic access? That's a PR landmine ("volume app is listening to your room"). Constraints: explicit opt-in, on-device only, measurement *sessions* (user-triggered sweep/MMM measurement → RT60/early-reflection estimate) rather than always-on listening. Technically: log-sweep deconvolution for RIR, magnitude-only correction below ~500 Hz where room modes dominate, folded into the existing `AutoEQProcessor` profile path — the delivery mechanism already exists.
- **The Twin is the data product:** room profile + hearing dose history + preference trajectory + per-app listening habits = a portable acoustic identity. Apple has dosimetry (AirPods) and Adaptive Audio, but it's trapped per-device and not exposed; your version spans every app and every output device. That's the wedge — and the Sherlock target, see §4.

### 2.4 The "Front-Row" Spatial Engine (Acoustic Time Machine) — Grade: A− for the demo, with one dirty secret

The dirty secret: 90% of this feature is not AI — it's classic, deterministic, *excellent* DSP, and that's exactly why it ships. **Partitioned convolution reverb** (uniform-partition overlap-save via vDSP FFT) against measured festival/arena impulse responses is fully RT-budgetable on the signal plane; the catch is tail length — a stadium IR runs 2–4 seconds, so use a **hybrid topology**: convolved early reflections (first 80–120 ms, the part that encodes "where you are standing") + a feedback delay network for the tail. Sub-bass "chest" comes from psychoacoustic harmonic bass synthesis (MaxxBass-style nonlinear harmonic generation — pure waveshaping, deterministic); crowd bed is gain-staged sample playback through the existing output chain.

Where the AI actually earns its name (control plane): **content-adaptive venue rendering** — the source classifier from §2.1 estimates genre/energy/vocal presence and continuously morphs IR selection, wet/dry, crowd density, and stage distance via the parameter bus, so a ballad and a drop don't get the same room. IR *interpolation* between venue models ("move from the soundboard to the barricade" as a slider) is the patentable bit. Position the convolution stage at the AI hook; report added latency honestly through the aggregate device.

One correction to the "use Apple Silicon's GPU" framing: **the GPU is the wrong processor for in-loop convolution.** Metal command-buffer dispatch latency is non-deterministic (scheduler queuing, preemption by WindowServer) — the same class of sin as ANE-in-the-IOProc. Real-time partitioned convolution runs on CPU vDSP FFT, where the codebase already lives; the GPU's legitimate jobs here are *offline* — IR preprocessing, partition planning, and venue-model interpolation tables baked before playback. The moat framing survives the correction: Apple's Spatial Audio is Atmos object panning; measured-venue generative acoustics ("an acoustic time machine," not a wider stereo image) is a genuinely different product, and the marketing line writes itself. VC verdict: this is the toggle that sells the app in a 15-second TikTok. Build it third-party-demo-proof before building anything else flashy.

### 2.5 Autonomous "Flow State" Orchestration / The Zero-UI Agentic Context Engine — Grade: A− engineering, D− pitch language (fix it before legal does)

This is §2.2 promoted from *tool* to *agent*, and the agentic framing is right: the context engine (window-focus dwell, typing cadence entropy, app class) runs as a background policy agent that *acts* — no toggles, no prompts, ideally an app the user never opens. The strategic framing worth keeping verbatim: third-party apps become *nodes* in your orchestration graph — **Apple has Universal Control for hardware; you have Universal Context for software.** That line belongs in the deck because it names the structural position: FineTune is the only process on the machine that simultaneously observes every app's audio output *and* can actuate on each stream independently. Two parts of the spec as written are gold, one is a liability:

- **Gold #1 — notification suppression as policy.** Because FineTune holds a *per-process* tap on every app, it can do what no plugin can: when focus score exceeds threshold, the Slack/Teams/Messages taps get their own gain trim (existing `_volume` path, slewed), deferring the ping without touching the OS notification system. This is "Do Not Disturb for the ears" and it's a weekend of work on top of the context engine.
- **Gold #2 — transient suppression + dynamic-range narrowing** during deep work: deterministic multiband compression and transient shaping driven by the focus classifier, exactly the "Focus Render" reshaping already specced in §2.2. Sudden snare hits and mix drops are objectively measurable distractors; suppressing them needs no neuroscience claims.
- **The liability — "beta-wave-inducing frequencies (12–30 Hz)."** Beta waves are *EEG* bands, not audio bands; 12–30 Hz acoustic content is at the threshold of audibility, and the adjacent claim space (binaural beats entrainment) has weak, contested evidence. Marketing "Auditory Adderall" is an FTC health-claim action and an App-Store-of-public-opinion disaster in one phrase. Ship the *measurable* claims (distraction-event reduction, interruption deferral) and let users report the focus magic themselves. The feature is strong enough to survive honesty.

### 2.6 Biometric DSP (The Adrenaline Curve) — Grade: B+ tech, C market fit on a Mac, A in Phase 2

Engineering is the easy part and maps 1:1 onto the architecture: real-time heart rate → cardiovascular zone → pre-compiled `vDSP_biquad` coefficient set + loudness profile, published through the parameter bus and slewed by the RT interpolator. Two corrections to the spec:

- **HealthKit does not exist on macOS.** Real-time HR on a Mac comes from (a) standard **BLE Heart Rate Profile (GATT 0x180D)** — Polar/Garmin/Wahoo straps and most watches broadcast it, CoreBluetooth on macOS reads it natively, zero partnership needed; (b) a companion iPhone/Watch app relaying via Watch Connectivity; (c) Whoop's API (cloud, laggy — fine for trends, wrong for rep-by-rep). Build on (a).
- **The cynical question: who lifts heavy at a desktop Mac?** The gym scenario lives on iPhone/Watch — where the Process Tap API *does not exist*. On macOS the honest use cases are Peloton/Zwift-at-the-desk, walking pads, and the inverse direction nobody pitched: **stress-responsive calm-down rendering during work** (HR elevation during an incident postmortem → soften transients, widen, slow the morphs). That inverse feature composes with §2.5 into one biometric-aware focus agent and is unique to the desktop context.

Strategically this feature is a sleeper for **Phase 2**: the AI-DAC dongle is host-independent and travels to the gym; "the first audio hardware that syncs to your cardiovascular system" is a hardware launch headline, not a menu bar checkbox. The moat claim ("turning standard headphones into biometric-responsive hardware") is real but only compounds when the zone→DSP mapping is *learned per user* from Twin data — adrenaline response to sub-bass is individual; a static zone table is a gimmick anyone clones in a week, a personalized adrenaline curve trained on months of your sessions is not.

### 2.7 Semantic "Ad-Block for Reality" — Grade: A+ virality, and the most architecturally dishonest spec in the deck. Fix it like this.

The teardown first: **"analyzing the audio stream 500 ms ahead of the user's perception" is physically impossible for live audio without making it not-live.** There is no future audio to analyze; to look ahead you must *create* lookahead by inserting a delay line in the tapped stream. That is a real, viable design — own it instead of hand-waving it:

- **Lookahead mode (podcasts, audio-only):** per-tap delay ring of 1–3 s (pre-allocated, RT-safe — it's just a circular buffer in the signal plane). The control plane classifies the *head* of the buffer while the user hears the *tail*; ad onset triggers the existing crossfade state machine to duck into the lo-fi bed *before* the sponsor read reaches the ears. Latency is irrelevant for podcasts. **For video it breaks lip sync** — so video gets **reactive mode**: fast classifier (~1–2 s detection lag), fade on detect, fade back on content resume. Users tolerate hearing one second of "this episode is brought to—" far better than desynced mouths.
- **Detection stack (control plane, ANE):** three fused signals — (1) acoustic fingerprints of ad production (loudness-war compression density, LUFS jump, music-bed signatures); (2) **on-device streaming ASR** (Whisper-tiny-class) feeding a sponsor-cadence text classifier ("...is sponsored by," "use code," "back to the show"); (3) crowdsourced timestamp priors à la SponsorBlock for known content (per-app bundle ID + stream metadata as the join key). Each signal alone is mediocre; fused, the precision gets shippable. False-positive cost is high (ducking the actual content is rage-uninstall territory) — bias conservative, expose a per-app sensitivity policy, and log every trigger for one-tap "that wasn't an ad" feedback that retrains the prior.
- **The risk ledger (this one earns its own entry in §4):** users processing their own local audio is legally defensible (the SponsorBlock/DVR-skip lineage), but expect platform hostility — YouTube/Spotify ToS fights, sponsor-industry PR, and possible countermeasures (ad audio engineered to mimic content). You are picking a fight with the attention economy using a menu bar app. As a VC I love it *and* I'm pricing in the legal budget: ship it as user-configured policy ("Smart Skip") rather than default-on, and never market it as "ad-block" — market it as *semantic volume policy* (§2.8), of which ad-ducking is merely the most popular policy.
- **The brand play that survives all of the above: "Acoustic Consent."** Apple built a decade of brand equity on App Tracking Transparency; the analogous position here is *the user decides what meaning is allowed to enter their ears, at the system level*. An "auditory firewall" framing (user-authored semantic policies, of which ad-ducking is one) is defensible in court, in press, and in the App-Store-of-public-opinion in ways "we block ads" never will be — and it generalizes the feature into the policy platform §2.8 describes instead of a single cat-and-mouse fight.

### 2.8 Two features the vision missed (free of charge)

- **Semantic Volume:** because FineTune sits per-process, it can learn *what kind of content* each app emits over time and offer policy, not gain: "never let notifications exceed speech by more than 6 dB," "duck music under any detected voice in any app." Volume becomes intent. Cheap (control plane classifiers), demoable, patentable as a policy-actuation layer.
- **Acoustic Scene Memory:** snapshot the entire mixer + EQ + routing + focus state as embeddings; auto-recall when context recurs ("Tuesday standup," "late-night editing"). Pure control plane, pure retention feature.

---

## 3. The 10-Decade Plan — Translated From Fantasy Into Option Tree

VC reality check: nobody plans 10 decades; Apple doesn't plan 10 *years*. What you build is an option tree where each phase is independently profitable and purchases the right to attempt the next. Here is the technically honest version.

### Phase 1 (Years 0–4): The OS Dominance Layer — headless audio runtime + SDK

- **Extract `FineTuneKit`:** split the engine (taps, aggregate devices, DSP chain, AIParameterBus) from the menu bar app into a headless framework + LaunchAgent audio server, with the app as first client. The current `AudioEngine.swift` (99KB God-object orchestrator) must be decomposed anyway — this is the forcing function.
- **The architectural landmine nobody in the room has noticed:** the "obvious" maturation path — shipping a virtual `AudioServerPlugIn` HAL driver instead of per-process taps — moves your code *into `coreaudiod`'s sandbox*, where CoreML/ANE access is unavailable and even file I/O is restricted. Therefore the AI layer can never live in the driver: the design is a thin RT shim in `coreaudiod` connected by **shared-memory rings (the same SPSC primitive from §1.2) to a user-space AI daemon**. Decide this boundary now; retrofitting it is a rewrite.
- **SDK surface:** third parties get (a) control-plane API — publish context signals, subscribe to acoustic state, register parameter policies; (b) signal-plane API — submit BNNSGraph-compatible model packages that pass an automated RT-budget certification harness (cycle-count attestation per buffer size/chip generation) before they're eligible to load. The certification harness *is* the platform — it's what App Review is to iOS.
- **Business:** the app stays $29–49; the runtime is free; monetization is model marketplace rake + Pro subscription (Hearing Twin sync, team policies). Kill criterion: if third-party SDK adoption is <100 serious integrations by year 3, you are a feature, not a platform — sell to Adobe or Rogue Amoeba's acquirer and go home.

### Phase 2 (Years 4–12): Edge Silicon Co-Processor ("AI-DAC")

- The cynical truth first: **hardware is where software margins go to die.** Inventory, CE/FCC certification, support, returns. You earn the right to attempt this only if Phase 1 proves users *pay recurring money* for AI audio processing.
- The technically sound version is not "custom silicon" (a $50M+ tapeout fantasy) but a **reference design + licensed runtime**: a USB-C UAC2 class-compliant DAC with an off-the-shelf NPU-bearing SoC running your model runtime and parameter-bus protocol. Host independence is real — the DSP/AI chain follows the user to a work-locked MacBook, an iPad, a Windows box. Build it with an established DAC ODM; your IP is the runtime + model format + Twin sync, never the PCB.
- Custom silicon (a true "AI-DAC" ASIC) is a Phase 2.5 decision gated on >1M units of the reference design. Anything else is cosplay.

### Phase 3 (Years 12+): The Ubiquitous Auditory Interface

- The honest framing: audio as a *continuous, low-attention output channel for ambient computing* — not "replacing screens" (screens win at random-access information density; audio wins at peripheral awareness, temporal pattern, and zero-gaze interaction).
- What carries forward technically: the dual-plane runtime becomes the **personal acoustic context engine** — a persistent process that knows the user's hearing model (Twin), environment (room/scene state), and attention state (cognitive engine), and renders *all* machine-to-human audio through it: notifications as a learned sonic language, spatial anchors for persistent tasks, presence rendering for remote collaborators. Every OS, wearable, and vehicle becomes a render target for the same Twin.
- This phase is unfundable today and that's fine; it exists to give Phases 1–2 a direction of travel. The Twin data corpus is the only artifact from year 1 that is still the moat in year 30.

---

## 4. Adversarial Risk Assessment & Moat Formulation

### 4.1 The kill list, ranked by probability × severity

1. **Apple Sherlocks the mixer (near-certainty, eventually).** Per-app volume is one System Settings checkbox away — Apple built `CATapDescription` for itself first. Severity depends entirely on whether your value has migrated *above* the mixer (context intelligence, Twin, SDK) by the time it happens. If your pitch is still "per-app volume + EQ" when it ships, you're dead and deserved it.
2. **Platform rug-pull (high impact, moderate probability).** You are unsandboxed, Developer-ID-distributed, dependent on a TCC audio-capture grant and an API (`AudioHardwareCreateProcessTap`) Apple could fence behind a new entitlement in any macOS release. Mitigations: dual capture strategy (process taps *and* the AudioServerPlugIn virtual-device path — different policy regimes), pristine notarization standing, and a real relationship with CoreAudio DTS. Also the honest one: this risk is unhedgeable and belongs in the risk disclosure, not under the rug.
3. **Compute/battery tax (high probability, churn-shaped).** Always-on ANE inference + per-tap DSP on a MacBook Air shows up in the Battery menu as *you*. Hard budgets: control plane ≤ 1% CPU-equivalent average, inference duty-cycled to activity, models throttle to slower cadence on battery. Instrument this from day one; "FineTune drained my battery" Reddit threads are how utility companies die.
4. **TCC prompt fatigue.** Audio capture + mic + Accessibility + input monitoring = four scary dialogs. Stage them per-feature at the moment of value ("enable Focus Render → needs X"), never at onboarding.
5. **Open-source fragmentation / clone risk.** The tap+aggregate technique is now documented in your own open code and others'. The engine *will* be commoditized; plan for it (next section) instead of pretending otherwise.
6. **Placebo backlash** (§2.1) — self-inflicted, fully avoidable via the blind A/B harness.
7. **Platform/legal retaliation over ad-ducking (§2.7).** ToS conflicts with YouTube/Spotify, sponsor-industry pressure, and adversarial ad audio engineered to evade classifiers. Mitigations: user-configured policy framing (never default-on, never marketed as "ad-block"), local-only processing, conservative false-positive bias, and a legal opinion *before* launch, not after the takedown letter.
8. **Health-claim exposure (§2.5, §2.6).** "Auditory Adderall" / brainwave-entrainment language invites FTC scrutiny. Market measurable acoustics (distraction-event suppression, interruption deferral, zone-mapped rendering), never neurological or therapeutic outcomes.

### 4.2 Moat construction: open-core split, IP, and the only durable asset

**Open (Apache-2.0/MIT — commoditize the complement, recruit the ecosystem):**
- The RT engine: tap management, aggregate device handling, crossfade machinery, the SPSC ring + parameter-bus primitives, the RT-safety certification harness.
- The SDK surface and model package format (open *spec*, you control the reference implementation and certification).
- Rationale: this layer will be replicated anyway; owning the canonical implementation means every competitor builds on your abstractions, your conformance suite, your governance. Kubernetes economics, audio edition.

**Closed (the company):**
- All trained models: BWE nets, focus classifiers, scene embeddings — and crucially the *training/eval corpora and the ABX-validated perceptual test battery* behind them.
- The Hearing Twin: per-user acoustic identity, dose history, preference trajectories, room profiles, and its cross-device sync. **This is the moat.** It compounds daily, it's useless to copy without the history, and it makes switching cost personal: leaving FineTune means abandoning a multi-year model of your own hearing.
- The certification authority for the model marketplace (the rake, and the quality bar).

**IP posture (realistic for a startup vs. Goliath):** patents don't stop Apple; they price an acquisition and deter mid-size copycats. File narrowly on: (1) staleness-tolerant dual-plane parameter inference for RT audio (the §1.2 contract), (2) cognitive-state-driven seamless audio morphing (crossfade-as-state-transition), (3) hearing-twin-derived dynamic DSP mask generation. Trademark "Hearing Twin" aggressively — the brand for the data product outlives any single technique. And the unglamorous truth: your strongest defense is *cadence* — shipping perceptually validated models faster than a platform org can route them through privacy review.

---

## 5. The Delivery Roadmap — One Feature Per PR, No Dumps

Engineering doctrine for every PR below: **one reviewable concern per PR (~200–600 net LOC)**, feature-flagged off by default, unit tests in `FineTuneTests` landing in the *same* PR, zero regression to the RT-safety contract (no new allocations/locks on the I/O thread, verified via Instruments signposts and a callback-duration assertion test), and protocol-seamed for testability following the existing `ProcessTapControlling` pattern. Each track is sequential internally; tracks are parallelizable after Track 0 lands. No PR depends on an unmerged PR.

### Track 0 — The Dual-Plane Foundation (everything depends on this; merge first, soak longest)

| PR | Scope | ~LOC | Key contents |
|---|---|---|---|
| **PR-1** | `AIParameterBus` | 300 | Triple-buffered atomic snapshot publish/consume primitive with deferred destruction (modeled on `BiquadProcessor.swapSetup`'s 500 ms grace pattern); `ParameterSnapshot` value type; staleness timestamping via `mach_absolute_time`. Pure data structure + exhaustive unit tests (concurrent publish/read stress test). No pipeline integration yet. |
| **PR-2** | `PCMFeatureRing` | 350 | SPSC lock-free ring (word-atomic indices, acquire/release ordering, drop-on-full); feature-frame extraction (peak/RMS/band energies) reusing the VU-meter computation path. Unit tests including a producer/consumer race harness. |
| **PR-3** | AI hook + bypass + watchdog | 250 | No-op AI hook point in `processMappedBuffers` between per-app EQ and AutoEQ; word-atomic `_aiBypass` (sibling to `_forceSilence`); staleness monitor wired into the existing `hasRecentAudioCallback` health-check family; `os_signpost` instrumentation of callback duration. This is the PR where RT-safety review is the whole review. |
| **PR-4** | `InferenceCoordinator` | 400 | Control-plane actor: model lifecycle (compile → `mlock` weights → warmup inference → eligible), dedicated pinned inference thread (not the cooperative pool), snapshot publishing into `AIParameterBus`, automatic bypass-trip on staleness. Ships with a stub model; no user-facing feature. |

### Track A — Zero-UI Context Engine → Focus Render (§2.2/§2.5) — control-plane only, ships first

| PR | Scope | ~LOC | Key contents |
|---|---|---|---|
| **PR-5** | Context signal collectors | 400 | Frontmost-app + window-dwell via `NSWorkspace`; typing-cadence entropy via `CGEventTap` behind a staged TCC gate (permission requested at feature-enable, never at onboarding); collectors behind a `ContextSignalProviding` protocol so tests inject synthetic signals. |
| **PR-6** | Focus-state classifier | 300 | Heuristic state machine first (deep-focus/ambient/interrupted with hysteresis + minimum dwell), CoreML temporal model swappable behind the same protocol later. Classifier emits states onto the bus at 500 ms cadence. |
| **PR-7** | Focus Render actuation + UI | 450 | State→policy mapping: per-app gain trims for notification-class apps (existing `_volume` path), EQ coefficient morphs via `swapSetup`, 2 s slewed transitions through existing ramp machinery; settings pane + feature flag UI. First user-visible AI feature. |

### Track B — Hearing Twin v0: Dosimetry (§2.3) — zero new permissions, starts the data moat

| PR | Scope | ~LOC | Key contents |
|---|---|---|---|
| **PR-8** | LAeq dose engine | 300 | A-weighted LAeq accumulator extending the existing peak/EMA path in the render callback (one extra filter + accumulation, RT-budgeted); WHO/ITU-T H.870 daily-dose model; persistence via `SettingsManager`'s versioned JSON (bump settings version). |
| **PR-9** | Dose surface | 250 | Settings-pane dose view + menu bar daily summary; export. Deliberately boring UI; the asset is the longitudinal data. |

### Track C — Front-Row Spatial Engine (§2.4) — first signal-plane feature, gated on Track 0 soak

| PR | Scope | ~LOC | Key contents |
|---|---|---|---|
| **PR-10** | Partitioned convolution core | 500 | Uniform-partition overlap-save engine on vDSP FFT; pre-allocated partition workspaces; cycle-budget bench at 128-frame buffers on base-M1-class hardware committed as a perf test. Engine only — not yet in the pipeline. |
| **PR-11** | Hybrid tail + bass synth | 400 | FDN late-reverb tail; psychoacoustic harmonic bass synthesis (waveshaping); both as `@unchecked Sendable` processors following the `BiquadProcessor` ownership pattern. |
| **PR-12** | Venue rendering + toggle | 400 | Three venue IR assets, control-plane adaptive morphing (wet/dry, stage distance) via the bus, latency reporting through the aggregate device, one-toggle UI. The TikTok demo PR. |

### Track D — Biometric DSP (§2.6) — small, independent, composes with Track A

| PR | Scope | ~LOC | Key contents |
|---|---|---|---|
| **PR-13** | BLE heart-rate ingestion | 300 | CoreBluetooth GATT 0x180D (Heart Rate Profile) service behind a `BiometricSignalProviding` protocol; device pairing UI reusing existing Bluetooth entitlement; synthetic-HR test injector. |
| **PR-14** | Zone→DSP policy | 250 | Cardio-zone mapping to pre-compiled coefficient sets published via the bus; inverse "calm-down" policy composing with PR-6 focus states. |

### Track E — Smart Skip / Auditory Firewall (§2.7) — last, because its failure mode is user trust

| PR | Scope | ~LOC | Key contents |
|---|---|---|---|
| **PR-15** | Detection eval harness | 400 | Offline labeled sponsor-read corpus + precision/recall harness in `FineTuneTests`; streaming classifier scaffold on the control plane. **Merge gate for PR-16 is a measured precision number, not vibes.** |
| **PR-16** | Reactive ducking + policy UI | 350 | Classifier verdicts drive the existing crossfade state machine; per-app opt-in policy UI; one-tap false-positive feedback logging. Reactive mode only. |
| **PR-17** | Lookahead mode | 400 | Per-tap pre-allocated delay ring (1–3 s) for audio-only apps; classify-at-head/play-at-tail; explicit latency disclosure in UI. Only after PR-16 field data justifies it. |

### Track F — Speech BWE (§2.1) — research-gated, no committed PRs until the spike passes

| PR | Scope | ~LOC | Key contents |
|---|---|---|---|
| **PR-18** | BWE eval spike | 400 | BNNSGraph GRU model offline harness: ABX battery + PESQ-style metrics + RT cycle budgets measured on M1/M2/M3. Go/no-go artifact; pipeline integration PRs are specced only if it passes. |

**Sequencing logic:** Track 0 merges first and soaks under telemetry while Tracks A/B (control-plane-only, zero dropout risk) deliver user-visible value. Track C is the first signal-plane feature and inherits a hardened bus. Track E ships last and gated on measured detection precision. Tracks B's dose data and A's context states are what make D and the eventual Twin personalization compound. At ~17 PRs averaging ~350 LOC, this is roughly two quarters for a two-engineer team holding a flawless-or-flagged bar — which is the correct bar, because in this product a single audible glitch costs more trust than a missing feature.
