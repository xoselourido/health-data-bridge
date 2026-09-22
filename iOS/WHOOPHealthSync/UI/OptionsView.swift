import AppIntents
import SwiftUI
import WHOOPHealthSyncCore
#if os(iOS)
import UIKit
#endif

struct OptionsView: View {
    @ObservedObject var viewModel: SyncViewModel
    @State private var showsAccountBindingConfirmation = false
    @Binding var appLanguage: AppLanguage
    @Binding var presentedSheet: SyncSheet?

    var body: some View {
        Form {
            if viewModel.requiresAccountBinding {
                Section("Account for saved sync progress") {
                    Text("Confirm that the saved sync progress belongs to your current WHOOP account before reusing it. Your existing progress will be retained.")
                    if case let .authenticated(email) = viewModel.authStatus {
                        Text(email)
                        Button("Confirm this account") { showsAccountBindingConfirmation = true }
                            .disabled(viewModel.isSyncing || viewModel.isAuthenticating || viewModel.isBindingAccount)
                            .accessibilityIdentifier("account.confirmSavedProgress")
                    } else {
                        Text("Connect WHOOP to confirm the account for saved sync progress.")
                    }
                }
                .confirmationDialog("Does the saved sync progress belong to this WHOOP account?", isPresented: $showsAccountBindingConfirmation, titleVisibility: .visible) {
                    Button("Confirm this account") { Task { await viewModel.confirmExistingAccount() } }
                    Button("Cancel", role: .cancel) {}
                }
            }
            Section("Data to sync") {
                Label("Sleep", systemImage: "moon.zzz.fill")
                Label("Heart rate", systemImage: "heart.fill")
                Text("Recovery HRV")
                Text(LocalizedStringKey(viewModel.recoveryStatusKey))
                    .accessibilityIdentifier("recovery.status")
                Text("Imports the HRV measured during the main sleep, not the WHOOP recovery percentage. Subsequent syncs review the last seven days. No daytime readings are generated.")
                    .font(.footnote)
                Button("Configure sync") { presentedSheet = .configuration }
                    .disabled(viewModel.isSyncing || viewModel.isAuthenticating || viewModel.isConfiguringRecovery || !isAuthenticated || !viewModel.repositoryAvailable)
                    .accessibilityIdentifier("recovery.configure")
            }
            Section("Historical import") {
                Text("Import an earlier period for sleep, heart rate and configured HRV. Daily sync and Shortcuts keep their saved progress.")
                    .font(.footnote)
                Button("Import an earlier period") { presentedSheet = .history }
                    .disabled(!viewModel.canImportHistory)
                    .accessibilityIdentifier("recovery.importHistory")
                if viewModel.hasPendingHistoryImport || (viewModel.recoveryState.initialImportCutoff != nil && !viewModel.recoveryState.historicalResolved) {
                    if let cutoff = viewModel.historyCutoff {
                        LabeledContent { Text(cutoff, style: .date) } label: { Text("Fixed history cutoff") }
                    }
                    if let remaining = viewModel.pendingHistoryWindow {
                        LabeledContent { Text(remaining.start, style: .date) } label: { Text("Next historical window") }
                    }
                    Text(LocalizedStringKey(viewModel.historyPhase == "recovery" ? "History phase: recovery HRV" : "History phase: sleep and heart rate"))
                    Button("Resume historical import") { Task { await viewModel.importHistory(start: nil) } }
                        .disabled(!viewModel.canImportHistory)
                        .accessibilityIdentifier("history.resume")
                }
                if viewModel.isSyncing {
                    ProgressView()
                    LabeledContent("Recovery history pages", value: "\(viewModel.recoveryProgress.pagesConfirmed)")
                    LabeledContent("Recovery HRV written", value: "\(viewModel.recoveryProgress.written)")
                    Button("Stop import") { viewModel.cancelRecoveryImport() }
                }
            }

            #if WHOOP_VALIDATION_BUILD
            Section("Read-only recovery validation") {
                Text("Uses the existing WHOOP cycles route and shows field names and types only. Does not request HealthKit access or write health data.")
                Button("Inspect WHOOP recovery schema") { Task { await viewModel.probeRecoverySchema() } }
                    .disabled(viewModel.isSyncing || viewModel.isAuthenticating || viewModel.isProbingRecovery)
                Text("This additional diagnostic displays your HRV values and sleep dates locally to compare with WHOOP. It does not write to Health or include account identifiers or credentials.")
                    .font(.footnote)
                Button("Compare recovery values with WHOOP") { Task { await viewModel.probeRecoveryValues() } }
                    .disabled(viewModel.isSyncing || viewModel.isAuthenticating || viewModel.isProbingRecovery)
                    .accessibilityIdentifier("recovery.compareValues")
                if viewModel.isProbingRecovery { ProgressView() }
                if !viewModel.recoveryProbeText.isEmpty {
                    Text(viewModel.recoveryProbeText).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            #endif

            Section {
                Picker("App language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Automatic uses Spanish when the iPhone is set to Spanish and English for every other language.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sync with Shortcuts", systemImage: "wand.and.stars")
                        .font(.headline)
                    Text("Open Shortcuts to add the Sync WHOOP action or include it in a personal automation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                #if os(iOS)
                ShortcutsLink()
                #else
                Text("Open Shortcuts on your iPhone to add the Sync WHOOP action.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif
            } header: {
                Text("Automation")
            }

            Section {
                NavigationLink {
                    SyncActivityView(viewModel: viewModel)
                } label: {
                    HStack(spacing: 12) {
                        Label("Activity and diagnostics", systemImage: "list.bullet.rectangle.portrait")
                        Spacer()
                        if !viewModel.errors.isEmpty {
                            Text("\(viewModel.errors.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.red, in: Capsule())
                        }
                    }
                }
            } footer: {
                Text("Detailed sync windows, summaries, errors, events and the local log.")
            }

            Section {
                Text("Independent project. Not affiliated with, sponsored by, or endorsed by WHOOP.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }

        }
        .navigationTitle("Options")
    }

    private var isAuthenticated: Bool {
        if case .authenticated = viewModel.authStatus { return true }; return false
    }
}

struct SyncSetupView: View {
    @ObservedObject var viewModel: SyncViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var includeRecovery = true
    @State private var fullReading = false
    @State private var nativeExportChecked = false
    @State private var sourceBundle = ""
    @State private var continuingWithoutRecovery = false

    private var needsReadConfirmation: Bool {
        guard let authorization = viewModel.recoveryAuthorization else { return false }
        if case .unknown = authorization.access { return true }
        return false
    }
    private var nativeExporter: Bool {
        guard let authorization = viewModel.recoveryAuthorization else { return false }
        if case .nativeExporter = authorization.access { return true }
        return false
    }
    private var ready: Bool {
        viewModel.dataAuthorizationCompleted && !viewModel.requiresAccountBinding && !viewModel.isConfiguringRecovery &&
        (!effectiveRecovery || (viewModel.recoveryAuthorization?.writeAuthorized == true &&
            (nativeExporter || (nativeExportChecked && (!needsReadConfirmation || fullReading)))))
    }
    private var effectiveRecovery: Bool { includeRecovery && viewModel.supportsRecovery }
    var body: some View {
        NavigationStack {
            Form {
                Section("Data to sync") {
                    Label("Sleep", systemImage: "moon.zzz.fill")
                    Label("Heart rate", systemImage: "heart.fill")
                    Toggle("Recovery HRV", isOn: $includeRecovery)
                        .disabled(!viewModel.supportsRecovery || viewModel.isConfiguringRecovery)
                        .accessibilityIdentifier("sync.includeHRV")
                    if !viewModel.supportsRecovery { Text("Requires iOS 27 and support for RMSSD HRV").foregroundStyle(.secondary) }
                    Text("Recovery HRV is RMSSD in milliseconds, not WHOOP recovery percentage or SDNN.").font(.footnote)
                    Text(LocalizedStringKey(viewModel.needsInitialSetup
                         ? "Your first sync covers the last seven days. Import an earlier period later in Options."
                         : "Your account, imported data and saved progress are retained. This does not restart history."))
                        .font(.footnote)
                }
                Section("Health access") {
                    Button("Authorize selected data") {
                        fullReading = false; nativeExportChecked = false
                        Task { await viewModel.authorizeSyncData(includeRecovery: includeRecovery && viewModel.supportsRecovery) }
                    }
                    .disabled(viewModel.isConfiguringRecovery || viewModel.isSyncing || viewModel.isAuthenticating)
                    .accessibilityIdentifier("recovery.authorize")
                    if viewModel.isConfiguringRecovery { ProgressView() }
                    if let authorization = viewModel.selectedDataAuthorization {
                        if let date = authorization.sleepReadBoundary {
                            Text("Sleep: reading limited from"); Text(date, style: .date)
                        }
                        if let date = authorization.heartRateReadBoundary {
                            Text("Heart rate: reading limited from"); Text(date, style: .date)
                        }
                    }
                    Text("A completed request does not confirm all Health permissions. Reading may remain unknown. Review this app's data access in Health. Cancelling here cannot undo Apple's permission choices.").font(.footnote)
                    if let authorization = viewModel.recoveryAuthorization {
                        if !authorization.writeAuthorized {
                            Text("Recovery HRV writing is not authorized. Review access in Health or continue without HRV.")
                        }
                        if case let .limited(date) = authorization.access {
                            Text("Health reading is limited from")
                            Text(date, style: .date)
                            Text("Older recoveries remain pending until reading covers their sleep dates.")
                        }
                        if nativeExporter {
                            Text("WHOOP already writes recovery HRV to Health. Continue with sleep and heart rate to avoid duplicates.")
                        } else {
                            if !authorization.sources.isEmpty {
                                Picker("WHOOP source in Health", selection: $sourceBundle) {
                                    Text("Not identified").tag("")
                                    ForEach(authorization.sources) { source in Text(source.name).tag(source.bundle) }
                                }
                            }
                            Toggle("I checked that WHOOP does not already write recovery HRV to Health", isOn: $nativeExportChecked)
                                .accessibilityIdentifier("recovery.confirmNoNativeExport")
                            Text("Does WHOOP already save your recovery HRV in Health? Check its data sources to avoid importing it twice. Select only a source you recognize; names alone do not identify WHOOP.").font(.footnote)
                            if needsReadConfirmation {
                                Text("Health does not reveal denied reading when only this app's data or no data is visible. Check that recovery HRV reading is allowed for all dates in Health before enabling import.")
                                    .font(.footnote)
                                Toggle("I allowed recovery HRV reading for all dates", isOn: $fullReading)
                                    .accessibilityIdentifier("recovery.confirmFullReading")
                            }
                        }
                        Button("Continue with sleep and heart rate") {
                            continuingWithoutRecovery = true
                            includeRecovery = false
                            viewModel.continueSetupWithoutRecovery()
                        }
                        .accessibilityIdentifier("sync.continueWithoutHRV")
                    }
                    if viewModel.dataAuthorizationCompleted && (!includeRecovery || !viewModel.supportsRecovery) {
                        Text("Health access requested. HRV can be enabled later in Configure sync.").font(.footnote)
                    }
                }
                if viewModel.requiresAccountBinding {
                    Section { Text("Confirm the account for saved sync progress in Options before enabling recovery HRV.") }
                }
                if let error = viewModel.errors.last {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button(LocalizedStringKey(viewModel.needsInitialSetup ? "Save and sync" : "Save configuration")) {
                        Task {
                            let firstSetup = viewModel.needsInitialSetup
                            if await viewModel.completeSyncSetup(includeRecovery: effectiveRecovery,
                                fullReadConfirmed: needsReadConfirmation && fullReading,
                                whoopBundle: sourceBundle.isEmpty ? nil : sourceBundle) {
                                dismiss()
                                if firstSetup { await viewModel.synchronize() }
                            }
                        }
                    }
                    .disabled(!ready)
                    .accessibilityIdentifier("recovery.enable")
                }
            }
            .navigationTitle("Configure sync")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .interactiveDismissDisabled(viewModel.isConfiguringRecovery)
            .onAppear {
                includeRecovery = viewModel.supportsRecovery && (viewModel.needsInitialSetup || viewModel.recoveryState.enabled)
                sourceBundle = viewModel.recoveryState.officialWhoopBundle ?? ""
                viewModel.resetSetupAuthorization()
            }
            .onChange(of: includeRecovery) { _, _ in
                if continuingWithoutRecovery { continuingWithoutRecovery = false }
                else { viewModel.resetSetupAuthorization() }
                fullReading = false; nativeExportChecked = false; sourceBundle = ""
            }
            .onChange(of: sourceBundle) { _, _ in
                fullReading = false; nativeExportChecked = false
            }
        }
    }
}

struct HistoryImportView: View {
    @ObservedObject var viewModel: SyncViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-30 * 86400))

    var body: some View {
        NavigationStack {
            Form {
                Section("Historical import") {
                    DatePicker("Import from", selection: $start, in: ...Date(), displayedComponents: .date)
                    Text("Imports the indicated period up to now for sleep, heart rate and configured HRV. Existing data is checked before writing. Completion does not certify all WHOOP history.")
                        .font(.footnote)
                    Text("Daily sync keeps its checkpoints. You can stop this import and resume it in Options.")
                        .font(.footnote)
                    if let saved = viewModel.recoveryState.historyStartDate, saved < start {
                        Text("Existing wider HRV history is retained. Any pending HRV work can include that earlier period.")
                            .font(.footnote)
                    }
                }
                Section {
                    Button("Import indicated history") {
                        let date = Calendar.current.startOfDay(for: start)
                        dismiss()
                        Task { await viewModel.importHistory(start: date) }
                    }
                    .disabled(!viewModel.canImportHistory)
                    .accessibilityIdentifier("history.start")
                }
            }
            .navigationTitle("Historical import")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct SyncActivityView: View {
    @ObservedObject var viewModel: SyncViewModel
    @Environment(\.locale) private var locale
    @State private var diagnosticCopyMessage: LocalizedStringKey?

    var body: some View {
        List {
            if !viewModel.errors.isEmpty {
                Section("Current issues") {
                    ForEach(viewModel.errors, id: \.self) { error in
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let summary = viewModel.lastSummary {
                Section("Latest sync summary") {
                    localizedMetric("Result", summary.hasIncompleteResults ? "Partial result; review pending data" : "Sync finished")
                    metric("Recovery HRV written", summary.recovery.written)
                    metric("Recovery HRV skipped", summary.recovery.skippedExternal)
                    metric("Recovery history pages", summary.recovery.pagesConfirmed)
                    metric("Unverified recoveries skipped", summary.recovery.invalid)
                    metric("Sleeps downloaded", summary.sleepsDownloaded)
                    metric("Sleeps written", summary.sleepsWritten)
                    metric("Sleeps unchanged", summary.sleepsUnchanged)
                    metric("Sleeps revised", summary.sleepsRevised)
                    metric("Sleeps outside the window", summary.sleepsDiscardedOutOfWindow)
                    metric("Stages written", summary.stagesWritten)
                    metric("Stages skipped", summary.stagesSkipped)
                    metric("Stages removed", summary.stagesRemoved)
                    metric("Heart-rate samples downloaded", summary.heartRateDownloaded)
                    metric("Heart-rate samples written", summary.heartRateWritten)
                    metric("Heart-rate samples skipped", summary.heartRateSkipped)
                    metric("Heart-rate samples removed", summary.heartRateRemoved)
                    metric("Heart-rate samples outside the window", summary.heartRateDiscardedOutOfWindow)
                    if let resolution = summary.effectiveHeartRateResolution {
                        metric("Heart-rate resolution", "\(resolution) s")
                    }
                    metric("Sleep window", dateRange(start: summary.sleepQueryWindowStart, end: summary.sleepQueryWindowEnd))
                    metric("Heart-rate window", dateRange(start: summary.heartRateWindowStart, end: summary.heartRateWindowEnd))
                    metric("Elapsed time", "\(String(format: "%.1f", summary.elapsedSeconds)) s")
                }
            }

            Section("Recovery HRV progress") {
                Text(LocalizedStringKey(viewModel.recoveryStatusKey))
                if let date = viewModel.recoveryState.historyStartDate { metric("WHOOP history starts", dateValue(date)) }
                if let date = viewModel.recoveryState.initialImportCutoff { metric("Initial history cutoff", dateValue(date)) }
                if let date = viewModel.recoveryState.oldestEnumeratedDate { metric("Oldest enumerated recovery", dateValue(date)) }
                metric("Recovery history pages", viewModel.recoveryState.historicalPagesConfirmed)
                metric("Pending recoveries", viewModel.recoveryState.pendingItems.count)
                Text("Completion covers the indicated period. Provider-certified full history has not been established.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(viewModel.recoveryState.pendingItems.values.sorted { $0.firstDetectedAt < $1.firstDetectedAt }, id: \.cycleID) { item in
                    VStack(alignment: .leading) {
                        Text(item.reason == "access" ? "Pending Health reading" : "Pending recovery validation")
                        if let range = item.range { Text(dateRange(start: range.start, end: range.end)).font(.footnote) }
                        if item.requiresManualReview(at: Date()) { Text("Manual review required").font(.footnote) }
                    }
                }
            }

            Section("Local progress") {
                let preview = viewModel.nextSyncPreview()
                metric("Sleep checkpoint", dateValue(viewModel.diagnostics.lastSleepCheckpoint))
                metric("Heart-rate checkpoint", dateValue(viewModel.diagnostics.lastHeartRateCheckpoint))
                metric("Next sleep review window", dateRange(start: preview.sleepWindowStart, end: preview.sleepWindowEnd))
                metric("Next heart-rate window", dateRange(start: preview.heartRateWindowStart, end: preview.heartRateWindowEnd))
                localizedMetric("Sleep mode", preview.isFirstSleepSync ? "First sync" : "Incremental")
                localizedMetric("Heart-rate mode", preview.isFirstHeartRateSync ? "First sync" : "Incremental")
                if let resolution = viewModel.diagnostics.heartRateResolution {
                    metric("Saved heart-rate resolution", "\(resolution) s")
                }
                metric("Last run", lastRunText)
                metric("Recorded sleeps", viewModel.diagnostics.recordedSleepCount)
                if !lastRunErrorsText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last run errors")
                        Text(lastRunErrorsText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            if !viewModel.events.isEmpty {
                Section("This session") {
                    ForEach(viewModel.events, id: \.self) { event in
                        Text(event)
                            .font(.footnote)
                    }
                }
            }

            if !viewModel.diagnostics.recentEvents.isEmpty {
                Section("Local log") {
                    ForEach(viewModel.diagnostics.recentEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(event.level.uppercased()) · \(event.category)")
                                .font(.caption)
                                .foregroundStyle(levelColor(event.level))
                            Text(event.message)
                                .font(.footnote)
                            Text(dateValue(event.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Diagnostics") {
                Button("Copy diagnostics") {
                    copyDiagnostics()
                }
                if let diagnosticCopyMessage {
                    Text(diagnosticCopyMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .whoopDashboardListStyle()
        .navigationTitle("Activity")
    }

    private var lastRunText: String {
        guard let startedAt = viewModel.diagnostics.lastRunStartedAt else {
            return "-"
        }
        let status = localizedStatus(viewModel.diagnostics.lastRunStatus)
        if let finishedAt = viewModel.diagnostics.lastRunFinishedAt {
            return "\(status), \(dateValue(startedAt)) → \(dateValue(finishedAt))"
        }
        return "\(status), \(dateValue(startedAt))"
    }

    private var lastRunErrorsText: String {
        SensitiveTextSanitizer.redact(viewModel.diagnostics.lastRunErrorsText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metric(_ title: LocalizedStringKey, _ value: Int) -> some View {
        metric(title, "\(value)")
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func localizedMetric(_ title: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func dateRange(start: Date?, end: Date?) -> String {
        guard let start, let end else {
            return "-"
        }
        return "\(dateValue(start)) → \(dateValue(end))"
    }

    private func dateValue(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func localizedStatus(_ status: String?) -> String {
        let usesSpanish = locale.language.languageCode?.identifier == "es"
        switch status {
        case "success":
            return usesSpanish ? "completada" : "completed"
        case "partial":
            return usesSpanish ? "con incidencias" : "with issues"
        case "failed":
            return usesSpanish ? "fallida" : "failed"
        case "running":
            return usesSpanish ? "en curso" : "in progress"
        default:
            return usesSpanish ? "desconocida" : "unknown"
        }
    }

    private func copyDiagnostics() {
        let report = viewModel.diagnosticsReport()
        #if os(iOS)
        UIPasteboard.general.string = report
        diagnosticCopyMessage = "Diagnostics copied."
        #else
        diagnosticCopyMessage = "Copying diagnostics is only available on iOS."
        #endif
    }

    private func levelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error":
            return .red
        case "warning":
            return .orange
        default:
            return .secondary
        }
    }
}
