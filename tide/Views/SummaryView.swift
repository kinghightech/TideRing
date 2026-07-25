//
//  SummaryView.swift
//  Tide
//
//  The home tab (Oura-style). A full-bleed ocean image that SCROLLS with the content and fades on the
//  sides and bottom into deep ocean. A clean row of daily scores (Sleep / Activity / Calories) up top
//  (no glass box), a shallow semi-circle readiness arc with the score + copy under it, then "Today's
//  highlights" as Liquid Glass cards below.
//
//  The three top scores are live progress for today. Readiness is a persisted daily wellness score
//  calculated from last night's sleep and yesterday's completed activity after history sync.
//

import SwiftUI

struct SummaryView: View {
    @ObservedObject var manager: RingManager
    @ObservedObject var store: RingStore
    /// Jumps to the Trends tab (used by "See insights" / "View all").
    var onSeeTrends: () -> Void = {}
    /// Opens the dedicated Vitals tab from the home shortcut.
    var onViewVitals: () -> Void = {}

    private let grid = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    private var readinessSnapshot: TideReadinessSnapshot? { store.readinessSnapshot(forToday: Date()) }
    private var readiness: Int? { readinessSnapshot?.score }
    private var todayActivity: ActivityRecord? { store.todayActivityRecord() }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    ZStack(alignment: .top) {
                        // Backdrop scrolls WITH the content (it lives inside the scroll).
                        HomeBackdrop(width: geo.size.width)
                        VStack(spacing: 0) {
                            heroSection(topInset: geo.safeAreaInsets.top)
                            highlightsSection
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // ScrollView bleeds under the status bar; the GeometryReader (outside this) still
                // reports the real top inset, which we pad the greeting by.
                .ignoresSafeArea(edges: .top)
            }
            .background(TideColors.deepOcean.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            // Render the home CONTENT in dark (dark glass over the ocean) via an ENVIRONMENT override,
            // not preferredColorScheme — the latter overrides the whole window and would force every
            // other tab/page dark too (breaking light mode). This scopes dark to the home content only.
            .environment(\.colorScheme, .dark)
            .onAppear {
                seedIfRequested()
                // Repair an incomplete snapshot as soon as Home opens. This covers users who
                // already have yesterday's sleep/activity stored from a later history packet.
                store.freezeTodayReadiness(settings: manager.settings)
            }
        }
    }

    // MARK: - Hero

    private func heroSection(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(greeting)
                        .font(TideFont.sans(20, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("Ready to make today count.")
                        .font(TideFont.sans(13))
                        .foregroundStyle(.white.opacity(0.68))
                }
                // The greeting uses minimumScaleFactor, which re-resolves as the header's width settles
                // on re-appear (e.g. the connection pill changing width). Kill implicit animations here
                // so the text snaps to its final size instead of visibly scaling from small → large.
                .transaction { $0.animation = nil }
                Spacer(minLength: 8)
                RingConnectionPill(manager: manager)
            }
            .padding(.horizontal, 22)
            .padding(.top, topInset + 8)

            ScoreRow(sleep: sleepScore, activity: activityScore, calories: calorieScore)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            ReadinessBlock(
                score: readiness,
                state: stateWord,
                quality: qualityWord,
                message: readinessMessage,
                onSeeInsights: onSeeTrends
            )
            .padding(.top, 26)
            .padding(.bottom, 30)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        let name = manager.settings.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? part : "\(part), \(name)"
    }

    private var stateWord: String {
        guard let readiness else { return "LEARNING" }
        return readiness >= 75 ? "READY" : "UNREADY"
    }
    private var qualityWord: String {
        guard let readiness else { return "BUILDING" }
        if readiness >= 75 { return "OPTIMAL" }
        if readiness >= 50 { return "STEADY" }
        return "RESTORE"
    }
    private var readinessMessage: String {
        guard let readiness else {
            return "Use your Tide Ring for a couple days\nto help us calculate your score."
        }
        if readiness >= 75 {
            return "Your body is balanced\nand primed to perform."
        }
        if readiness >= 50 {
            return "Your body is finding its rhythm.\nTake today at a steady pace."
        }
        return "Your body may need more recovery.\nGo gently and prioritize rest."
    }

    // MARK: - Scores

    private var sleepScore: Int? {
        guard let night = store.lastNight(forToday: Date()) else { return nil }
        return TideReadinessEngine.sleepScore(
            actualSleepMinutes: night.asleepMinutes,
            sleepGoalHours: manager.settings.sleepGoalHours
        )
    }
    private var activityScore: Int? {
        goalScore(Double(todayActivity?.steps ?? 0), Double(manager.settings.stepGoal))
    }
    private var calorieScore: Int? {
        let calories = todayActivity.map {
            ActiveEnergy.resolved(
                ringCalories: $0.calories,
                steps: $0.steps,
                weightKg: manager.settings.weightKg
            )
        } ?? 0
        return goalScore(calories, Double(manager.settings.calorieGoal))
    }
    private func goalScore(_ actual: Double, _ goal: Double) -> Int {
        guard goal > 0 else { return 0 }
        return Int(min(100, max(0, (actual / goal * 100).rounded())))
    }

    // MARK: - Today's highlights

    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Today's highlights")
                    .font(TideFont.sans(20, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onSeeTrends) {
                    HStack(spacing: 3) {
                        Text("View all")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .font(TideFont.sans(15))
                    .foregroundStyle(.white.opacity(0.85))
                }
            }

            LazyVGrid(columns: grid, spacing: 14) {
                highlightLink(.heartRate)
                highlightLink(.sleep)
                highlightLink(.bloodOxygen)
                highlightLink(.steps)
                highlightLink(.calories)
                highlightLink(.bloodPressure)
            }

            Button(action: onViewVitals) {
                HStack(spacing: 13) {
                    ZStack {
                        Circle()
                            .fill(TideColors.accent.opacity(0.20))
                            .frame(width: 42, height: 42)
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(TideColors.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("View all vitals")
                            .font(TideFont.sans(16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Heart rate, oxygen, recovery and more")
                            .font(TideFont.sans(12))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity, minHeight: 68)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.32), .white.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.7
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity)
    }

    private func highlightLink(_ metric: TideMetric) -> some View {
        NavigationLink {
            MetricDetailView(metric: metric, manager: manager, store: store)
        } label: {
            HighlightCard(model: model(for: metric))
        }
        .buttonStyle(.plain)
    }

    private func model(for metric: TideMetric) -> HighlightCard.Model {
        switch metric {
        case .heartRate:
            let v = store.latestHeartRate?.value
            return .init(metric: metric, value: v.map { Fmt.number($0) } ?? "—", unit: "bpm",
                         status: v.map(hrStatus) ?? "No data",
                         series: recentValues(store.heartRate, 24))
        case .sleep:
            let n = store.lastNight(forToday: Date())
            return .init(metric: metric, value: n.map { Fmt.duration(minutes: $0.asleepMinutes) } ?? "—", unit: "",
                         status: sleepScore.map { "Score \($0)" } ?? "No data",
                         series: store.sleepNights.suffix(7).map { Double($0.asleepMinutes) })
        case .bloodOxygen:
            let v = store.latestSpO2?.value
            return .init(metric: metric, value: v.map { "\(Int($0))" } ?? "—", unit: "%",
                         status: v.map { $0 >= 95 ? "Normal" : "Low" } ?? "No data",
                         series: recentValues(store.spo2, 24))
        case .steps:
            let steps = todayActivity?.steps ?? 0
            let distance = todayActivity.map { Fmt.distanceKm($0.distanceMeters) }
            return .init(metric: metric, value: steps.formatted(), unit: "steps",
                         status: distance ?? "Starting today",
                         series: store.dailyActivity.suffix(7).map { Double($0.steps) })
        case .calories:
            let a = todayActivity
            let kcal = a.map { ActiveEnergy.resolved(ringCalories: $0.calories, steps: $0.steps, weightKg: manager.settings.weightKg) }
            return .init(metric: metric, value: kcal.map { Fmt.calories($0) } ?? "0", unit: "kcal",
                         status: calorieScore.map { "Score \($0)" } ?? "Starting today",
                         series: store.dailyActivity.suffix(7).map {
                             ActiveEnergy.resolved(ringCalories: $0.calories, steps: $0.steps, weightKg: manager.settings.weightKg)
                         })
        case .bloodPressure:
            let bp = store.latestBloodPressure
            return .init(metric: metric, value: bp.map { "\($0.systolic)/\($0.diastolic)" } ?? "—", unit: "mmHg",
                         status: bp.map(bpStatus) ?? "No data",
                         series: store.bloodPressure.suffix(24).map { Double($0.systolic) })
        default:
            return .init(metric: metric, value: "—", unit: metric.unit, status: "No data", series: [])
        }
    }

    private func recentValues(_ series: [RingReading], _ count: Int) -> [Double] {
        series.sorted { $0.date < $1.date }.suffix(count).map(\.value)
    }
    private func hrStatus(_ v: Double) -> String { v < 60 ? "Resting" : (v < 100 ? "Normal" : "Elevated") }
    private func bpStatus(_ bp: BloodPressureReading) -> String {
        bp.systolic < 120 && bp.diastolic < 80 ? "Normal" : (bp.systolic < 140 ? "Elevated" : "High")
    }

    // MARK: - Demo seed (QA only, behind TIDE_SEED=1)

    private func seedIfRequested() {
        guard ProcessInfo.processInfo.environment["TIDE_SEED"] == "1", store.activity == nil else { return }
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        for i in 0..<24 { store.addHeartRate(bpm: 58 + (i * 7 % 30), date: now.addingTimeInterval(Double(-i * 450)), source: "live") }
        for i in 0..<20 { store.addSpO2(value: 95 + (i % 4), date: now.addingTimeInterval(Double(-i * 600))) }
        store.updateActivity(ActivityRecord(steps: 9000, distanceMeters: 6500, calories: 450, timestamp: yesterday))
        store.updateActivity(ActivityRecord(steps: 8420, distanceMeters: 6100, calories: 420, timestamp: now))
        store.addBloodPressure(systolic: 118, diastolic: 76, date: now)
        store.addBloodPressure(systolic: 128, diastolic: 76, date: yesterday)
        if let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: yesterday) {
            var stages: [SleepStage] = []
            for i in 0..<75 { let r = i % 10; stages.append(r < 6 ? .light : (r < 8 ? .deep : .rem)) }
            store.addSleepFrame(start: start, stages: stages)
        }
        store.freezeTodayReadiness(settings: manager.settings, now: now)
    }
}

// MARK: - Backdrop (scrolls with content; fades on the sides + bottom into deep ocean)

struct HomeBackdrop: View {
    let width: CGFloat

    var body: some View {
        // scaledToFill natural height of the image at this width (image ratio ≈ 0.563).
        let sharpHeight = width / 0.563
        ZStack(alignment: .top) {
            // Base color fills the full scroll height (matches the content's height).
            TideColors.deepOcean

            // Blurred image continues below the sharp hero so the glass cards have texture to refract.
            Image("newbg")
                .resizable().scaledToFill()
                .frame(width: width, height: sharpHeight + 260)
                .clipped()
                .blur(radius: 34)
                .overlay(TideColors.deepOcean.opacity(0.28))

            // Sharp hero image, fading out at its bottom into the blurred layer.
            Image("newbg")
                .resizable().scaledToFill()
                .frame(width: width, height: sharpHeight)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.0), .init(color: .black, location: 0.62),
                                .init(color: .clear, location: 0.98)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            // Bottom fade of the whole hero region into deep ocean.
            LinearGradient(
                stops: [.init(color: .clear, location: 0.66),
                        .init(color: TideColors.deepOcean, location: 1.0)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: sharpHeight + 260)
        }
    }
}

// MARK: - Score row (clean, no glass box)

struct ScoreRow: View {
    let sleep: Int?
    let activity: Int?
    let calories: Int?

    var body: some View {
        HStack(spacing: 0) {
            item("moon.fill", "Sleep", sleep)
            divider
            item("figure.walk", "Activity", activity)
            divider
            item("flame.fill", "Calories", calories)
        }
        .padding(.vertical, 13)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
        )
    }

    private func item(_ icon: String, _ title: String, _ value: Int?) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.white.opacity(0.85))
            Text(value.map(String.init) ?? "—").font(TideFont.serif(30)).foregroundStyle(.white)
            Text(title).font(TideFont.sans(12)).foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 0.5, height: 40)
    }
}

// MARK: - Readiness block (shallow semi-circle arc + score + copy)

struct ReadinessBlock: View {
    let score: Int?
    let state: String
    let quality: String
    let message: String
    let onSeeInsights: () -> Void

    /// Ensures the entrance animation only fires once per app launch.
    private static var hasAnimated = false

    @State private var animatedScore: Int = 0
    @State private var arcProgress: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            ReadinessArc(progress: arcProgress)
                .frame(height: 66)
                .padding(.horizontal, 18)

            Text(state)
                .font(TideFont.sans(15, weight: .medium)).tracking(5)
                .foregroundStyle(.white.opacity(0.9))
            Text(score == nil ? "—" : "\(animatedScore)")
                .font(TideFont.serif(92))
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(animatedScore)))
            Text(quality)
                .font(TideFont.sans(14, weight: .medium)).tracking(4)
                .foregroundStyle(.white.opacity(0.9))
            Text(message)
                .font(TideFont.sans(15))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Button(action: onSeeInsights) {
                HStack(spacing: 5) {
                    Text("See insights")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(TideFont.sans(15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.top, 14)
        }
        .accessibilityHint("Tide wellness estimate. This is not a medical score.")
        .onAppear {
            present(score)
        }
        .onChange(of: score) { _, newScore in present(newScore) }
    }

    private func present(_ score: Int?) {
        guard let score else {
            animatedScore = 0
            arcProgress = 0
            return
        }
        guard !Self.hasAnimated else {
            animatedScore = score
            arcProgress = Double(score) / 100
            return
        }
        Self.hasAnimated = true
        withAnimation(.easeInOut(duration: 2.0).delay(0.5)) {
            arcProgress = Double(score) / 100
        }
        animateScore(to: score)
    }

    /// Drives the displayed number from 0 → target over ~2 s with a calm pace.
    private func animateScore(to target: Int) {
        guard target > 0 else { return }
        let totalDuration: Double = 2.0
        let steps = target
        let interval = totalDuration / Double(steps)
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * interval) {
                withAnimation(.easeInOut(duration: 0.08)) {
                    animatedScore = i
                }
            }
        }
    }
}

/// A shallow, wide semi-circle arc (dome). White track with a soft-blue progress fill and a marker
/// dot. Drawn by sampling points so there is no clockwise ambiguity.
struct ReadinessArc: View, Animatable {
    var progress: Double
    var lineWidth: CGFloat = 6

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let sagitta = max(h - lineWidth * 2, 1)          // dome height
            let r = ((w / 2) * (w / 2) + sagitta * sagitta) / (2 * sagitta)
            let cx = w / 2
            let cy = h - sagitta + r                         // circle centre (below the dome)
            let start = atan2(h - cy, 0 - cx)                // left endpoint angle
            let end = atan2(h - cy, w - cx)                  // right endpoint angle
            let dotAngle = start + (end - start) * progress
            let dot = CGPoint(x: cx + r * cos(dotAngle), y: cy + r * sin(dotAngle))

            ZStack {
                // Frosted-glass track.
                arcPath(cx: cx, cy: cy, r: r, from: start, to: end)
                    .stroke(.white.opacity(0.28), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Progress fill — thick, blue-white, glowing.
                arcPath(cx: cx, cy: cy, r: r, from: start, to: dotAngle)
                    .stroke(
                        LinearGradient(colors: [TideColors.accent, Color(red: 0.78, green: 0.93, blue: 1.0)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .shadow(color: TideColors.accent.opacity(0.7), radius: 7)
                    .overlay(
                        // Top sheen along the fill for a glassy highlight.
                        arcPath(cx: cx, cy: cy, r: r, from: start, to: dotAngle)
                            .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: lineWidth * 0.32, lineCap: .round))
                            .offset(y: -lineWidth * 0.2)
                            .blendMode(.plusLighter)
                    )
                Circle()
                    .fill(.white)
                    .frame(width: lineWidth + 5, height: lineWidth + 5)
                    .shadow(color: .white.opacity(0.9), radius: 6)
                    .position(dot)
            }
        }
    }

    private func arcPath(cx: CGFloat, cy: CGFloat, r: CGFloat, from: CGFloat, to: CGFloat) -> Path {
        Path { p in
            let steps = 80
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let a = from + (to - from) * t
                let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }
}

// MARK: - Highlight card (Liquid Glass)

struct HighlightCard: View {
    struct Model {
        let metric: TideMetric
        let value: String
        let unit: String
        let status: String
        let series: [Double]
        var wide: Bool = false
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(model.metric.tint.opacity(0.20)).frame(width: 32, height: 32)
                    Image(systemName: model.metric.icon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(model.metric.tint)
                }
                Text(model.metric.shortTitle.uppercased())
                    .font(TideFont.sans(11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.value)
                    .font(TideFont.sans(26, weight: .semibold))
                    .foregroundStyle(model.value == "—" ? .white.opacity(0.4) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !model.unit.isEmpty {
                    Text(model.unit).font(TideFont.sans(13)).foregroundStyle(.white.opacity(0.5))
                }
            }

            Text(model.status)
                .font(TideFont.sans(13, weight: .medium))
                .foregroundStyle(model.value == "—" ? .white.opacity(0.4) : model.metric.tint)

            Sparkline(values: model.series, tint: model.metric.tint)
                .frame(height: model.wide ? 44 : 34)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Glass edge sheen so the cards clearly read as Liquid Glass even over the dark ocean.
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A minimal line sparkline with a soft gradient fill; a faint dashed baseline when there's no data.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count >= 2 {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    Circle().fill(tint).frame(width: 5, height: 5).position(pts[pts.count - 1])
                }
            } else {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height * 0.62))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * 0.62))
                }
                .stroke(tint.opacity(0.25), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, let mn = values.min(), let mx = values.max() else { return [] }
        let range = max(mx - mn, 0.0001)
        return values.enumerated().map { i, v in
            let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
            let norm = CGFloat((v - mn) / range)
            let y = size.height * 0.9 - size.height * 0.8 * norm
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Connection pill

/// A small connectivity pill for the top-right of the home header. Taps into the ring screen.
struct RingConnectionPill: View {
    @ObservedObject var manager: RingManager

    var body: some View {
        NavigationLink {
            RingConnectionView(manager: manager)
        } label: {
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(label)
                    .font(TideFont.sans(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var label: String {
        switch manager.connectionState {
        case .connected:
            if let b = manager.batteryPercent { return "\(b)%" }
            return "Connected"
        case .connecting, .reconnecting, .scanning: return "Syncing"
        default: return "Offline"
        }
    }

    private var statusColor: Color {
        switch manager.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting, .scanning: return .orange
        case .failed: return .red
        default: return .gray
        }
    }
}
