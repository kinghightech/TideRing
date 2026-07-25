# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Tide** is an iOS app (iOS 26.5+) that collects and visualizes health metrics from a Oura Ring-like wearable device via Bluetooth. It uses SwiftUI for the UI and maintains a local-only data store (no backend/network layer).

**Bundle ID:** `com.aahish.ringmvp`  
**Swift Version:** 5.0 with strict concurrency enabled  
**Key Dependencies:** SwiftUI, CoreBluetooth (no CocoaPods or SPM packages)

## Project Structure

```
tide/
├── Ring/                      # Bluetooth and protocol layer
│   ├── RingManager.swift      # Central Bluetooth coordinator (~32KB)
│   ├── RingProtocol.swift     # Byte-level JRing protocol (~28KB)
│   ├── RingStore.swift        # Local JSON data persistence
│   ├── RingEnums.swift        # Connection state, measurement types, sleep stages
│   ├── JringClock.swift       # Protocol timestamp handling
│   └── RingEventGate.swift    # Event sequencing
├── Views/                     # SwiftUI components
│   ├── ContentView.swift      # App entry point (onboarding gate)
│   ├── SummaryView.swift      # Home tab, forces dark mode
│   ├── TrendsView.swift       # Historical data charts
│   ├── TideCameraView.swift   # Remote camera shutter
│   ├── SettingsView.swift     # Settings and Ring connection UI
│   ├── TideDesign.swift       # Design language (fonts, colors, glass effects)
│   ├── TideKit.swift          # Shared UI components
│   ├── RingConnectionView.swift # Ring pairing/connection flow
│   ├── MetricDetailView.swift # Detail view for individual metrics
│   ├── Onboarding/            # Onboarding flow
│   └── Settings/              # Settings sub-views
├── Assets.xcassets/           # Images and color sets
├── ringmvpApp.swift           # Main app entry point
└── TideNotificationService.swift # Notification handling

ringmvp.xcodeproj/            # Xcode project (single target: ringmvp)
```

## Architecture & Design

### Ring Module: Bluetooth + Data

**RingManager** (@MainActor) is the single point of contact for all Bluetooth operations. It owns:
- **Connection state machine:** idle → scanning → connecting → connected (or reconnecting/failed)
- **CoreBluetooth plumbing** for peripheral discovery and connection
- **Command sequencing** (startup, bind, measurement flows) ported from PulseLoop
- **Publish-Subscribe for UI:** @Published state for battery, HR, firmware, connection status, etc.
- **Ring settings** (name, age, height, weight, HR interval, goals) persisted via @Published didSet

**RingProtocol** decodes/encodes byte-level frames (0x06, 0x11, etc.) and handles the JRing protocol. It works bidirectionally with RingManager to produce readings.

**RingStore** is the app's entire persistence layer:
- Holds readings in memory, mirrored to a single JSON file in Application Support
- Models: `RingReading` (scalar measurements), `BloodPressureReading`, `ExtraMeasurement` (stress/HRV/temp/fatigue/glucose), `SleepBlock`, `DailyActivity`
- Sleep is grouped into nights by wake date (matching PulseLoop)
- Activity is both live ("today") and per-day history

**RingEnums** and **JringClock** define the protocol's types and timestamp handling.

### Views: SwiftUI UI

- **ContentView** checks `tide.onboardingComplete` (AppStorage) and conditionally shows OnboardingFlow or MainTabView
- **MainTabView** is the tab bar (Home/Trends/Camera/Settings) after onboarding, owns RingManager
- **SummaryView** (Home) forces `.preferredColorScheme(.dark)` for its subtree; navigation destinations pushed from it follow the system setting
- **TideDesign** defines the "Liquid Glass" language with iOS 26's `.glass` effect APIs, custom fonts (PP Editorial New serif + Akkurat sans with system fallbacks), and the cyan-blue accent palette
- **TideKit** holds reusable components (likely cards, buttons, etc.)

### Key Design Decisions

1. **Strict Concurrency:** `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`. All state mutation must be on MainActor.
2. **No Backend:** Everything is local. RingStore writes to the app's sandbox (Application Support directory).
3. **No External Packages:** CoreBluetooth only; SwiftUI/Foundation.
4. **Protocol Portability:** The JRing protocol is ported from PulseLoop to ensure on-the-wire compatibility. This code is licensed CC BY 4.0.
5. **Dark Mode:** Home screen forces dark; other destinations respect system preference (see ContentView comment).

## Building & Running

Open `ringmvp.xcodeproj` in Xcode and build/run on a physical device (iOS 26.5+) or simulator.

```bash
# Build from CLI
xcodebuild -scheme ringmvp -configuration Debug build

# Run on simulator
xcodebuild -scheme ringmvp -configuration Debug test

# Archive for distribution
xcodebuild -scheme ringmvp -configuration Release archive
```

**Environment Variables:**
- `TIDE_TAB`: Set to override the initial selected tab (0 = Home, 1 = Trends, 2 = Camera, 3 = Settings) in MainTabView for testing.

## Data & Persistence

### In-Memory Models (RingStore)
- **RingReading:** value, date, source ("live", "history", "manual") — unified series like Apple Health
- **SleepBlock:** stageRaw, start, minutes — grouped into SleepNight by wake date
- **DailyActivity:** steps, distanceMeters, calories per day
- **ActivityRecord:** live "today" cumulative snapshot

### Persisted Settings (RingSettings via @Published)
User-tunable: name, age, isMale, height, weight, HR interval, step/calorie/sleep goals, BP calibration, app identifier.

### File Location
Single JSON file in Application Support directory, mirrored from memory whenever RingStore changes.

## Common Development Tasks

### Adding a New Metric

1. Define the reading model in **RingStore.swift** (e.g., `struct NewMetricReading`).
2. Add the measurement kind to **RingEnums.swift** (e.g., `case newMetric` in `MeasurementKind`).
3. Add a @Published property to **RingManager** (e.g., `@Published var newMetricValue: Double?`).
4. Decode frames in **RingProtocol.swift** and update RingManager via delegation.
5. Add a chart/detail view in **Views/** and reference it in **SummaryView** or **TrendsView**.

### Connecting to the Ring

- **Auto-connect:** On app launch, MainTabView calls `manager.connectLastKnown()` if not already connected.
- **Manual pairing:** RingConnectionView handles discovery and connection.
- Connection state is observed via `manager.connectionState` (@Published).

### Customizing Design

All typography, colors, and effects are in **TideDesign.swift**:
- `TideFont.serif()` and `TideFont.sans()` provide custom fonts with system fallbacks.
- `TideColors` enum defines the accent and glow palette.
- Glass effects use iOS 26's `.glass` API directly (no availability guards needed).

## Testing Notes

- No test target yet (single Xcode project, no SPM).
- Manual testing on device recommended due to Bluetooth dependency.
- Environment variable `TIDE_TAB` can be set to test tab navigation without UI interaction.

## Important Caveats

1. **Bluetooth:** Requires a real Ring or compatible device on a physical iPhone (simulator BLE is limited).
2. **Permissions:** App must request Bluetooth permission; also location for background HR scanning (iOS requirement).
3. **MainActor Isolation:** All UI state and RingManager operations are MainActor-isolated. Do not call from background threads.
4. **Protocol Brittleness:** Byte-level protocol changes require careful coordination with the ring firmware. Ported code is from PulseLoop; deviations may break compatibility.

## Further Reading

- **RingManager.swift:** Head comment explains the consolidation and credits PulseLoop.
- **RingProtocol.swift:** Decodes 0x06 (measurement), 0x11 (sleep timeline), and other frames.
- **RingStore.swift:** Explains the data model and JSON persistence strategy.
- **TideDesign.swift:** Notes on font fallbacks and iOS 26 APIs.
- **ContentView.swift:** Comment on dark mode override strategy.
