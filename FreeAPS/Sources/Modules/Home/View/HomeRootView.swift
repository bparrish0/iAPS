import Charts
import CoreData
import SpriteKit
import SwiftDate
import SwiftUI
import Swinject

extension Home {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state: StateModel
        @State var isStatusPopupPresented = false
        @State var showCancelAlert = false
        @State var showCancelTTAlert = false
        @State var triggerUpdate = false
        @State var display = false
        @State var displayGlucose = false
        @State var animateLoop = Date.distantPast
        @State var animateTIR = Date.distantPast
        @State var showBolusActiveAlert = false
        @State var displayAutoHistory = false
        @State var displayDynamicHistory = false
        @State private var isChartPanningEnabled = true
        @State private var inspectedGlucose: BloodGlucose?
        @State private var duoPosture = DuoTentPosture()
        @State private var tentLayoutFrames: [String: CGRect] = [:]
        @AppStorage("DuoTent.mode") private var tentMode = 0

        let buttonFont = Font.custom("TimeButtonFont", size: 14)
        let viewPadding: CGFloat = 5

        @Environment(\.managedObjectContext) var moc
        @Environment(\.sizeCategory) private var fontSize
        @Environment(\.colorScheme) var colorScheme
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        @FetchRequest(
            entity: Override.entity(),
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
        ) var fetchedPercent: FetchedResults<Override>

        @FetchRequest(
            entity: OverridePresets.entity(),
            sortDescriptors: [NSSortDescriptor(key: "name", ascending: true)], predicate: NSPredicate(
                format: "name != %@", "" as String
            )
        ) var fetchedProfiles: FetchedResults<OverridePresets>

        @FetchRequest(
            entity: Auto_ISF.entity(),
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
        ) var fetchedAISF: FetchedResults<Auto_ISF>

        @FetchRequest(
            entity: TempTargets.entity(),
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
        ) var sliderTTpresets: FetchedResults<TempTargets>

        @FetchRequest(
            entity: TempTargetsSlider.entity(),
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
        ) var enactedSliderTT: FetchedResults<TempTargetsSlider>

        @FetchRequest(
            entity: Onboarding.entity(),
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: false)]
        ) var onboarded: FetchedResults<Onboarding>

        private let numberFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            return formatter
        }()

        private let fetchedTargetFormatterMmol: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter
        }()

        private let fetchedTargetFormatterMgdl: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter
        }()

        private var fetchedTargetFormatter: NumberFormatter {
            state.data.units == .mmolL ? fetchedTargetFormatterMmol : fetchedTargetFormatterMgdl
        }

        private let targetFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter
        }()

        private let tirFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter
        }()

        private let dateFormatter: DateFormatter = {
            let dateFormatter = DateFormatter()
            dateFormatter.timeStyle = .short
            return dateFormatter
        }()

        private var spriteScene: SKScene {
            let scene = SnowScene()
            scene.scaleMode = .resizeFill
            scene.backgroundColor = .clear
            return scene
        }

        init(resolver: Resolver) {
            self.resolver = resolver
            _state = StateObject(wrappedValue: StateModel(resolver: resolver))
        }

        var glucoseView: some View {
            CurrentGlucoseView(
                recentGlucose: $state.recentGlucose,
                delta: $state.glucoseDelta,
                units: $state.data.units,
                alarm: $state.alarm,
                lowGlucose: $state.data.lowGlucose,
                highGlucose: $state.data.highGlucose,
                alwaysUseColors: $state.alwaysUseColors,
                displayDelta: $state.displayDelta,
                scrolling: $displayGlucose, displaySAGE: $state.displaySAGE,
                displayExpiration: $state.displayExpiration,
                sensordays: $state.sensorDays,
                inspectedGlucose: inspectedGlucose
            )
            .onTapGesture {
                if state.alarm == nil {
                    state.openCGM()
                } else {
                    state.showModal(for: .snooze)
                }
            }
            .onLongPressGesture {
                let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                impactHeavy.impactOccurred()
                if state.alarm == nil {
                    state.showModal(for: .snooze)
                } else {
                    state.openCGM()
                }
            }
        }

        var pumpView: some View {
            PumpView(
                reservoir: $state.reservoir,
                battery: $state.battery,
                name: $state.pumpName,
                expiresAtDate: $state.pumpExpiresAtDate,
                timerDate: $state.data.timerDate, timeZone: $state.timeZone,
                state: state
            )
            .onTapGesture {
                if state.pumpDisplayState != nil {
                    state.setupPump = true
                }
            }
            .offset(y: 1)
        }

        var loopView: some View {
            LoopView(
                suggestion: $state.data.suggestion,
                enactedSuggestion: $state.enactedSuggestion,
                closedLoop: $state.closedLoop,
                timerDate: $state.data.timerDate,
                isLooping: $state.isLooping,
                lastLoopDate: $state.lastLoopDate,
                manualTempBasal: $state.manualTempBasal,
                showTitle: !tentActive
            )
            .onTapGesture {
                state.isStatusPopupPresented.toggle()
            }.onLongPressGesture {
                let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                impactHeavy.impactOccurred()
                state.runLoop()
            }
        }

        var tempBasalString: String {
            guard let tempRate = state.tempRate else {
                return "?" + NSLocalizedString(" U/hr", comment: "Unit per hour with space")
            }
            let rateString = numberFormatter.string(from: tempRate as NSNumber) ?? "0"
            var manualBasalString = ""

            if state.apsManager.isManualTempBasal {
                manualBasalString = NSLocalizedString(
                    " Manual",
                    comment: "Manual Temp basal"
                )
            }
            return rateString + " " + NSLocalizedString(" U/hr", comment: "Unit per hour with space") + manualBasalString
        }

        var tempTargetString: String? {
            guard let tempTarget = state.tempTarget else {
                return nil
            }
            return tempTarget.displayName
        }

        var info: some View {
            HStack(spacing: 10) {
                ZStack {
                    HStack {
                        if state.pumpSuspended {
                            Text("Pump suspended")
                                .font(.extraSmall).bold().foregroundColor(.loopGray)
                        } else {
                            Text(tempBasalString)
                                .font(.statusFont).bold()
                                .foregroundColor(.insulin)
                        }
                    }
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let tempTargetString = tempTargetString, !(fetchedPercent.first?.enabled ?? false) {
                    Text(tempTargetString)
                        .font(.buttonFont)
                        .foregroundColor(.secondary)
                } else {
                    profileView
                }

                ZStack {
                    HStack {
                        Text("⇢").font(.statusFont).foregroundStyle(.secondary)

                        if let eventualBG = state.eventualBG {
                            Text(
                                fetchedTargetFormatter.string(
                                    from: (state.data.units == .mmolL ? eventualBG.asMmolL : Decimal(eventualBG)) as NSNumber
                                ) ?? ""
                            ).font(.statusFont).foregroundColor(colorScheme == .dark ? .white : .black)
                        } else {
                            Text("?").font(.statusFont).foregroundStyle(.secondary)
                        }
                        Text(state.data.units.rawValue).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }

        var infoPanel: some View {
            info.frame(height: 26)
                .background {
                    InfoPanelBackground(colorScheme: colorScheme)
                }
        }

        var mainChart: some View {
            ZStack {
                if state.animatedBackground {
                    SpriteView(scene: spriteScene, options: [.allowsTransparency])
                        .ignoresSafeArea()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
                MainChartView(
                    data: state.data,
                    triggerUpdate: $triggerUpdate,
                    isPanningEnabled: isChartPanningEnabled,
                    inspectedGlucose: $inspectedGlucose,
                    compactLayout: tentActive,
                    historyOnly: true
                )
            }
            .padding(.bottom, 5)
            .onTapGesture {
                if isChartPanningEnabled { state.showModal(for: .dataTable) }
            }
        }

        @ViewBuilder private var homeActionButtons: some View {
            let isOverride = fetchedPercent.first?.enabled ?? false
            let isTarget = state.tempTarget != nil
            if state.carbButton {
                Button { state.showModal(for: .addCarbs(editMode: false, override: false)) }
                label: {
                    ZStack(alignment: Alignment(horizontal: .trailing, vertical: .bottom)) {
                        Image(systemName: "fork.knife")
                            .renderingMode(.template)
                            .font(.custom("Buttons", size: 24))
                            .foregroundColor(colorScheme == .dark ? .loopYellow : .orange)
                            .padding(8)
                            .foregroundColor(.loopYellow)
                        if let carbsReq = state.carbsRequired {
                            Text(numberFormatter.string(from: carbsReq as NSNumber)!)
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Capsule().fill(Color.red))
                        }
                    }
                }.buttonStyle(.borderless)
                    .accessibilityLabel("Carbs")
            }
            Button {
                (state.bolusProgress != nil) ? showBolusActiveAlert = true :
                    state.showModal(for: .bolus(
                        waitForSuggestion: state.useCalc ? true : false,
                        fetch: false
                    ))
            }
            label: {
                Image(systemName: "syringe")
                    .renderingMode(.template)
                    .font(.custom("Buttons", size: 24))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.insulin)
            .accessibilityLabel("Bolus")
            if state.allowManualTemp {
                Button { state.showModal(for: .manualTempBasal) }
                label: {
                    Image("bolus1")
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: IAPSconfig.buttonSize, height: IAPSconfig.buttonSize, alignment: .bottom)
                }
                .foregroundColor(.insulin)
                .accessibilityLabel("Temporary basal")
            }
            if state.profileButton {
                ZStack(alignment: Alignment(horizontal: .trailing, vertical: .bottom)) {
                    Image(systemName: isOverride ? "person.fill" : "person")
                        .symbolRenderingMode(.palette)
                        .font(.custom("Buttons", size: 28))
                        .foregroundStyle(.purple)
                        .padding(8)
                        .background(isOverride ? .purple.opacity(0.15) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .onTapGesture {
                    if isOverride {
                        showCancelAlert.toggle()
                    } else {
                        state.showModal(for: .overrideProfilesConfig)
                    }
                }
                .onLongPressGesture {
                    state.showModal(for: .overrideProfilesConfig)
                }
                .accessibilityLabel("Profiles")
                .accessibilityAddTraits(.isButton)
            }
            if state.useTargetButton {
                Image(systemName: "target")
                    .renderingMode(.template)
                    .font(.custom("Buttons", size: 24))
                    .padding(8)
                    .foregroundColor(.loopGreen)
                    .background(isTarget ? .green.opacity(0.15) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture {
                        if isTarget {
                            showCancelTTAlert.toggle()
                        } else {
                            state.showModal(for: .addTempTarget)
                        }
                    }
                    .onLongPressGesture {
                        state.showModal(for: .addTempTarget)
                    }
                    .accessibilityLabel("Temporary target")
                    .accessibilityAddTraits(.isButton)
            }
            Button { state.showModal(for: .settings) }
            label: {
                Image(systemName: "gear")
                    .renderingMode(.template)
                    .font(.custom("Buttons", size: 24))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.gray)
            .accessibilityLabel("Settings")
        }

        @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
            if #available(iOS 27.1, *) {
                ToolbarItemGroup(placement: .bottomBar) {
                    homeActionButtons
                }
                .axisBehavior(.verticalPreferred)
            } else {
                ToolbarItemGroup(placement: .bottomBar) {
                    homeActionButtons
                }
            }
        }

        private func chart(height: CGFloat) -> some View {
            addColouredBackground().shadow(radius: 3, y: 3)
                .overlay {
                    mainChart
                }
                .frame(height: height)
                .overlay(alignment: .top) {
                    if tentActive, let progress = state.bolusProgress, let amount = state.bolusAmount {
                        bolusProgressPanel(progress: progress, amount: amount)
                            .padding(.top, 8)
                    }
                }
        }

        var carbsAndInsulinView: some View {
            HStack {
                // A temporary ugly(?) workaround for displaying last real IOB and COB computation
                let opacity: CGFloat = colorScheme == .dark ? 0.2 : 0.65
                let materialOpacity: CGFloat = colorScheme == .dark ? 0.25 : 0.10
                // Carbs on Board
                HStack {
                    let substance = Double(state.data.suggestion?.cob ?? 0)
                    let max = max(Double(state.maxCOB), 1)
                    let fraction: Double = 1 - (substance / max)
                    let fill = CGFloat(min(Swift.max(fraction, 0.05), substance > 0 ? 0.92 : 1))
                    TestTube(
                        opacity: opacity,
                        amount: fill,
                        colourOfSubstance: .loopYellow,
                        materialOpacity: materialOpacity
                    )
                    .frame(width: 12, height: 38)
                    .offset(y: -5)
                    HStack(spacing: 0) {
                        if let loop = state.data.suggestion, let cob = loop.cob {
                            Text(numberFormatter.string(from: cob as NSNumber) ?? "0")
                                .font(.statusFont).bold()
                            // Display last loop, unless very old
                        } else {
                            Text("?").font(.statusFont).bold()
                        }
                        Text(NSLocalizedString(" g", comment: "gram of carbs")).font(.statusFont).foregroundStyle(.secondary)
                    }.offset(y: 5)
                }
                // Instead of Spacer
                Text(" ")

                // Insulin on Board
                HStack {
                    let substance = Double(state.data.iob ?? 0)
                    let max = max(Double(state.maxIOB), 1)
                    let fraction: Double = 1 - abs(substance) / max
                    let fill = CGFloat(min(Swift.max(fraction, 0.05), 1))
                    TestTube(
                        opacity: opacity,
                        amount: fill,
                        colourOfSubstance: substance < 0 ? .red : .insulin,
                        materialOpacity: materialOpacity
                    )
                    .frame(width: 12, height: 38)
                    .offset(y: -5)
                    HStack(spacing: 0) {
                        if let iob = state.data.iob {
                            Text(
                                targetFormatter.string(from: iob as NSNumber) ?? "0"
                            ).font(.statusFont).bold()
                        } else {
                            Text("?").font(.statusFont).bold()
                        }
                        Text(NSLocalizedString(" U", comment: "Insulin unit")).font(.statusFont).foregroundStyle(.secondary)
                    }.offset(y: 5)
                }
            }.offset(x: 5, y: 5)
        }

        var preview: some View {
            addBackground()
                .frame(minHeight: 200)
                .overlay {
                    PreviewChart(
                        readings: $state.readings,
                        lowLimit: $state.data.lowGlucose,
                        highLimit: $state.data.highGlucose
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .addShadows()
                .padding(.horizontal, 10)
                .blur(radius: animateTIRView ? 2 : 0)
                .onTapGesture {
                    timeIsNowTIR()
                    state.showModal(for: .statistics)
                }
                .overlay {
                    if animateTIRView {
                        animation.asAny()
                    }
                }
        }

        var infoPanelView: some View {
            addBackground()
                .frame(height: 30)
                .overlay {
                    HStack {
                        info
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .addShadows()
                .padding(.horizontal, 10)
        }

        var activeIOBView: some View {
            addBackground()
                .frame(minHeight: 190)
                .overlay {
                    ActiveIOBView(
                        data: $state.iobData,
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .addShadows()
                .padding(.horizontal, 10)
        }

        var activeCOBView: some View {
            addBackground()
                .frame(minHeight: 190)
                .overlay {
                    ActiveCOBView(data: $state.iobData)
                }
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .addShadows()
                .padding(.horizontal, 10)
        }

        var insulinView: some View {
            addBackground()
                .frame(minHeight: 280)
                .overlay {
                    InsulinSummaryView(
                        neg: $state.neg,
                        tddChange: $state.tddChange,
                        tddAverage: $state.tddAverage,
                        tddYesterday: $state.tddYesterday,
                        tdd2DaysAgo: $state.tdd2DaysAgo,
                        tdd3DaysAgo: $state.tdd3DaysAgo,
                        tddActualAverage: $state.tddActualAverage
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .addShadows()
                .padding(.horizontal, 10)
        }

        var mealsView: some View {
            addBackground()
                .frame(minHeight: 190)
                .overlay {
                    MealsSummaryView(data: $state.mealData)
                }
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .addShadows()
                .padding(.horizontal, 10)
        }

        var loopPreview: some View {
            addBackground()
                .frame(minHeight: 160)
                .overlay {
                    LoopsView(loopStatistics: $state.loopStatistics)
                }
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .addShadows()
                .padding(.horizontal, 10)
                .blur(radius: animateLoopView ? 2.5 : 0)
                .onTapGesture {
                    timeIsNowLoop()
                    state.showModal(for: .statistics)
                }
                .overlay {
                    if animateLoopView {
                        animation.asAny()
                    }
                }
        }

        var profileView: some View {
            HStack(spacing: 0) {
                if let override = fetchedPercent.first {
                    if override.enabled {
                        if override.isPreset {
                            let profile = fetchedProfiles.first(where: { $0.id == override.id })
                            if let currentProfile = profile {
                                if let name = currentProfile.name, name != "EMPTY", name.nonEmpty != nil, name != "",
                                   name != "\u{0022}\u{0022}"
                                {
                                    if name.count > 15 {
                                        let shortened = name.prefix(15)
                                        Text(shortened).font(.statusFont).foregroundStyle(.secondary)
                                    } else {
                                        Text(name).font(.statusFont).foregroundStyle(.secondary)
                                    }
                                }
                            } else { Text("📉") } // Hypo Treatment is not actually a preset
                        } else if override.percentage != 100 {
                            Text((tirFormatter.string(from: override.percentage as NSNumber) ?? "") + " %").font(.statusFont)
                                .foregroundStyle(.secondary)
                        } else if override.smbIsOff, !override.smbIsAlwaysOff {
                            Text("No ").font(.statusFont).foregroundStyle(.secondary) // "No" as in no SMBs
                            Image(systemName: "syringe")
                                .font(.previewNormal).foregroundStyle(.secondary)
                        } else if override.smbIsOff {
                            Image(systemName: "clock").font(.statusFont).foregroundStyle(.secondary)
                            Image(systemName: "syringe")
                                .font(.previewNormal).foregroundStyle(.secondary)
                        } else {
                            Text("Override").font(.statusFont).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        private func bolusProgressPanel(progress: Decimal, amount: Decimal) -> some View {
            bolusProgressView(progress: progress, amount: amount)
                .frame(maxWidth: 320)
                .frame(height: 90)
                .background(.gray.opacity(0.9), in: RoundedRectangle(cornerRadius: 15))
        }

        func bolusProgressView(progress: Decimal, amount: Decimal) -> some View {
            ZStack {
                VStack {
                    HStack {
                        let bolused = targetFormatter.string(from: (amount * progress) as NSNumber) ?? ""
                        Text("Bolusing")
                        Text(
                            bolused + " " + NSLocalizedString("of", comment: "") + " " + amount
                                .formatted() + NSLocalizedString(" U", comment: "")
                        )
                    }
                    .font(.bolusProgressBarFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 300, height: 34)
                    HStack(alignment: .bottom, spacing: 5) {
                        ProgressView(value: Double(progress)).progressViewStyle(BolusProgressViewStyle())
                            .overlay {
                                Image(systemName: "pause.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .blue)
                                    .font(.bolusProgressStopFont)
                            }
                    }
                    .onTapGesture { state.cancelBolus() }
                }
                .dynamicTypeSize(...DynamicTypeSize.large)
                .padding(.bottom, 8)
            }
        }

        @ViewBuilder private func headerView(_ geo: GeometryProxy) -> some View {
            let height: CGFloat = displayGlucose ? 140 : 210
            addHeaderBackground()
                .frame(
                    height: fontSize < .extraExtraLarge ? height + geo.safeAreaInsets.top : height + 10 + geo
                        .safeAreaInsets.top
                )
                .clipShape(Rectangle())
                .overlay {
                    VStack {
                        ZStack {
                            if !displayGlucose {
                                glucoseView.frame(maxHeight: .infinity, alignment: .center).offset(y: -5)
                                loopView
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity,
                                        alignment: .topLeading
                                    )
                                    .padding(20)
                                    .offset(x: 5, y: -10)
                                BatteryTimeRemainingView(
                                    expirationDate: state.battery?.batteryExpirationDate,
                                    label: "P",
                                    labelColor: .purple,
                                    timerDate: $state.data.timerDate
                                )
                                .padding(6)
                                .contentShape(Rectangle())
                                .onTapGesture { state.presentBatteryDetail(.pump) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .padding(.trailing, 9)
                                .padding(.bottom, 44)
                                BatteryTimeRemainingView(
                                    expirationDate: state.orangeLinkExpirationDate,
                                    label: "O",
                                    labelColor: .orange,
                                    timerDate: $state.data.timerDate
                                )
                                .padding(6)
                                .contentShape(Rectangle())
                                .onTapGesture { state.presentBatteryDetail(.orangeLink) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                .padding(.leading, 9)
                                .padding(.bottom, 44)
                                BatteryTimeRemainingView(
                                    expirationDate: state.insulinExpirationDate,
                                    label: "I",
                                    labelColor: .insulin,
                                    timerDate: $state.data.timerDate
                                )
                                .italic(state.insulinEstimateUsesLatestTddOnly)
                                .padding(6)
                                .contentShape(Rectangle())
                                .onTapGesture { state.toggleInsulinEstimateMode() }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            }
                            if displayGlucose {
                                glucoseView.frame(maxHeight: .infinity, alignment: .center).offset(y: -10)
                            } else {
                                HStack {
                                    carbsAndInsulinView
                                        .frame(maxHeight: .infinity, alignment: .bottom)
                                    Spacer()
                                    pumpView
                                        .frame(maxHeight: .infinity, alignment: .bottom)
                                }
                                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 5)
                            }
                        }

                        if displayGlucose {
                            glucosePreview
                        } else {
                            infoPanelView
                        }

                        Divider()
                    }
                    .padding(.top, geo.safeAreaInsets.top)
                }
        }

        var glucosePreview: some View {
            let data = state.data.glucose
            let minimum = data.compactMap(\.glucose).min() ?? 0
            let minimumRange = Double(minimum) * 0.8
            let maximum = Double(data.compactMap(\.glucose).max() ?? 0) * 1.1

            let high = state.data.highGlucose
            let low = state.data.lowGlucose
            let veryHigh = 198

            return Chart(data) {
                PointMark(
                    x: .value("Time", $0.dateString),
                    y: .value("Glucose", Double($0.glucose ?? 0) * (state.data.units == .mmolL ? 0.0555 : 1.0))
                )
                .foregroundStyle(
                    (($0.glucose ?? 0) > veryHigh || Decimal($0.glucose ?? 0) < low) ? Color(.red) : Decimal($0.glucose ?? 0) >
                        high ? Color(.yellow) : Color(.darkGreen)
                )
                .symbolSize(5)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3))
            }
            .chartYScale(
                domain: minimumRange * (state.data.units == .mmolL ? 0.0555 : 1.0) ... maximum *
                    (state.data.units == .mmolL ? 0.0555 : 1.0)
            )
            .chartXScale(
                domain: Date.now.addingTimeInterval(-1.days.timeInterval) ... Date.now
            )
            .frame(height: 50)
            .padding(.leading, 30)
            .padding(.trailing, 32)
            .padding(.top, 15)
            .dynamicTypeSize(DynamicTypeSize.medium ... DynamicTypeSize.large)
        }

        var timeSetting: some View {
            let hourLabel = NSLocalizedString("\(state.hours) hours", comment: "") + "   "

            return Menu(hourLabel) {
                ForEach([3, 6, 9, 12, 24], id: \.self) { value in
                    let label = NSLocalizedString("\(value) hours", comment: "")
                    Button(label, action: { state.hours = value })
                }

                Button("UI/UX Settings", action: {
                    state.showModal(for: .statisticsConfig)
                })
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .font(.timeSettingFont)
            .padding(.vertical, tentActive ? 8 : 15)
            .background(TimeEllipse(characters: hourLabel.count))
        }

        private var isfView: some View {
            ZStack {
                HStack(spacing: 4) {
                    Image(systemName: "divide")
                        .font(.system(size: 16))
                        .foregroundStyle(.teal)

                    Text(String(describing: state.data.suggestion?.sensitivityRatio ?? 1))
                        .foregroundStyle(.primary)
                        .lineLimit(1) // maximum 1 row
                        .fixedSize(horizontal: true, vertical: false) // Prevent wrapping
                }
                .font(.timeSettingFont)
                .background(TimeEllipse(characters: 10))
                .onTapGesture {
                    if (state.autoisf && !disabled()) || enabled() {
                        displayAutoHistory.toggle()
                    } else {
                        displayDynamicHistory.toggle()
                    }
                }
            }
        }

        private func enabled() -> Bool {
            guard let or = fetchedPercent.first, or.enabled else { return false }
            guard let aisf = fetchedAISF.first else { return false }
            return aisf.autoisf
        }

        private func disabled() -> Bool {
            guard let or = fetchedPercent.first, or.enabled else { return false }
            guard let aisf = fetchedAISF.first else { return false }
            return !aisf.autoisf
        }

        private var animateLoopView: Bool {
            -1 * animateLoop.timeIntervalSinceNow < 1.5
        }

        private var animateTIRView: Bool {
            -1 * animateTIR.timeIntervalSinceNow < 1.5
        }

        private func timeIsNowLoop() {
            animateLoop = Date.now
        }

        private func timeIsNowTIR() {
            animateTIR = Date.now
        }

        private var animation: any View {
            ActivityIndicator(isAnimating: .constant(true), style: .large)
        }

        private var tentActive: Bool { duoPosture.isActive(mode: tentMode) }

        private var homeBackground: Color {
            if tentActive { return .black }
            return colorScheme == .light ? IAPSconfig.homeViewBackgroundLight : IAPSconfig.homeViewBackgrundDark
        }

        private var tentDisplayControls: some View {
            HStack {
                timeSetting
                    .overlay(alignment: .topLeading) {
                        TentIOBView(data: state.data)
                            .offset(y: 36)
                    }
                chartPanButton
                loopView
                Spacer()
            }
            .font(.subheadline)
            .padding(.trailing, 16)
        }

        private var chartPanButton: some View {
            Button {
                inspectedGlucose = nil
                isChartPanningEnabled.toggle()
            } label: {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isChartPanningEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: tentActive ? 36 : 44, height: tentActive ? 36 : 44)
                    .background(isChartPanningEnabled ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scroll chart history")
            .accessibilityValue(isChartPanningEnabled ? "On" : "Off")
            .accessibilityHint("When off, drag on the chart to inspect glucose readings.")
        }

        private func tentReading(fontSize: CGFloat) -> some View {
            VStack(spacing: 8) {
                TentGlucoseView(
                    data: state.data,
                    recentGlucose: state.recentGlucose,
                    inspectedGlucose: inspectedGlucose,
                    delta: state.glucoseDelta,
                    fontSize: fontSize
                )
            }
            .frame(maxWidth: .infinity)
        }

        private func tentDashboard(_ geo: GeometryProxy, controlTopInset: CGFloat) -> some View {
            let usableHeight = geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom
            // SwiftUI's content area excludes the toolbar and camera/status rail.
            // Center the reading in the actual window instead.
            let contentFrame = geo.frame(in: .global)
            let centerOffset = duoPosture.windowBounds.width > 0
                ? duoPosture.windowBounds.midX - contentFrame.midX : 0
            let readingHeight: CGFloat = {
                guard let controls = tentLayoutFrames["controls"], let toolbar = tentLayoutFrames["toolbar"] else {
                    return min(220, usableHeight * 0.4)
                }
                return max(80, toolbar.minY - controls.maxY - 2)
            }()
            let readingFontSize = min(190, geo.size.width * 0.38, max(28, (readingHeight - 54) / 1.1))
            return VStack(spacing: 1) {
                tentDisplayControls
                    .offset(y: controlTopInset)
                    // Measure the original row so moving its controls below the
                    // camera does not move the glucose or shrink the chart.
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: TentLayoutFramesKey.self, value: ["controls": proxy.frame(in: .global)])
                        }
                    }
                tentReading(fontSize: readingFontSize)
                    // Keep the glucose size while reclaiming the tightened header's space for the chart.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: max(48, readingHeight - 32))
                    .offset(x: centerOffset, y: -26)
                GeometryReader { chartArea in
                    chart(height: max(140, chartArea.size.height))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, geo.safeAreaInsets.top + 2)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        @ViewBuilder private func dashboard(_ geo: GeometryProxy) -> some View {
            // Use the window's current geometry so folding and window resizing work
            // without relying on a device model or the dimensions of another display.
            let isWide = geo.size.width >= 700
            if isWide {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        headerView(geo)
                        Spacer(minLength: 0)
                    }
                    .frame(width: min(360, max(320, geo.size.width * 0.4)))
                    Divider()
                    GeometryReader { chartArea in
                        dashboardScroll(chartHeight: max(180, chartArea.size.height - 60))
                    }
                    .padding(.top, geo.safeAreaInsets.top)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
                }
            } else {
                VStack(spacing: 0) {
                    headerView(geo)
                    GeometryReader { chartArea in
                        dashboardScroll(chartHeight: max(180, chartArea.size.height - 60))
                    }
                }
            }
        }

        private func dashboardScroll(chartHeight: CGFloat) -> some View {
            ScrollView {
                VStack {
                    // Main Chart
                    chart(height: chartHeight)
                    // Adjust hours visible (X-Axis) and ratio display
                    HStack {
                        Spacer(minLength: 0)
                        timeSetting
                        Spacer(minLength: 12)
                        chartPanButton
                        Spacer(minLength: 12)
                        isfView
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    // TIR Chart
                    if !state.data.glucose.isEmpty {
                        preview.padding(.top, 15)
                    }
                    // Loops Chart
                    loopPreview.padding(.vertical, 15)

                    // COB Chart
                    if state.carbData > 0 {
                        activeCOBView.padding(.bottom, 15)
                    }

                    // IOB Chart
                    if !state.iobData.isEmpty {
                        activeIOBView.padding(.bottom, 15)
                    }

                    // Summary Views
                    insulinView.padding(.bottom, 15)
                    mealsView.padding(.bottom, 15)
                }
                .background {
                    // Track vertical scroll
                    GeometryReader { proxy in
                        let scrollPosition = proxy.frame(in: .named("HomeScrollView")).minY
                        let yThreshold: CGFloat = -550
                        Color.clear
                            .onChange(of: scrollPosition) {
                                if scrollPosition < yThreshold, state.iobs > 0 || state.carbData > 0,
                                   !state.skipGlucoseChart
                                {
                                    withAnimation(.easeOut(duration: 0.3)) { displayGlucose = true }
                                } else {
                                    withAnimation(.easeOut(duration: 0.4)) { displayGlucose = false }
                                }
                            }
                    }
                }
            }.coordinateSpace(name: "HomeScrollView")
        }

        @Environment(\.scenePhase) private var scenePhase

        var body: some View {
            GeometryReader { window in
                let useSideColumn = tentActive || (horizontalSizeClass == .regular && window.size.height > window.size.width)
                let showActions = !(onboarded.first?.firstRun ?? true) || state.openAPSSettings == nil
                let leadingInset = max(window.safeAreaInsets.leading, window.frame(in: .global).minX - duoPosture.windowBounds.minX)
                let trailingInset = max(window.safeAreaInsets.trailing, duoPosture.windowBounds.maxX - window.frame(in: .global).maxX)
                HStack(spacing: 0) {
                    GeometryReader { geo in
                        if onboarded.first?.firstRun ?? true, let openAPSSettings = state.openAPSSettings {
                            /// If old iAPS user pre v5.7.1 OpenAPS settings will be reset, but can be restored in View below
                            importResetSettingsView(settings: openAPSSettings)
                        } else {
                            Group {
                                if tentActive {
                                    tentDashboard(geo, controlTopInset: leadingInset > 0 ? 64 : 0)
                                } else {
                                    dashboard(geo)
                                }
                            }
                                .background(homeBackground)
                                .environment(\.colorScheme, tentActive ? .dark : colorScheme)
                                .ignoresSafeArea(edges: .vertical)
                                .overlay {
                                    if !tentActive, let progress = state.bolusProgress, let amount = state.bolusAmount {
                                        bolusProgressPanel(progress: progress, amount: amount)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .offset(y: -100)
                                    }
                                }
                                .onChange(of: scenePhase) {
                                    switch scenePhase {
                                    case .active:
                                        state.startTimer()
                                    case .background,
                                         .inactive:
                                        inspectedGlucose = nil
                                        state.stopTimer()
                                    default:
                                        break
                                    }
                                }
                        }
                    }
                    if showActions, useSideColumn {
                        VStack {
                            if tentActive {
                                TentPhoneBatteryView(compact: true)
                                    .padding(.top, window.safeAreaInsets.top + 2)
                                    .offset(x: -6)
                            }
                            Spacer(minLength: 0)
                            VStack(spacing: 14) {
                                homeActionButtons
                            }
                            .padding(.vertical, 12)
                            .frame(width: 52)
                            .background(.ultraThinMaterial, in: Capsule())
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: TentLayoutFramesKey.self,
                                        value: tentActive ? ["toolbar": proxy.frame(in: .global)] : [:]
                                    )
                                }
                            }
                        }
                        .frame(width: tentActive ? 64 : 52)
                        .padding(.horizontal, 6)
                        .padding(.bottom, tentActive && trailingInset > 0 ? 42 : 12)
                    }
                }
                .ignoresSafeArea(.container, edges: tentActive ? .horizontal : [])
                .background { homeBackground.ignoresSafeArea() }
                .toolbar {
                    if showActions, !useSideColumn {
                        homeToolbar
                    }
                }
            }
            .onPreferenceChange(TentLayoutFramesKey.self) { frames in
                if frames != tentLayoutFrames { tentLayoutFrames = frames }
            }
            .onAppear {
                if onboarded.first?.firstRun ?? true {
                    state.fetchPreferences()
                }
            }
            .background {
                DuoPostureObserver { posture in
                    if duoPosture != posture { duoPosture = posture }
                }
                .allowsHitTesting(false)
                TentScreenAwake(posture: duoPosture, isAppActive: tentActive && scenePhase == .active)
                    .frame(width: 0, height: 0)
            }
            .onChange(of: tentActive) { inspectedGlucose = nil }
            .navigationTitle("Home")
            .navigationBarHidden(true)
            .confirmationDialog("Cancel Profile Override", isPresented: $showCancelAlert) {
                Button("Cancel Profile Override", role: .destructive) {
                    state.cancelProfile()
                    triggerUpdate.toggle()
                }
            }
            .confirmationDialog("Cancel Temporary Target", isPresented: $showCancelTTAlert) {
                Button("Cancel Temporary Target", role: .destructive) {
                    state.cancelTempTarget()
                }
            }
            .confirmationDialog("Bolus already in Progress", isPresented: $showBolusActiveAlert) {
                Button("Bolus already in Progress!", role: .destructive) {
                    showBolusActiveAlert = false
                }
            }
            .ignoresSafeArea(.keyboard)
            .sheet(isPresented: $displayAutoHistory) {
                AutoISFHistoryView(units: state.data.units)
                    .environment(\.colorScheme, colorScheme)
            }
            .sheet(isPresented: $displayDynamicHistory) {
                DynamicHistoryView(units: state.data.units)
                    .environment(\.colorScheme, colorScheme)
            }
            .sheet(item: $state.batteryDetailKind) { kind in
                BatteryDetailView(kind: kind, state: state)
                    .environment(\.colorScheme, colorScheme)
            }
            .popup(isPresented: state.isStatusPopupPresented, alignment: .bottom, direction: .bottom) {
                popup
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.popUpGray)
                    )
                    .onTapGesture {
                        state.isStatusPopupPresented = false
                    }
                    .gesture(
                        DragGesture(minimumDistance: 10, coordinateSpace: .local)
                            .onEnded { value in
                                if value.translation.height < 0 {
                                    state.isStatusPopupPresented = false
                                }
                            }
                    )
            }
        }

        private var popup: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.statusTitle).font(.suggestionHeadline).foregroundColor(.white)
                    .padding(.bottom, 4)
                if let suggestion = state.data.suggestion {
                    TagCloudView(tags: suggestion.reasonParts).animation(.none, value: false)

                    Text(suggestion.reasonConclusion.capitalizingFirstLetter()).font(.suggestionSmallParts)
                        .foregroundColor(.white)
                } else {
                    Text("No suggestion found").font(.suggestionHeadline).foregroundColor(.white)
                }
                if let errorMessage = state.errorMessage, let date = state.errorDate {
                    Text(NSLocalizedString("Status at", comment: "") + " " + dateFormatter.string(from: date))
                        .foregroundColor(.white)
                        .font(.suggestionError)
                        .padding(.bottom, 4)
                        .padding(.top, 8)
                    Text(errorMessage).font(.suggestionError).fontWeight(.semibold).foregroundColor(.orange)
                } else if let suggestion = state.data.suggestion, (suggestion.bg ?? 100) == 400 {
                    Text("Invalid CGM reading (HIGH).").font(.suggestionError).bold().foregroundColor(.loopRed).padding(.top, 8)
                    Text("SMBs and High Temps Disabled.").font(.suggestionParts).foregroundColor(.white).padding(.bottom, 4)
                }
            }
        }

        private func importResetSettingsView(settings: Preferences) -> some View {
            Restore.RootView(
                resolver: resolver,
                openAPS: settings
            )
        }
    }
}
