// Sources & methods (App Review guideline 1.4.1): the published work behind every health number
// the app works out on the phone, one topic per feature, each with links to its sources.
//
// Reachable from Profile ▸ Sources & methods, the foot of the Today tab, every metric's detail
// screen, the Calories / Strain / PAI info sheets, the workout Training section, Heart Rate Zones,
// the Cycle Calendar and the Headache Log. `HealthSourcesButton(topic:)` opens the screen on one
// topic (that topic first, then the rest), so each feature's sources are one tap from where the
// number is shown.
//
// Every citation was checked against its DOI record (Crossref) or PubMed entry; the links are DOI
// or PubMed URLs so they keep resolving. Method lines must stay true to the Analytics code they
// describe (file named in each comment); change both together.

import SwiftUI

struct HealthCitation: Hashable {
    let text: String
    let url: URL

    init(_ text: String, doi: String) {
        self.text = text
        self.url = URL(string: "https://doi.org/" + doi)!
    }

    init(_ text: String, pubmed: Int) {
        self.text = text
        self.url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pubmed)/")!
    }
}

enum HealthSourceTopic: String, CaseIterable, Identifiable, Hashable {
    case heartRate, restingHR, hrv, sleep, sleepScore, readiness, strain, calories, activity, vo2Max,
         heartRateRecovery, skinTemperature, illness, cycle, headache, pai

    var id: String { rawValue }
}

struct HealthSource: Identifiable {
    let topic: HealthSourceTopic
    let title: String
    let method: String
    let citations: [HealthCitation]
    var id: HealthSourceTopic { topic }
}

enum HealthSources {
    static let intro = "OpenCircuit works these numbers out on your phone from your wearable's readings. "
        + "Each one is an estimate based on the published methods below, not a medical device or a diagnosis. "
        + "Tap a source to read it."

    // Shared citations.
    private static let fox = HealthCitation(
        "Fox SM, Naughton JP, Haskell WL (1971). Physical activity and the prevention of coronary heart disease. Annals of Clinical Research 3:404–432.",
        pubmed: 4945367)
    private static let tanaka = HealthCitation(
        "Tanaka H, Monahan KD, Seals DR (2001). Age-predicted maximal heart rate revisited. Journal of the American College of Cardiology 37(1):153–156.",
        doi: "10.1016/S0735-1097(00)01054-8")
    private static let karvonen = HealthCitation(
        "Karvonen MJ, Kentala E, Mustala O (1957). The effects of training on heart rate: a longitudinal study. Annales Medicinae Experimentalis et Biologiae Fenniae 35(3):307–315.",
        pubmed: 13470504)
    private static let garber = HealthCitation(
        "Garber CE et al. (2011). American College of Sports Medicine position stand: quantity and quality of exercise for developing and maintaining cardiorespiratory, musculoskeletal, and neuromotor fitness in apparently healthy adults. Medicine & Science in Sports & Exercise 43(7):1334–1359.",
        doi: "10.1249/MSS.0b013e318213fefb")
    private static let shaffer = HealthCitation(
        "Shaffer F, Ginsberg JP (2017). An overview of heart rate variability metrics and norms. Frontiers in Public Health 5:258.",
        doi: "10.3389/fpubh.2017.00258")
    private static let taskForce = HealthCitation(
        "Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology (1996). Heart rate variability: standards of measurement, physiological interpretation, and clinical use. Circulation 93(5):1043–1065.",
        doi: "10.1161/01.CIR.93.5.1043")
    private static let hirshkowitz = HealthCitation(
        "Hirshkowitz M et al. (2015). National Sleep Foundation's sleep time duration recommendations: methodology and results summary. Sleep Health 1(1):40–43.",
        doi: "10.1016/j.sleh.2014.12.010")
    private static let watson = HealthCitation(
        "Watson NF et al. (2015). Recommended amount of sleep for a healthy adult: a joint consensus statement of the American Academy of Sleep Medicine and Sleep Research Society. Sleep 38(6):843–844.",
        doi: "10.5665/sleep.4716")
    private static let borresen = HealthCitation(
        "Borresen J, Lambert MI (2009). The quantification of training load, the training response and the effect on performance. Sports Medicine 39(9):779–795. (Describes Edwards' heart-rate-zone training impulse, TRIMP.)",
        doi: "10.2165/11317780-000000000-00000")
    private static let smarr = HealthCitation(
        "Smarr BL et al. (2020). Feasibility of continuous fever monitoring using wearable devices. Scientific Reports 10:21640.",
        doi: "10.1038/s41598-020-78355-6")
    private static let maijala = HealthCitation(
        "Maijala A et al. (2019). Nocturnal finger skin temperature in menstrual cycle tracking: ambulatory pilot study using a wearable Oura ring. BMC Women's Health 19:150.",
        doi: "10.1186/s12905-019-0844-9")

    static let all: [HealthSource] = [
        // HeartRateZones.swift, MaxHeartRate, VO2MaxEstimate.swift
        HealthSource(
            topic: .heartRate, title: "Maximum heart rate and heart-rate zones",
            method: "Estimated maximum heart rate is 220 minus your age, unless you enter your own in Heart Rate "
                + "Zones. Zones start at 50, 60, 70, 80 and 90% of that maximum, or of your heart-rate reserve "
                + "(maximum minus resting, the Karvonen method) if you choose it. VO₂ max estimates use the "
                + "Tanaka formula (208 − 0.7 × age) or your highest recorded heart rate, whichever is higher.",
            citations: [fox, tanaka, karvonen, garber]),
        // RestingHR.swift
        HealthSource(
            topic: .restingHR, title: "Resting heart rate",
            method: "Worked out from your heart rate at rest: the average while you sleep, or the day's lowest "
                + "sustained heart rate. A day without enough readings has no value.",
            citations: [
                HealthCitation(
                    "Nanchen D (2018). Resting heart rate: what is normal? Heart 104(13):1048–1049.",
                    doi: "10.1136/heartjnl-2017-312731"),
            ]),
        // HRV.swift, OvernightAverages.swift
        HealthSource(
            topic: .hrv, title: "Heart rate variability (HRV)",
            method: "Your wearable measures HRV as RMSSD, the variation between consecutive heartbeats. "
                + "OpenCircuit shows the average of the readings taken while you slept, and compares it with "
                + "your own recent nights rather than a population norm.",
            citations: [shaffer, taskForce]),
        // SleepDetection.swift, SleepStaging.swift, NapDetection.swift
        HealthSource(
            topic: .sleep, title: "Sleep, sleep stages and naps",
            method: "With the RingConn ring, sleep is found from long still periods in the ring's motion "
                + "readings, and stages (awake, light, deep, REM) are estimated from heart rate, HRV and "
                + "movement in each 2.5-minute period, the approach consumer rings and wristbands use. The "
                + "Helio Strap reports its own sleep and stages. Stages are approximate, not a sleep-lab "
                + "result. Daytime still periods of 15 minutes or more count as naps.",
            citations: [
                HealthCitation(
                    "Ancoli-Israel S et al. (2003). The role of actigraphy in the study of sleep and circadian rhythms. Sleep 26(3):342–392.",
                    doi: "10.1093/sleep/26.3.342"),
                HealthCitation(
                    "de Zambotti M et al. (2019). The sleep of the ring: comparison of the ŌURA sleep tracker against polysomnography. Behavioral Sleep Medicine 17(2):124–136.",
                    doi: "10.1080/15402002.2017.1300587"),
            ]),
        // SleepScore.swift
        HealthSource(
            topic: .sleepScore, title: "Sleep score",
            method: "A 0–100 score from time asleep against your sleep goal (adults are advised 7–9 hours), the "
                + "share of deep and REM sleep, sleep efficiency (time asleep out of time in bed), time awake, "
                + "sleeping heart rate, and skin temperature against your usual. The weighting is OpenCircuit's own.",
            citations: [
                hirshkowitz, watson,
                HealthCitation(
                    "Ohayon MM et al. (2004). Meta-analysis of quantitative sleep parameters from childhood to old age in healthy individuals: developing normative sleep values across the human lifespan. Sleep 27(7):1255–1273.",
                    doi: "10.1093/sleep/27.7.1255"),
                HealthCitation(
                    "Ohayon M et al. (2017). National Sleep Foundation's sleep quality recommendations: first report. Sleep Health 3(1):6–19.",
                    doi: "10.1016/j.sleh.2016.11.006"),
            ]),
        // SleepStress.swift, WellnessBalance.swift, BaselineTrend.swift
        HealthSource(
            topic: .readiness, title: "Overnight stress and readiness",
            method: "Overnight stress is read from your sleeping HRV: lower HRV than usual reads as more "
                + "stress. Readiness combines last night's sleep score, overnight stress, your vitals against "
                + "your usual range and the day's activity score, with OpenCircuit's own weighting. It is not a "
                + "published or clinically validated score; the sources cover its inputs.",
            citations: [shaffer, taskForce, hirshkowitz]),
        // Strain.swift, DailyStrain.swift, TrainingLoad.swift
        HealthSource(
            topic: .strain, title: "Strain and training load",
            method: "Both use Edwards' training impulse (TRIMP): minutes in each heart-rate zone times the zone "
                + "number (1 to 5). Training load is that sum for one workout. Strain sums it over the day "
                + "using heart-rate-reserve zones and puts it on a 0–21 scale (OpenCircuit's own scaling).",
            citations: [borresen, karvonen, fox]),
        // Calories.swift, WorkoutSession.swift
        HealthSource(
            topic: .calories, title: "Calories (resting and active energy)",
            method: "Resting energy (BMR) uses the Mifflin-St Jeor equation with your height, weight, age and "
                + "sex. Active energy uses the Keytel heart-rate equation for the time your heart rate is "
                + "raised while you move, and counts steps when there is no raised heart rate.",
            citations: [
                HealthCitation(
                    "Mifflin MD, St Jeor ST et al. (1990). A new predictive equation for resting energy expenditure in healthy individuals. American Journal of Clinical Nutrition 51(2):241–247.",
                    doi: "10.1093/ajcn/51.2.241"),
                HealthCitation(
                    "Keytel LR et al. (2005). Prediction of energy expenditure from heart rate monitoring during submaximal exercise. Journal of Sports Sciences 23(3):289–297.",
                    doi: "10.1080/02640410470001730089"),
                fox,
            ]),
        // ExerciseMinutes.swift, ActivityScore.swift
        HealthSource(
            topic: .activity, title: "Exercise minutes and activity score",
            method: "Exercise minutes are minutes at or above half your estimated maximum heart rate while you "
                + "are moving. The activity score is how much of your own step, exercise-minute and "
                + "active-calorie goals you reached.",
            citations: [
                garber,
                HealthCitation(
                    "Tudor-Locke C et al. (2018). How fast is fast enough? Walking cadence (steps/min) as a practical estimate of intensity in adults: a narrative review. British Journal of Sports Medicine 52(12):776–788.",
                    doi: "10.1136/bjsports-2017-097628"),
            ]),
        // VO2MaxEstimate.swift, VO2MaxEstimate+Indoor.swift
        HealthSource(
            topic: .vo2Max, title: "VO₂ max (estimate)",
            method: "From a steady-paced run: the oxygen cost of your pace and slope (the American College of "
                + "Sports Medicine running equation), extended to your maximum heart rate on the basis that "
                + "the share of heart-rate reserve you use matches the share of VO₂ reserve.",
            citations: [
                HealthCitation(
                    "Swain DP, Leutholtz BC (1997). Heart rate reserve is equivalent to %VO2 reserve, not to %VO2max. Medicine & Science in Sports & Exercise 29(3):410–414.",
                    doi: "10.1097/00005768-199703000-00018"),
                tanaka, garber,
            ]),
        // HeartRateRecovery.swift
        HealthSource(
            topic: .heartRateRecovery, title: "Heart rate recovery",
            method: "How far your heart rate falls 1 and 2 minutes after a workout ends, from its peak during the "
                + "workout. It is shown only when the workout reached zone 4.",
            citations: [
                HealthCitation(
                    "Cole CR et al. (1999). Heart-rate recovery immediately after exercise as a predictor of mortality. New England Journal of Medicine 341(18):1351–1357.",
                    doi: "10.1056/NEJM199910283411804"),
            ]),
        // SkinTempBaseline.swift, VitalsBaseline.swift
        HealthSource(
            topic: .skinTemperature, title: "Skin temperature, vitals status and fever signs",
            method: "Each night's sleeping skin temperature is compared with your average of the previous 30 "
                + "nights; within 1 °C counts as usual. Vitals status compares each vital with your own recent "
                + "range. Fever signs need both a skin-temperature rise of at least 1 °C and a resting heart "
                + "rate at least 8 bpm above your 7-day average.",
            citations: [smarr, maijala]),
        // IllnessSignals.swift
        HealthSource(
            topic: .illness, title: "Possible illness signs",
            method: "Raised when at least two of skin temperature, sleeping heart rate, HRV and breathing rate "
                + "move away from your usual (the median of up to 30 earlier nights). These are changes "
                + "studies have seen early in common infections; alcohol, a late meal, a hot room or hard "
                + "training can cause the same pattern.",
            citations: [
                HealthCitation(
                    "Radin JM et al. (2020). Harnessing wearable device data to improve state-level real-time surveillance of influenza-like illness in the USA: a population-based study. The Lancet Digital Health 2(2):e85–e93.",
                    doi: "10.1016/S2589-7500(19)30222-5"),
                smarr, shaffer,
            ]),
        // CyclePredictor.swift
        HealthSource(
            topic: .cycle, title: "Cycle predictions",
            method: "The next period is your average logged cycle length after your last period. Ovulation is "
                + "estimated 14 days before it and the fertile window as the 5 days before ovulation. A "
                + "skin-temperature rise of 0.2 °C or more for 2 nights can support the estimate but never "
                + "moves it. Estimates only, not a contraception tool.",
            citations: [
                HealthCitation(
                    "Bull JR et al. (2019). Real-world menstrual cycle characteristics of more than 600,000 menstrual cycles. npj Digital Medicine 2:83.",
                    doi: "10.1038/s41746-019-0152-7"),
                HealthCitation(
                    "Munro MG et al. (2018). The two FIGO systems for normal and abnormal uterine bleeding symptoms and classification of causes of abnormal uterine bleeding in the reproductive years: 2018 revisions. International Journal of Gynecology & Obstetrics 143(3):393–408.",
                    doi: "10.1002/ijgo.12666"),
                maijala,
            ]),
        // HeadacheSignals.swift
        HealthSource(
            topic: .headache, title: "Headache signals",
            method: "Shows how far last night's sleeping vitals were from your own usual, as a position on your "
                + "own scale. It records what was measured and never predicts a headache.",
            citations: [
                HealthCitation(
                    "Lipton RB et al. (2014). Reduction in perceived stress as a migraine trigger: testing the \"let-down headache\" hypothesis. Neurology 82(16):1395–1401.",
                    doi: "10.1212/WNL.0000000000000332"),
                shaffer,
            ]),
        // StrapPAIReading.swift (the strap's own number)
        HealthSource(
            topic: .pai, title: "PAI (Amazfit Helio Strap)",
            method: "PAI is calculated by the strap itself from the time your heart rate spends in its zones over "
                + "a rolling week. OpenCircuit shows the strap's number and doesn't calculate it.",
            citations: [
                HealthCitation(
                    "Nes BM et al. (2017). Personalized Activity Intelligence (PAI) for prevention of cardiovascular disease and promotion of physical activity. American Journal of Medicine 130(3):328–336.",
                    doi: "10.1016/j.amjmed.2016.09.031"),
            ]),
    ]

    static func source(_ topic: HealthSourceTopic) -> HealthSource {
        all.first { $0.topic == topic }!
    }

    /// The list in display order: `focus` first, then the rest in their usual order.
    static func ordered(focus: HealthSourceTopic?) -> [HealthSource] {
        guard let focus else { return all }
        return [source(focus)] + all.filter { $0.topic != focus }
    }
}

/// The Sources & methods screen. Push it inside a navigation stack, or present it through
/// `HealthSourcesButton`, which wraps it in its own.
struct HealthSourcesView: View {
    var focus: HealthSourceTopic? = nil

    var body: some View {
        List {
            Section {
                Text(HealthSources.intro).font(.subheadline)
            }
            ForEach(HealthSources.ordered(focus: focus)) { source in
                Section(source.title) {
                    Text(source.method).font(.subheadline)
                    ForEach(source.citations, id: \.self) { citation in
                        Link(destination: citation.url) {
                            Label {
                                Text(citation.text).font(.footnote).multilineTextAlignment(.leading)
                            } icon: {
                                Image(systemName: "book.closed")
                            }
                        }
                        .accessibilityHint("Opens the source in Safari")
                    }
                }
            }
        }
        .navigationTitle("Sources & Methods")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A "Sources & methods" button that opens the screen on one topic in a sheet. Borderless, so it
/// stays its own tap target inside a List row or a card.
struct HealthSourcesButton: View {
    var topic: HealthSourceTopic? = nil
    var title = "Sources & methods"

    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            Label(title, systemImage: "book.closed")
                .font(.footnote)
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $presented) {
            NavigationStack {
                HealthSourcesView(focus: topic)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { presented = false }
                        }
                    }
            }
        }
    }
}
