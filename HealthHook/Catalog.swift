import Foundation
import HealthKit

/// A Health metric the app can send. `id` is the top-level JSON key (and the prefix of `_min` / `_avg` / `_max` keys).
/// Keep the keys in sync with `tools/generate_ha_package.py` (Home Assistant sensors).
struct Metric: Identifiable {
    enum Kind {
        /// Daily total (steps, distance, energy…). Top level = today's total.
        case cumulative
        /// Discrete measurement (heart rate, weight…). Top level = latest sample, `days` = daily average.
        case discrete
        /// Sleep: hours asleep during the night that ends on that day.
        case sleep
    }

    let id: String
    let title: String.LocalizationValue
    let category: Category
    let kind: Kind
    var quantity: HKQuantityTypeIdentifier? = nil
    var unit: HKUnit = .count()
    var factor: Double = 1
    var decimals = 0
    var suffix = ""
    /// Also sends `<id>_min` and `<id>_max` (and the daily average becomes `<id>_avg`).
    var minMax = false

    var localizedTitle: String { String(localized: title) }

    /// Key of the daily average (in `days`, and at top level for `minMax` metrics).
    var averageKey: String { minMax ? id + "_avg" : id }

    var options: HKStatisticsOptions {
        switch kind {
        case .cumulative: return .cumulativeSum
        case .discrete: return minMax ? [.discreteAverage, .discreteMin, .discreteMax] : .discreteAverage
        case .sleep: return []
        }
    }

    func format(_ v: Double) -> String {
        let number = v.formatted(.number.precision(.fractionLength(decimals)))
        return suffix.isEmpty ? number : "\(number) \(suffix)"
    }
}

enum Category: CaseIterable, Identifiable {
    case activity, heart, sleep, body, mobility, environment, nutrition

    var id: Self { self }

    var title: String {
        switch self {
        case .activity: return String(localized: "Activity")
        case .heart: return String(localized: "Heart & respiration")
        case .sleep: return String(localized: "Sleep")
        case .body: return String(localized: "Body")
        case .mobility: return String(localized: "Mobility")
        case .environment: return String(localized: "Environment")
        case .nutrition: return String(localized: "Nutrition")
        }
    }
}

enum Catalog {
    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let kg = HKUnit.gramUnit(with: .kilo)

    private static func total(_ id: String, _ title: String.LocalizationValue, _ cat: Category,
                              _ q: HKQuantityTypeIdentifier, _ u: HKUnit, _ suffix: String, dec: Int = 0) -> Metric {
        Metric(id: id, title: title, category: cat, kind: .cumulative, quantity: q, unit: u, decimals: dec, suffix: suffix)
    }

    private static func sample(_ id: String, _ title: String.LocalizationValue, _ cat: Category,
                               _ q: HKQuantityTypeIdentifier, _ u: HKUnit, _ suffix: String, dec: Int = 0,
                               factor: Double = 1, minMax: Bool = false) -> Metric {
        Metric(id: id, title: title, category: cat, kind: .discrete, quantity: q, unit: u,
               factor: factor, decimals: dec, suffix: suffix, minMax: minMax)
    }

    static let metrics: [Metric] = [
        // Activity
        total("steps", "Steps", .activity, .stepCount, .count(), ""),
        total("walking_running_distance", "Walking + running distance", .activity, .distanceWalkingRunning, .meterUnit(with: .kilo), "km", dec: 2),
        total("cycling_distance", "Cycling distance", .activity, .distanceCycling, .meterUnit(with: .kilo), "km", dec: 2),
        total("swimming_distance", "Swimming distance", .activity, .distanceSwimming, .meter(), "m"),
        total("flights_climbed", "Flights climbed", .activity, .flightsClimbed, .count(), ""),
        total("active_energy", "Active energy", .activity, .activeEnergyBurned, .kilocalorie(), "kcal"),
        total("resting_energy", "Resting energy", .activity, .basalEnergyBurned, .kilocalorie(), "kcal"),
        total("exercise_time", "Exercise minutes", .activity, .appleExerciseTime, .minute(), "min"),
        total("stand_time", "Stand minutes", .activity, .appleStandTime, .minute(), "min"),
        total("swimming_strokes", "Swimming strokes", .activity, .swimmingStrokeCount, .count(), ""),
        total("time_in_daylight", "Time in daylight", .activity, .timeInDaylight, .minute(), "min"),

        // Heart & respiration
        sample("heart_rate", "Heart rate", .heart, .heartRate, bpm, "bpm", minMax: true),
        sample("resting_heart_rate", "Resting heart rate", .heart, .restingHeartRate, bpm, "bpm"),
        sample("walking_heart_rate", "Walking heart rate average", .heart, .walkingHeartRateAverage, bpm, "bpm"),
        sample("heart_rate_recovery", "Heart rate recovery (1 min)", .heart, .heartRateRecoveryOneMinute, bpm, "bpm"),
        sample("hrv", "Heart rate variability (SDNN)", .heart, .heartRateVariabilitySDNN, .secondUnit(with: .milli), "ms"),
        sample("spo2", "Blood oxygen", .heart, .oxygenSaturation, .percent(), "%", factor: 100),
        sample("respiratory_rate", "Respiratory rate", .heart, .respiratoryRate, bpm, "/min", dec: 1),
        sample("vo2max", "VO2 max", .heart, .vo2Max,
               .literUnit(with: .milli).unitDivided(by: kg.unitMultiplied(by: .minute())), "mL/kg/min", dec: 1),
        sample("blood_pressure_systolic", "Blood pressure (systolic)", .heart, .bloodPressureSystolic, .millimeterOfMercury(), "mmHg"),
        sample("blood_pressure_diastolic", "Blood pressure (diastolic)", .heart, .bloodPressureDiastolic, .millimeterOfMercury(), "mmHg"),
        sample("blood_glucose", "Blood glucose", .heart, .bloodGlucose,
               .gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)), "mg/dL"),

        // Sleep
        Metric(id: "sleep", title: "Sleep", category: .sleep, kind: .sleep, decimals: 1, suffix: "h"),
        sample("wrist_temperature", "Wrist temperature (sleep)", .sleep, .appleSleepingWristTemperature, .degreeCelsius(), "°C", dec: 2),

        // Body
        sample("weight", "Weight", .body, .bodyMass, kg, "kg", dec: 1),
        sample("bmi", "Body mass index", .body, .bodyMassIndex, .count(), "", dec: 1),
        sample("body_fat", "Body fat", .body, .bodyFatPercentage, .percent(), "%", dec: 1, factor: 100),
        sample("lean_body_mass", "Lean body mass", .body, .leanBodyMass, kg, "kg", dec: 1),
        sample("height", "Height", .body, .height, .meterUnit(with: .centi), "cm"),
        sample("waist_circumference", "Waist circumference", .body, .waistCircumference, .meterUnit(with: .centi), "cm", dec: 1),
        sample("body_temperature", "Body temperature", .body, .bodyTemperature, .degreeCelsius(), "°C", dec: 1),

        // Mobility
        sample("walking_speed", "Walking speed", .mobility, .walkingSpeed,
               .meterUnit(with: .kilo).unitDivided(by: .hour()), "km/h", dec: 1),
        sample("step_length", "Step length", .mobility, .walkingStepLength, .meterUnit(with: .centi), "cm"),
        sample("walking_asymmetry", "Walking asymmetry", .mobility, .walkingAsymmetryPercentage, .percent(), "%", factor: 100),
        sample("double_support", "Double support time", .mobility, .walkingDoubleSupportPercentage, .percent(), "%", factor: 100),
        sample("walking_steadiness", "Walking steadiness", .mobility, .appleWalkingSteadiness, .percent(), "%", factor: 100),
        sample("six_minute_walk", "Six-minute walk", .mobility, .sixMinuteWalkTestDistance, .meter(), "m"),

        // Environment
        sample("environmental_audio", "Environmental sound levels", .environment, .environmentalAudioExposure,
               .decibelAWeightedSoundPressureLevel(), "dB", dec: 1),
        sample("headphone_audio", "Headphone audio levels", .environment, .headphoneAudioExposure,
               .decibelAWeightedSoundPressureLevel(), "dB", dec: 1),

        // Nutrition
        total("dietary_energy", "Dietary energy", .nutrition, .dietaryEnergyConsumed, .kilocalorie(), "kcal"),
        total("protein", "Protein", .nutrition, .dietaryProtein, .gram(), "g"),
        total("carbohydrates", "Carbohydrates", .nutrition, .dietaryCarbohydrates, .gram(), "g"),
        total("fat", "Total fat", .nutrition, .dietaryFatTotal, .gram(), "g"),
        total("sugar", "Sugar", .nutrition, .dietarySugar, .gram(), "g"),
        total("fiber", "Fiber", .nutrition, .dietaryFiber, .gram(), "g"),
        total("sodium", "Sodium", .nutrition, .dietarySodium, .gramUnit(with: .milli), "mg"),
        total("caffeine", "Caffeine", .nutrition, .dietaryCaffeine, .gramUnit(with: .milli), "mg"),
        total("water", "Water", .nutrition, .dietaryWater, .liter(), "L", dec: 2),
    ]

    /// Selected on first launch.
    static let defaults: Set<String> = ["steps", "sleep", "heart_rate", "resting_heart_rate", "hrv", "spo2"]

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis)]
        for m in metrics { if let q = m.quantity { types.insert(HKQuantityType(q)) } }
        return types
    }
}
