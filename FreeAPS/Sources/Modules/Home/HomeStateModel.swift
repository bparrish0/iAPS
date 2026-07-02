import Combine
import CoreData
import LibreTransmitter
import LoopKit
import LoopKitUI
import SwiftDate
import SwiftUI

extension Home {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var broadcaster: Broadcaster!
        @Injected() var appCoordinator: AppCoordinator!
        @Injected() var deviceDataManager: DeviceDataManager!
        @Injected() var apsManager: APSManager!
        @Injected() var nightscoutManager: NightscoutManager!
        @Injected() var storage: TempTargetsStorage!
        @Injected() var keychain: Keychain!
        let coredataContext = CoreDataStack.shared.persistentContainer.viewContext
        private let timer = DispatchTimer(timeInterval: 5)
        private(set) var filteredHours = 24

        @Published var dynamicVariables: DynamicVariables?
        @Published var uploadStats = false
        @Published var enactedSuggestion: Suggestion?
        @Published var recentGlucose: BloodGlucose?
        @Published var glucoseDelta: Int?
        @Published var overrideUnit: Bool = false
        @Published var closedLoop = false
        @Published var pumpSuspended = false
        @Published var isLooping = false
        @Published var statusTitle = ""
        @Published var lastLoopDate: Date = .distantPast
        @Published var tempRate: Decimal?
        @Published var battery: Battery?
        @Published var orangeLinkExpirationDate: Date?
        @Published var batteryDetailKind: BatteryDeviceKind?
        @Published var batteryDetailLog: BatteryDischargeLog?
        @Published var insulinExpirationDate: Date?
        @Published var insulinEstimateUsesLatestTddOnly: Bool = UserDefaults.standard
            .bool(forKey: "insulinEstimateUsesLatestTddOnly")
        @Published var reservoir: Decimal?
        @Published var pumpName = ""
        @Published var pumpExpiresAtDate: Date?
        @Published var tempTarget: TempTarget?
        @Published var setupPump = false
        @Published var errorMessage: String? = nil
        @Published var errorDate: Date? = nil
        @Published var bolusProgress: Decimal?
        @Published var bolusAmount: Decimal?
        @Published var eventualBG: Int?
        @Published var carbsRequired: Decimal?
        @Published var allowManualTemp = false
        @Published var pumpDisplayState: PumpDisplayState?
        @Published var alarm: GlucoseAlarm?
        @Published var animatedBackground = false
        @Published var manualTempBasal = false
        @Published var maxValue: Decimal = 1.2
        @Published var timeZone: TimeZone?
        @Published var totalBolus: Decimal = 0
        @Published var isStatusPopupPresented: Bool = false
        @Published var readings: [Readings] = []
        @Published var loopStatistics: (Int, Int, Double, String) = (0, 0, 0, "")
        @Published var standing: Bool = false
        @Published var preview: Bool = true
        @Published var useTargetButton: Bool = false
        @Published var overrideHistory: [OverrideHistory] = []
        @Published var overrides: [Override] = []
        @Published var alwaysUseColors: Bool = false
        @Published var useCalc: Bool = true
        @Published var hours: Int = 6
        @Published var iobData: [IOBData] = []
        @Published var carbData: Decimal = 0
        @Published var iobs: Decimal = 0
        @Published var neg: Int = 0
        @Published var tddChange: Decimal = 0
        @Published var tddAverage: Decimal = 0
        @Published var tddYesterday: Decimal = 0
        @Published var tdd2DaysAgo: Decimal = 0
        @Published var tdd3DaysAgo: Decimal = 0
        @Published var tddActualAverage: Decimal = 0
        @Published var skipGlucoseChart: Bool = false
        @Published var displayDelta: Bool = false
        @Published var openAPSSettings: Preferences?
        @Published var maxIOB: Decimal = 0
        @Published var maxCOB: Decimal = 0
        @Published var autoisf = false
        @Published var displayExpiration = false
        @Published var displaySAGE = true
        @Published var sensorDays: Double = 10
        @Published var carbButton: Bool = true
        @Published var profileButton: Bool = true
        @Published var mealData = MealData()

        // Chart data
        var data = ChartModel(
            suggestion: nil,
            glucose: [],
            activity: [],
            cob: [],
            isManual: [],
            tempBasals: [],
            boluses: [],
            suspensions: [],
            announcement: [],
            hours: 24,
            maxBasal: 4,
            autotunedBasalProfile: [],
            basalProfile: [],
            tempTargets: [],
            carbs: [],
            timerDate: Date(),
            units: .mmolL,
            smooth: false,
            highGlucose: 200,
            lowGlucose: 60,
            displayXgridLines: true,
            displayYgridLines: true,
            thresholdLines: true,
            overrideHistory: [],
            minimumSMB: 0,
            insulinDIA: 7,
            insulinPeak: 75,
            maxBolus: 0,
            maxBolusValue: 1,
            maxCarbsValue: 1,
            maxIOB: 0,
            maxCOB: 1,
            useInsulinBars: true,
            screenHours: 6,
            fpus: true,
            fpuAmounts: false,
            showInsulinActivity: false,
            showCobChart: false,
            iob: nil,
            hidePredictions: false,
            useCarbBars: false
        )

        func startTimer() {
            timer.resume()
        }

        func stopTimer() {
            timer.suspend()
        }

        override func subscribe() {
            setupGlucose()
            setupBasals()
            setupBoluses()
            setupActivity()
            setupSuspensions()
            setupPumpSettings()
            setupBasalProfile()
            setupTempTargets()
            setupCarbs()
            setupBattery()
            setupOrangeLinkBattery()
            setupReservoir()
            setupInsulinTimeRemaining()
            setupAnnouncements()
            setupCurrentPumpTimezone()
            setupOverrideHistory()
            setupLoopStats()
            setupData()
            setupCob()
            setupMeals()

            data.suggestion = provider.suggestion
            dynamicVariables = provider.dynamicVariables
            overrideHistory = provider.overrideHistory()
            uploadStats = settingsManager.settings.uploadStats
            enactedSuggestion = provider.enactedSuggestion
            data.units = settingsManager.settings.units
            allowManualTemp = !settingsManager.settings.closedLoop
            closedLoop = settingsManager.settings.closedLoop
            lastLoopDate = apsManager.lastLoopDate
            carbsRequired = data.suggestion?.carbsReq
            alarm = provider.glucoseStorage.alarm
            manualTempBasal = apsManager.isManualTempBasal
            setStatusTitle()
            setupCurrentTempTarget()
            data.smooth = settingsManager.settings.smoothGlucose
            maxValue = settingsManager.preferences.autosensMax
            data.lowGlucose = settingsManager.settings.low
            data.highGlucose = settingsManager.settings.high
            overrideUnit = settingsManager.settings.overrideHbA1cUnit
            data.displayXgridLines = settingsManager.settings.xGridLines
            data.displayYgridLines = settingsManager.settings.yGridLines
            data.thresholdLines = settingsManager.settings.rulerMarks
            data.showInsulinActivity = settingsManager.settings.showInsulinActivity
            data.showCobChart = settingsManager.settings.showCobChart
            useTargetButton = settingsManager.settings.useTargetButton
            data.screenHours = settingsManager.settings.hours
            alwaysUseColors = settingsManager.settings.alwaysUseColors
            useCalc = settingsManager.settings.useCalc
            data.minimumSMB = settingsManager.settings.minimumSMB
            data.insulinDIA = settingsManager.pumpSettings.insulinActionCurve
            data.insulinPeak = settingsManager.preferences.useCustomPeakTime ? settingsManager.preferences.insulinPeakTime :
                (settingsManager.preferences.curve == .ultraRapid ? 55 : 75)

            data.maxBolus = settingsManager.pumpSettings.maxBolus
            data.maxIOB = settingsManager.preferences.maxIOB
            data.maxCOB = settingsManager.preferences.maxCOB
            data.useInsulinBars = settingsManager.settings.useInsulinBars
            data.fpus = settingsManager.settings.fpus
            data.fpuAmounts = settingsManager.settings.fpuAmounts
            data.hidePredictions = settingsManager.settings.hidePredictions
            data.useCarbBars = settingsManager.settings.useCarbBars
            skipGlucoseChart = settingsManager.settings.skipGlucoseChart
            displayDelta = settingsManager.settings.displayDelta
            maxIOB = settingsManager.preferences.maxIOB
            maxCOB = settingsManager.preferences.maxCOB
            autoisf = settingsManager.settings.autoisf
            hours = settingsManager.settings.hours
            displayExpiration = settingsManager.settings.displayExpiration
            displaySAGE = settingsManager.settings.displaySAGE

            updateSensorDays()

            appCoordinator.$sensorDays
                .receive(on: DispatchQueue.main)
                .sink { _ in self.updateSensorDays() }
                .store(in: &lifetime)

            carbButton = settingsManager.settings.carbButton
            profileButton = settingsManager.settings.profileButton

            broadcaster.register(GlucoseObserver.self, observer: self)
            broadcaster.register(SuggestionObserver.self, observer: self)
            broadcaster.register(SettingsObserver.self, observer: self)
            broadcaster.register(PumpHistoryObserver.self, observer: self)
            broadcaster.register(PumpSettingsObserver.self, observer: self)
            broadcaster.register(BasalProfileObserver.self, observer: self)
            broadcaster.register(TempTargetsObserver.self, observer: self)
            broadcaster.register(CarbsObserver.self, observer: self)
            broadcaster.register(EnactedSuggestionObserver.self, observer: self)
            broadcaster.register(PumpBatteryObserver.self, observer: self)
            broadcaster.register(PumpReservoirObserver.self, observer: self)
            broadcaster.register(PumpTimeZoneObserver.self, observer: self)
            animatedBackground = settingsManager.settings.animatedBackground

            subscribeSetting(
                \.hours,
                on: $hours,
                initial: {
                    let value = max(min($0, 24), 2)
                    hours = value
                },
                map: { $0 }
            )

            timer.eventHandler = {
                DispatchQueue.main.async { [weak self] in
                    self?.data.timerDate = Date()
                    self?.setupCurrentTempTarget()
                }
            }

            appCoordinator.isLooping
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.isLooping, on: self)
                .store(in: &lifetime)

            apsManager.lastLoopDateSubject
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.lastLoopDate, on: self)
                .store(in: &lifetime)

            apsManager.pumpName
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.pumpName, on: self)
                .store(in: &lifetime)

            apsManager.pumpExpiresAtDate
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.pumpExpiresAtDate, on: self)
                .store(in: &lifetime)

            apsManager.lastError
                .receive(on: DispatchQueue.main)
                .map { [weak self] error in
                    self?.errorDate = error == nil ? nil : Date()
                    /* if let error = error,
                        !error.localizedDescription.contains(NSLocalizedString("Pump is Busy.", comment: "Pump Error"))
                     {
                         info(.default, error.localizedDescription)
                     } */
                    return error?.localizedDescription
                }
                .weakAssign(to: \.errorMessage, on: self)
                .store(in: &lifetime)

            apsManager.bolusProgress
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.bolusProgress, on: self)
                .store(in: &lifetime)

            apsManager.bolusAmount
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.bolusAmount, on: self)
                .store(in: &lifetime)

            apsManager.pumpDisplayState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self else { return }
                    self.pumpDisplayState = state
                    if state == nil {
                        self.reservoir = nil
                        self.battery = nil
                        self.pumpName = ""
                        self.pumpExpiresAtDate = nil
                        self.setupPump = false
                    } else {
                        self.setupBattery()
                        self.setupReservoir()
                    }
                }
                .store(in: &lifetime)

            $setupPump
                .sink { [weak self] show in
                    guard let self = self else { return }
                    if show, let pumpManager = self.provider.deviceManager.pumpManager
                    {
                        if pumpManager.isOnboarded {
                            let view = PumpConfig.PumpSettingsView(
                                pumpManager: pumpManager,
                                deviceManager: self.provider.deviceManager,
                                completionDelegate: self,
                            ).asAny()
                            self.router.mainSecondaryModalView.send(view)
                        } else {
                            self.router.mainSecondaryModalView.send(nil)
                            showModal(for: .pumpConfig)
                        }
                    } else {
                        self.router.mainSecondaryModalView.send(nil)
                    }
                }
                .store(in: &lifetime)
        }

        private func updateSensorDays() {
            sensorDays = appCoordinator.sensorDays ?? settingsManager.settings.sensorDays
        }

        func addCarbs() {
            showModal(for: .addCarbs(editMode: false, override: false))
        }

        func runLoop() {
            provider.heartbeatNow()
        }

        func cancelBolus() {
            apsManager.cancelBolus()
        }

        func cancelProfile() {
            let os = OverrideStorage()
            // Is there a saved Override?
            if let activeOveride = os.fetchLatestOverride().first {
                let presetName = os.isPresetName()
                // Is the Override a Preset?
                if let preset = presetName {
                    if let duration = os.cancelProfile() {
                        // Update in Nightscout
                        nightscoutManager.editOverride(preset, duration, activeOveride.date ?? Date.now)
                    }
                } else if activeOveride.isPreset { // Because hard coded Hypo treatment isn't actually a preset
                    if let duration = os.cancelProfile() {
                        nightscoutManager.editOverride("📉", duration, activeOveride.date ?? Date.now)
                    }
                } else {
                    let nsString = activeOveride.percentage.formatted() != "100" ? activeOveride.percentage
                        .formatted() + " %" : "Custom"
                    if let duration = os.cancelProfile() {
                        nightscoutManager.editOverride(nsString, duration, activeOveride.date ?? Date.now)
                    }
                }
            }
            setupOverrideHistory()
        }

        func cancelTempTarget() {
            storage.storeTempTargets([TempTarget.cancel(at: Date())])
            coredataContext.performAndWait {
                let saveToCoreData = TempTargets(context: self.coredataContext)
                saveToCoreData.active = false
                saveToCoreData.date = Date()
                try? self.coredataContext.save()

                let setHBT = TempTargetsSlider(context: self.coredataContext)
                setHBT.enabled = false
                setHBT.date = Date()
                try? self.coredataContext.save()
            }
        }

        func fetchPreferences() {
            let token = Token().getIdentifier()
            let database = Database(token: token)
            database.fetchPreferences("default")
                .receive(on: DispatchQueue.main)
                .sink { completion in
                    switch completion {
                    case .finished:
                        debug(.service, "Preferences fetched from database. Profile: default")
                    case let .failure(error):
                        debug(.service, "Preferences fetched from database failed. Error: " + error.localizedDescription)
                    }
                }
            receiveValue: { self.openAPSSettings = $0 }
                .store(in: &lifetime)
        }

        private func setupGlucose() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.isManual = self.provider.manualGlucose(hours: self.filteredHours)
                self.data.glucose = self.provider.filteredGlucose(hours: self.filteredHours)
                self.readings = CoreDataStorage().fetchGlucose(interval: DateFilter().today)
                self.recentGlucose = self.data.glucose.last
                if self.data.glucose.count >= 2 {
                    self.glucoseDelta =
                        NSDecimalNumber(
                            decimal:
                            (self.recentGlucose?.unfiltered ?? 0) -
                                (self.data.glucose[self.data.glucose.count - 2].unfiltered ?? 0)
                        ).intValue
                } else {
                    self.glucoseDelta = nil
                }
                self.alarm = self.provider.glucoseStorage.alarm
            }
        }

        private func setupBasals() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.manualTempBasal = self.apsManager.isManualTempBasal
                self.data.tempBasals = self.provider.pumpHistory(hours: self.filteredHours).filter {
                    $0.type == .tempBasal || $0.type == .tempBasalDuration
                }
                let lastTempBasal = Array(self.data.tempBasals.suffix(2))
                guard lastTempBasal.count == 2 else {
                    self.tempRate = nil
                    return
                }

                guard let lastRate = lastTempBasal[0].rate, let lastDuration = lastTempBasal[1].durationMin else {
                    self.tempRate = nil
                    return
                }
                let lastDate = lastTempBasal[0].timestamp
                guard Date().timeIntervalSince(lastDate.addingTimeInterval(lastDuration.minutes.timeInterval)) < 0 else {
                    self.tempRate = nil
                    return
                }
                self.tempRate = lastRate
            }
        }

        private func setupBoluses() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.boluses = self.provider.pumpHistory(hours: self.filteredHours).filter {
                    $0.type == .bolus
                }
                self.data.maxBolusValue = self.data.boluses.compactMap(\.amount).max() ?? 1
            }
        }

        private func setupSuspensions() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.suspensions = self.provider.pumpHistory(hours: self.filteredHours).filter {
                    $0.type == .pumpSuspend || $0.type == .pumpResume
                }

                let last = self.data.suspensions.last
                let tbr = self.data.tempBasals.first { $0.timestamp > (last?.timestamp ?? .distantPast) }

                self.pumpSuspended = tbr == nil && last?.type == .pumpSuspend
            }
        }

        private func setupActivity() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.activity = CoreDataStorage().fetchInsulinData(interval: DateFilter().day)
            }
        }

        private func setupCob() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.cob = self.iobData
            }
        }

        private func setupPumpSettings() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.maxBasal = self.provider.pumpSettings().maxBasal
            }
        }

        private func setupBasalProfile() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.autotunedBasalProfile = self.provider.autotunedBasalProfile()
                self.data.basalProfile = self.provider.basalProfile()
            }
        }

        private func setupTempTargets() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.manualTempBasal = self.apsManager.isManualTempBasal
                self.data.tempTargets = self.provider.tempTargets(hours: self.filteredHours)
            }
        }

        private func setupCarbs() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.carbs = self.provider.carbs(hours: self.filteredHours)
                self.data.maxCarbsValue = self.data.carbs.compactMap(\.carbs).max() ?? 1
            }
        }

        private func setupOverrideHistory() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.overrideHistory = self.provider.overrideHistory()
            }
        }

        private func setupLoopStats() {
            let loopStats = CoreDataStorage().fetchLoopStats(interval: DateFilter().today)
            let loops = loopStats.compactMap({ each in each.loopStatus }).count
            let readings = CoreDataStorage().fetchGlucose(interval: DateFilter().today).compactMap({ each in each.glucose }).count
            let percentage = min(readings != 0 ? (Double(loops) / Double(readings) * 100) : 0, 100)
            // First loop date
            let time = (loopStats.last?.start ?? Date.now).addingTimeInterval(-5.minutes.timeInterval)

            let average = -1 * (time.timeIntervalSinceNow / 60) / max(Double(loops), 1)

            loopStatistics = (
                loops,
                readings,
                percentage,
                average.formatted(.number.grouping(.never).rounded().precision(.fractionLength(1))) + " min"
            )
        }

        private func setupOverrides() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.overrides = self.provider.overrides()
            }
        }

        private func setupAnnouncements() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.data.announcement = self.provider.announcement(self.filteredHours)
            }
        }

        private func setStatusTitle() {
            guard let suggestion = data.suggestion else {
                statusTitle = NSLocalizedString("No suggestion", comment: "Status title when there is no suggestion")
                return
            }

            let dateFormatter = DateFormatter()
            dateFormatter.timeStyle = .short
            if closedLoop,
               let enactedSuggestion = enactedSuggestion,
               let timestamp = enactedSuggestion.timestamp,
               enactedSuggestion.deliverAt == suggestion.deliverAt, enactedSuggestion.recieved == true
            {
                statusTitle = NSLocalizedString("Enacted at", comment: "Headline in enacted pop up") + " " + dateFormatter
                    .string(from: timestamp)
            } else if let suggestedDate = suggestion.deliverAt {
                statusTitle = NSLocalizedString("Suggested at", comment: "Headline in suggested pop up") + " " + dateFormatter
                    .string(from: suggestedDate)
            } else {
                statusTitle = "Suggested"
            }

            eventualBG = suggestion.eventualBG
        }

        private func setupReservoir() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.reservoir = self.provider.pumpReservoir()
            }
        }

        private func setupBattery() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.battery = self.provider.pumpBattery()
                if self.batteryDetailKind == .pump {
                    self.batteryDetailLog = self.provider.batteryLog(for: .pump)
                }
            }
        }

        /// Open the battery-detail sheet for the given battery, loading its persisted log.
        func presentBatteryDetail(_ kind: BatteryDeviceKind) {
            batteryDetailLog = provider.batteryLog(for: kind)
            batteryDetailKind = kind
        }

        /// Set (or clear, when `secondsRemaining` is nil) the user's time-remaining override for
        /// one voltage level of a battery's discharge table.
        func setBatteryLevelOverride(kind: BatteryDeviceKind, level: Int, secondsRemaining: TimeInterval?) {
            var log = provider.batteryLog(for: kind) ?? BatteryDischargeLog()
            var overrides = log.levelOverrides ?? []
            overrides.removeAll { $0.level == level }
            if let secondsRemaining = secondsRemaining {
                overrides.append(BatteryLevelRemaining(level: level, secondsRemaining: secondsRemaining))
            }
            log.levelOverrides = overrides
            finalizeBatteryLogEdit(kind: kind, log: log)
        }

        /// Delete one completed discharge cycle from a battery's history (e.g. an outlier
        /// session), so it stops contributing to the learned average.
        func deleteBatteryCycle(kind: BatteryDeviceKind, at index: Int) {
            guard var log = provider.batteryLog(for: kind),
                  log.completedCycles.indices.contains(index)
            else { return }
            log.completedCycles.remove(at: index)
            finalizeBatteryLogEdit(kind: kind, log: log)
        }

        /// Email a full battery-tracking debug report (both batteries) to the developer.
        /// Returns a short status string for display next to the button.
        func sendBatteryDebugEmail(for kind: BatteryDeviceKind) async -> String {
            let logs = BatteryDeviceKind.allCases.map { (kind: $0, log: provider.batteryLog(for: $0)) }
            let report = BatteryDebugReport.compose(
                focus: kind,
                logs: logs,
                battery: provider.pumpBattery(),
                reservoir: provider.pumpReservoir()
            )
            do {
                try await BatteryDebugMailer.send(subject: report.subject, body: report.body)
                return NSLocalizedString("Sent", comment: "Debug email status")
            } catch {
                return String(
                    format: NSLocalizedString("Failed: %@", comment: "Debug email status"),
                    error.localizedDescription
                )
            }
        }

        /// Persist an edited battery log, recompute its expiration estimate from the last known
        /// reading, and push the fresh estimate into the header display.
        private func finalizeBatteryLogEdit(kind: BatteryDeviceKind, log: BatteryDischargeLog) {
            var log = log
            if let value = log.lastValue, let date = log.currentValueSince ?? log.lastValueDate {
                log.currentExpirationDate = BatteryDischargeTracker.estimatedExpiration(
                    at: value,
                    from: date,
                    log: log,
                    config: kind.config
                )
            }
            provider.saveBatteryLog(log, for: kind)
            batteryDetailLog = log

            switch kind {
            case .orangeLink:
                orangeLinkExpirationDate = log.currentExpirationDate
            case .pump:
                // The header reads the pump expiration off the Battery snapshot, which is only
                // rewritten on the next pump-status update — refresh it now so the edit shows
                // immediately.
                if let current = provider.pumpBattery() {
                    let updated = Battery(
                        percent: current.percent,
                        voltage: current.voltage,
                        string: current.string,
                        display: current.display,
                        batteryExpirationDate: log.currentExpirationDate
                    )
                    provider.savePumpBattery(updated)
                    battery = updated
                }
            }
        }

        private func setupOrangeLinkBattery() {
            refreshOrangeLinkBattery()
            Foundation.NotificationCenter.default.publisher(for: .orangeLinkBatteryUpdated)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshOrangeLinkBattery() }
                .store(in: &lifetime)
        }

        private func refreshOrangeLinkBattery() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.orangeLinkExpirationDate = self.provider.orangeLinkBattery()?.currentExpirationDate
                if self.batteryDetailKind == .orangeLink {
                    self.batteryDetailLog = self.provider.orangeLinkBattery()
                }
            }
        }

        private func setupInsulinTimeRemaining() {
            refreshInsulinTimeRemaining()
        }

        /// Estimate hours-of-insulin-remaining from the rolling-24h TDD (the same value shown
        /// elsewhere as "TDD yesterday") and the current reservoir. By default averages one
        /// stored TDD value per calendar day across the last 10 days — multi-day smoothing so a
        /// single big-bolus day doesn't whipsaw the estimate. When the user has tapped the I
        /// view, uses just the single freshest TDD record (responsive when usage has suddenly
        /// shifted, e.g. vacation). Updated whenever pump history or reservoir changes; the
        /// UI's timer tick then counts the estimate down in real time.
        func refreshInsulinTimeRemaining() {
            let samples: [Decimal] = insulinEstimateUsesLatestTddOnly
                ? latestStoredTDD().map { [$0] } ?? []
                : recentDailyTDDSamples(limit: 10)
            guard !samples.isEmpty,
                  let reservoir = provider.pumpReservoir(),
                  reservoir > 0
            else {
                DispatchQueue.main.async { [weak self] in self?.insulinExpirationDate = nil }
                return
            }
            // Pump history events are concentration-adjusted before being saved (see
            // PumpHistoryStorage), so the stored TDD is already in real insulin units (e.g.
            // 85.7 U/day means 85.7 real units delivered). The raw reservoir from
            // `pumpReservoir()` is in pump-volume units though, so multiply by concentration
            // here to bring it into the same units before dividing.
            let concentration = Decimal(CoreDataStorage().insulinConcentration().concentration)
            let realReservoir = reservoir * concentration
            let avgDailyUnits = samples.reduce(0, +) / Decimal(samples.count)
            let unitsPerHour = avgDailyUnits / 24
            let hoursRemaining = Double(truncating: (realReservoir / unitsPerHour) as NSDecimalNumber)
            let expiration = Date().addingTimeInterval(hoursRemaining * 3600)
            DispatchQueue.main.async { [weak self] in self?.insulinExpirationDate = expiration }
        }

        private func latestStoredTDD() -> Decimal? {
            let tdds = CoreDataStorage().fetchTDD(interval: DateFilter().tenDays)
            guard let v = tdds.first?.tdd?.decimalValue, v > 0 else { return nil }
            return v
        }

        /// Up to `limit` daily TDD samples, taking the freshest stored record from each distinct
        /// calendar day. Loop saves a record every ~5 minutes, so naïvely taking the last N
        /// records all comes from the past ~N×5 minutes — meaningless for cross-day smoothing.
        private func recentDailyTDDSamples(limit: Int) -> [Decimal] {
            let tdds = CoreDataStorage().fetchTDD(interval: DateFilter().tenDays)
            let calendar = Calendar.current
            var seenDays: Set<Date> = []
            var result: [Decimal] = []
            for record in tdds {
                guard let ts = record.timestamp,
                      let value = record.tdd?.decimalValue,
                      value > 0
                else { continue }
                let day = calendar.startOfDay(for: ts)
                if seenDays.insert(day).inserted {
                    result.append(value)
                    if result.count == limit { break }
                }
            }
            return result
        }

        /// Toggle between rolling-7-record average (default, smoother) and single latest TDD
        /// (snappier — picks up day-over-day usage changes immediately). Persists across reboots.
        func toggleInsulinEstimateMode() {
            insulinEstimateUsesLatestTddOnly.toggle()
            UserDefaults.standard.set(insulinEstimateUsesLatestTddOnly, forKey: "insulinEstimateUsesLatestTddOnly")
            refreshInsulinTimeRemaining()
        }

        private func setupCurrentTempTarget() {
            tempTarget = provider.tempTarget()
        }

        private func setupCurrentPumpTimezone() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.timeZone = self.provider.pumpTimeZone()
            }
        }

        private func setupIOB() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                Task {
                    do {
                        if let sync = try await self.provider.iob() {
                            self.data.iob = sync
                        }
                    } catch { debug(.apsManager, "Error - Couldn't update foreground IOB value.") }
                }
            }
        }

        private func setupData() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let data = self.provider.reasons() {
                    self.iobData = data
                    self.carbData = data.map(\.cob).reduce(0, +)
                    self.iobs = data.map(\.iob).reduce(0, +)
                    neg = data.filter({ $0.iob < 0 }).count * 5
                    let tdds = CoreDataStorage().fetchTDD(interval: DateFilter().tenDays)
                    let yesterday = (tdds.first(where: {
                        ($0.timestamp ?? .distantFuture) <= Date().addingTimeInterval(-24.hours.timeInterval)
                    })?.tdd ?? 0) as Decimal
                    let oneDaysAgo = CoreDataStorage().fetchTDD(interval: DateFilter().today).last
                    tddChange = ((tdds.first?.tdd ?? 0) as Decimal) - yesterday
                    tddYesterday = (oneDaysAgo?.tdd ?? 0) as Decimal
                    tdd2DaysAgo = (tdds.first(where: {
                        ($0.timestamp ?? .distantFuture) <= (oneDaysAgo?.timestamp ?? .distantPast)
                            .addingTimeInterval(-1.days.timeInterval)
                    })?.tdd ?? 0) as Decimal
                    tdd3DaysAgo = (tdds.first(where: {
                        ($0.timestamp ?? .distantFuture) <= (oneDaysAgo?.timestamp ?? .distantPast)
                            .addingTimeInterval(-2.days.timeInterval)
                    })?.tdd ?? 0) as Decimal

                    if let tdds_ = self.provider.dynamicVariables {
                        tddAverage = ((tdds.first?.tdd ?? 0) as Decimal) - tdds_.average_total_data
                        tddActualAverage = tdds_.average_total_data
                    }
                }
            }
        }

        private func setupMeals() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let data = self.provider.fetchedMeals
                self.mealData.carbs = self.carbCount(data)
                self.mealData.fat = self.fatCount(data)
                self.mealData.protein = self.proteinCount(data)
                self.mealData.kcal = self.kcalCount()
                self.mealData.servings = self.servingsCount(data)
            }
        }

        private func carbCount(_ fetchedMeals: [Carbohydrates]) -> Decimal {
            fetchedMeals
                .compactMap(\.carbs)
                .map({ x in
                    x as Decimal
                }).reduce(0, +)
        }

        private func fatCount(_ fetchedMeals: [Carbohydrates]) -> Decimal {
            fetchedMeals
                .compactMap(\.fat)
                .map({ x in
                    x as Decimal
                }).reduce(0, +)
        }

        private func proteinCount(_ fetchedMeals: [Carbohydrates]) -> Decimal {
            fetchedMeals
                .compactMap(\.protein)
                .map({ x in
                    x as Decimal
                }).reduce(0, +)
        }

        private func servingsCount(_ fetchedMeals: [Carbohydrates]) -> Int {
            fetchedMeals.count
        }

        private func kcalCount() -> Decimal {
            4 * (mealData.carbs + mealData.protein) + mealData.fat * 9
        }

        func openCGM() {
            if let cgm = provider.deviceManager.cgmManager {
                if let url = cgm.appURL {
                    // if app url is provided (nightscout, xDrip) - open it
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                } else if let cgm = cgm as? CGMManagerUI {
                    let view = CGM.CGMSettingsView(
                        cgmManager: cgm,
                        deviceManager: provider.deviceManager,
                        completionDelegate: self
                    ).asAny()
                    router.mainSecondaryModalView.send(view)
                }
            }
        }

        func infoPanelTTPercentage(_ hbt_: Double, _ target: Decimal) -> Decimal {
            guard hbt_ != 0 || target != 0 else {
                return 0
            }
            let c = Decimal(hbt_ - 100)
            let ratio = min(c / (target + c - 100), maxValue)
            return (ratio * 100)
        }
    }
}

extension Home.StateModel:
    GlucoseObserver,
    SuggestionObserver,
    SettingsObserver,
    PumpHistoryObserver,
    PumpSettingsObserver,
    BasalProfileObserver,
    TempTargetsObserver,
    CarbsObserver,
    EnactedSuggestionObserver,
    PumpBatteryObserver,
    PumpReservoirObserver,
    PumpTimeZoneObserver
{
    func glucoseDidUpdate(_: [BloodGlucose]) {
        setupGlucose()
        setupLoopStats()
    }

    func suggestionDidUpdate(_ suggestion: Suggestion) {
        data.suggestion = suggestion
        data.iob = data.suggestion?.iob
        carbsRequired = suggestion.carbsReq
        setStatusTitle()
        setupOverrideHistory()
        setupLoopStats()
        setupData()
        setupActivity()
        setupCob()
    }

    func settingsDidChange(_ settings: FreeAPSSettings) {
        allowManualTemp = !settings.closedLoop
        uploadStats = settingsManager.settings.uploadStats
        closedLoop = settingsManager.settings.closedLoop
        data.units = settingsManager.settings.units
        animatedBackground = settingsManager.settings.animatedBackground
        manualTempBasal = apsManager.isManualTempBasal
        data.smooth = settingsManager.settings.smoothGlucose
        data.lowGlucose = settingsManager.settings.low
        data.highGlucose = settingsManager.settings.high
        overrideUnit = settingsManager.settings.overrideHbA1cUnit
        data.displayXgridLines = settingsManager.settings.xGridLines
        data.displayYgridLines = settingsManager.settings.yGridLines
        data.thresholdLines = settingsManager.settings.rulerMarks
        data.showInsulinActivity = settingsManager.settings.showInsulinActivity
        data.showCobChart = settingsManager.settings.showCobChart
        useTargetButton = settingsManager.settings.useTargetButton
        data.screenHours = settingsManager.settings.hours
        alwaysUseColors = settingsManager.settings.alwaysUseColors
        useCalc = settingsManager.settings.useCalc
        data.minimumSMB = settingsManager.settings.minimumSMB
        data.maxBolus = settingsManager.pumpSettings.maxBolus
        data.useInsulinBars = settingsManager.settings.useInsulinBars
        data.fpus = settingsManager.settings.fpus
        data.fpuAmounts = settingsManager.settings.fpuAmounts
        data.hidePredictions = settingsManager.settings.hidePredictions
        data.useCarbBars = settingsManager.settings.useCarbBars
        skipGlucoseChart = settingsManager.settings.skipGlucoseChart
        displayDelta = settingsManager.settings.displayDelta
        maxIOB = settingsManager.preferences.maxIOB
        maxCOB = settingsManager.preferences.maxCOB
        autoisf = settingsManager.settings.autoisf
        hours = settingsManager.settings.hours
        displayExpiration = settingsManager.settings.displayExpiration
        displaySAGE = settingsManager.settings.displaySAGE
//        cgm = settingsManager.settings.cgm
        carbButton = settingsManager.settings.carbButton
        profileButton = settingsManager.settings.profileButton
        updateSensorDays()

        setupGlucose()
        setupOverrideHistory()
        setupData()
    }

    func pumpHistoryDidUpdate(_: [PumpHistoryEvent]) {
        setupBasals()
        setupBoluses()
        setupSuspensions()
        setupAnnouncements()
        setupIOB()
        setupActivity()
        refreshInsulinTimeRemaining()
    }

    func pumpSettingsDidChange(_: PumpSettings) {
        setupPumpSettings()
    }

    func basalProfileDidChange(_: [BasalProfileEntry]) {
        setupBasalProfile()
    }

    func tempTargetsDidUpdate(_: [TempTarget]) {
        setupTempTargets()
    }

    func carbsDidUpdate(_: [CarbsEntry]) {
        setupCarbs()
        setupAnnouncements()
        setupMeals()
    }

    func enactedSuggestionDidUpdate(_ suggestion: Suggestion) {
        enactedSuggestion = suggestion
        setStatusTitle()
        setupOverrideHistory()
        setupLoopStats()
        setupData()
    }

    func pumpBatteryDidChange(_: Battery) {
        setupBattery()
    }

    func pumpReservoirDidChange(_: Decimal) {
        setupReservoir()
        refreshInsulinTimeRemaining()
    }

    func pumpTimeZoneDidChange(_: TimeZone) {
        setupCurrentPumpTimezone()
    }
}

extension Home.StateModel: CompletionDelegate {
    func completionNotifyingDidComplete(_: CompletionNotifying) {
        setupPump = false
    }
}
