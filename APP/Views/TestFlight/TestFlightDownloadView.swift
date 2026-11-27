import SwiftUI
import Foundation

struct TestFlightDownloadView: View {
    var showsCloseButton: Bool = true
    var showsNavigationStack: Bool = true

    @StateObject private var manager = TestFlightDownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var appleID = ""
    @State private var applePassword = ""
    @State private var code = ""
    @State private var showPassword = false
    @State private var focusTag: Int? = 0
    @State private var buildsApp: TestFlightApp?
    @State private var didAutoLogin = false
    @State private var metadata: [String: iTunesSearchResult] = [:]
    @State private var showAccounts = false
    @State private var showRegions = false
    @State private var showTFAppsWeb = false

    var body: some View {
        Group {
            if showsNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
        .overlay(alignment: .bottomTrailing) {
            tfAppsFloatingButton
        }
        .fullScreenCover(isPresented: $showTFAppsWeb) {
            TFAppsWebSheet()
                .environmentObject(themeManager)
        }
    }

    private var tfAppsFloatingButton: some View {
        Button {
            SoundEffects.play(.tap)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                showTFAppsWeb = true
            }
        } label: {
            Image("TestFlightIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
                .shadow(color: Color.black.opacity(0.28), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 18)
        .padding(.bottom, 88)
    }

    @ViewBuilder
    private var content: some View {
        if manager.imported {
            appList
        } else {
            loginPage
        }
    }

    private var loginPage: some View {
        ZStack(alignment: .topLeading) {
            themeManager.backgroundColor
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 8)

                    VStack(spacing: 16) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .cornerRadius(12)
                            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)

                        Text("TestFlight")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 32)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("testflight_email".localized)
                            .font(.headline)
                            .foregroundColor(.primary)
                        AppleLoginTextField(
                            text: $appleID,
                            placeholder: NSLocalizedString("enter_apple_id", comment: ""),
                            tag: 0,
                            keyboardType: .emailAddress,
                            returnKeyType: .next,
                            isSecure: false,
                            contentType: .username,
                            accent: themeManager.accentColor,
                            focusTag: $focusTag,
                            onCommit: { focusTag = 1 }
                        )
                        .frame(height: 52)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("testflight_password".localized)
                            .font(.headline)
                            .foregroundColor(.primary)
                        ZStack(alignment: .trailing) {
                            AppleLoginTextField(
                                text: $applePassword,
                                placeholder: NSLocalizedString("enter_password", comment: ""),
                                tag: 1,
                                keyboardType: .default,
                                returnKeyType: manager.requiresCode ? .next : .go,
                                isSecure: !showPassword,
                                contentType: .password,
                                accent: themeManager.accentColor,
                                focusTag: $focusTag,
                                onCommit: {
                                    if manager.requiresCode {
                                        focusTag = 2
                                    } else {
                                        focusTag = nil
                                        submitLogin()
                                    }
                                }
                            )
                            .frame(height: 52)
                            .padding(.trailing, 44)

                            Button(action: { showPassword.toggle() }) {
                                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 44, height: 52)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 2)
                            .accessibilityLabel(showPassword ? "hide_password".localized : "show_password".localized)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, manager.requiresCode ? 24 : 32)

                    if manager.requiresCode {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("two_factor_code".localized)
                                .font(.headline)
                                .foregroundColor(.primary)
                            AppleLoginTextField(
                                text: $code,
                                placeholder: NSLocalizedString("enter_6digit_code", comment: ""),
                                tag: 2,
                                keyboardType: .numberPad,
                                returnKeyType: .go,
                                isSecure: false,
                                contentType: .oneTimeCode,
                                accent: themeManager.accentColor,
                                focusTag: $focusTag,
                                maxLength: 6,
                                filterDigitsOnly: true,
                                onCommit: submitCode,
                                onTextChange: { value in
                                    if value.count == 6 { submitCode() }
                                }
                            )
                            .frame(height: 52)
                            Text("check_trusted_device".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 32)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Button(action: submitLogin) {
                        HStack(spacing: 12) {
                            if manager.isLoggingIn {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text(manager.isLoggingIn ? "testflight_logging_in".localized : "testflight_login".localized)
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(16)
                        .shadow(color: themeManager.accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .disabled(manager.isLoggingIn || appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || applePassword.isEmpty)

                    if manager.isLoggingIn {
                        Text("testflight_logging_in".localized)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, -20)
                            .padding(.bottom, 20)
                    } else if let error = manager.error,
                              !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 20)
                    }
                }
            }

            Button {
                Task {
                    let restored = await manager.cancelAddAccount()
                    if !restored {
                        TabRouter.shared.select(.downloads)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("back".localized)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .zIndex(1)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                        .foregroundColor(.primary)
                }
            }
        }
        .onChange(of: manager.requiresCode) { _, required in
            if required {
                code = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focusTag = 2 }
            }
        }
        .onAppear {
            prefillFromSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focusTag = 0 }
        }
        .alert("testflight_error".localized, isPresented: Binding(
            get: { manager.showsErrorAlert && manager.error != nil },
            set: { if !$0 { manager.error = nil; manager.showsErrorAlert = false } }
        )) {
            Button("ok".localized, role: .cancel) { manager.error = nil; manager.showsErrorAlert = false }
        } message: {
            Text(manager.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                 ? (manager.error ?? "")
                 : "testflight_login_failed".localized)
        }
    }

    private var appList: some View {
        ZStack {
            themeManager.backgroundColor
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    catalogHeader

                    if let bundle = manager.downloadingBundle {
                        downloadingCard(bundle)
                    }

                    if manager.apps.isEmpty {
                        emptyCatalog
                    } else {
                        ForEach(manager.apps) { app in
                            AppSearchResultCardView(
                                app: displayResult(for: app),
                                onTap: { buildsApp = app },
                                onGetAction: { buildsApp = app },
                                isDownloading: manager.downloadingBundle == app.bundle,
                                iconURLOverride: TFIcon.resolvedURL(storedURL: app.iconURL, appID: app.appID)?.absoluteString
                            )
                            .environmentObject(themeManager)
                            .overlay(alignment: .bottom) {
                                Divider()
                                    .padding(.leading, 92)
                                    .padding(.trailing, 16)
                            }
                            .task(id: app.id) {
                                async let icon: Void = manager.loadIcon(for: app)
                                async let meta: Void = loadMetadata(for: app)
                                _ = await (icon, meta)
                            }
                        }
                    }

                    catalogActions
                }
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .refreshable {
                await manager.refreshCatalog()
            }
        }
        .navigationTitle("TestFlight")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
        }
        .sheet(item: $buildsApp) { app in
            TestFlightBuildsSheet(app: app, manager: manager, onDownloadStarted: {
                buildsApp = nil
                dismiss()
                TabRouter.shared.select(.downloads)
            })
            .environmentObject(themeManager)
        }
        .sheet(isPresented: $showAccounts) {
            TestFlightAccountsSheet(manager: manager)
                .environmentObject(themeManager)
        }
        .sheet(isPresented: $showRegions) {
            TestFlightRegionSheet(manager: manager)
                .environmentObject(themeManager)
        }
        .task {
            await manager.revalidateCatalog()
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-autoDownload"),
               let first = manager.apps.first {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                manager.startDownloadFromUI(app: first)
            }
        }
    }

    private var catalogHeader: some View {
        HStack(spacing: 8) {
            Button {
                showAccounts = true
            } label: {
                HStack(spacing: 4) {
                    Text(manager.accountEmail ?? "TestFlight")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Button {
                showRegions = true
            } label: {
                HStack(spacing: 4) {
                    if manager.preferredRegion.isEmpty {
                        Image(systemName: "globe")
                            .font(.system(size: 10, weight: .semibold))
                        Text("testflight_region_auto".localized)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    } else {
                        Text(CountryHelpers.flag(country: manager.preferredRegion))
                            .font(.system(size: 11))
                        Text(RegionNames.localizedName(for: manager.preferredRegion))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(themeManager.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(themeManager.accentColor.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text(String(format: "testflight_catalog_count".localized, manager.apps.count))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func downloadingCard(_ bundle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(bundle)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(manager.downloadProgress * 100))%")
                    .font(.system(size: 11, weight: .semibold))
            }
            ProgressView(value: manager.downloadProgress)
            Text("testflight_downloading".localized)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var emptyCatalog: some View {
        VStack(spacing: 10) {
            Image(systemName: "paperplane")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("testflight_no_apps".localized)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var catalogActions: some View {
        Group {
            if let url = manager.lastOutput {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(url.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        SoundEffects.play(.tap)
                    })
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .padding(.horizontal, 16)
                .padding(.top, 20)
            }
        }
    }

    private func displayResult(for app: TestFlightApp) -> iTunesSearchResult {
        metadata[app.id] ?? fallbackResult(for: app)
    }

    private func fallbackResult(for app: TestFlightApp) -> iTunesSearchResult {
        let seedSource = app.appID ?? app.name
        let seed = seedSource.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        let trackID = Int(app.appID ?? "") ?? seed
        return iTunesSearchResult(
            trackId: trackID,
            trackName: app.name,
            artistName: nil,
            bundleId: app.bundle,
            version: app.version ?? "",
            formattedPrice: nil,
            price: nil,
            currency: nil,
            trackViewUrl: "",
            artworkUrl60: nil,
            artworkUrl100: app.iconURL?.absoluteString,
            artworkUrl512: nil,
            screenshotUrls: nil,
            ipadScreenshotUrls: nil,
            description: nil,
            releaseNotes: nil,
            sellerName: nil,
            genres: nil,
            primaryGenreName: nil,
            contentAdvisoryRating: nil,
            averageUserRating: nil,
            userRatingCount: nil,
            fileSizeBytes: nil,
            minimumOsVersion: nil,
            currentVersionReleaseDate: nil,
            releaseDate: nil,
            isGameCenterEnabled: nil,
            supportedDevices: nil,
            languageCodesISO2A: nil,
            advisories: nil,
            features: nil
        )
    }

    private func loadMetadata(for app: TestFlightApp) async {
        guard metadata[app.id] == nil else { return }
        let region = manager.metadataRegion
        let result: iTunesSearchResult?
        if !app.bundle.isEmpty {
            result = try? await iTunesClient.shared.lookup(bundleIdentifier: app.bundle, countryCode: region)
        } else if let trackID = Int(app.appID ?? "") {
            result = try? await iTunesClient.shared.lookup(trackId: trackID, countryCode: region)
        } else {
            result = nil
        }
        if let result {
            metadata[app.id] = result
        }
    }

    private func prefillFromSettings() {
        guard let account = AppStore.this.selectedAccount else { return }
        if appleID.isEmpty { appleID = account.email }
        if applePassword.isEmpty,
           let saved = StoreRequest.shared.storedPassword(for: account.email),
           !saved.isEmpty {
            applePassword = saved
        }
        if !applePassword.isEmpty, !didAutoLogin, !manager.isLoggingIn {
            didAutoLogin = true
            submitLogin()
        }
    }

    private func submitLogin() {
        guard !manager.isLoggingIn else { return }
        focusTag = nil
        Task {
            await manager.login(email: appleID, password: applePassword)
            if manager.imported { applePassword = "" }
        }
    }

    private func submitCode() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 6 else { return }
        focusTag = nil
        manager.submitCode(value)
    }
}

private struct TestFlightBuildsSheet: View {
    let app: TestFlightApp
    @ObservedObject var manager: TestFlightDownloadManager
    var onDownloadStarted: (() -> Void)? = nil
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                themeManager.backgroundColor
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        appHeader
                        historyHint
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .refreshable {
                    await manager.loadBuilds(for: app)
                }
            }
            .navigationTitle("testflight_history_builds".localized)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
            .task {
                await manager.loadBuilds(for: app)
            }
        }
    }

    private var appHeader: some View {
        HStack(spacing: 14) {
            AsyncImage(url: app.iconURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(themeManager.accentColor.opacity(0.12))
                        .overlay(
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(themeManager.accentColor)
                        )
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                Text(app.bundle.isEmpty ? (app.appID ?? "") : app.bundle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(manager.builds.count)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(themeManager.accentColor)
                Text("testflight_builds_unit".localized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var historyHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 1)

            Text("testflight_history_limit".localized)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.55))
        )
    }

    @ViewBuilder
    private var content: some View {
        if manager.isLoadingBuilds && manager.builds.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("testflight_history_loading".localized)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if manager.builds.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(manager.buildError ?? "testflight_no_builds".localized)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
        } else {
            VStack(spacing: 10) {
                ForEach(manager.builds) { build in
                    buildCard(build)
                }
            }
        }
    }

    private func buildCard(_ build: TFBuild) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(build.versionSummary)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)

                if build.isExpired {
                    Text("testflight_expired".localized)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                if manager.downloadingBuildID == build.id {
                    ProgressView()
                        .scaleEffect(0.85)
                        .frame(width: 32, height: 28)
                } else {
                    Button {
                        manager.startDownloadFromUI(app: app, buildID: build.id)
                        onDownloadStarted?()
                    } label: {
                        Label("testflight_download".localized, systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeManager.accentColor)
                    .controlSize(.small)
                    .disabled(build.isExpired || !build.platform.lowercased().contains("ios") || manager.downloadingBuildID == build.id)
                }
            }

            HStack(spacing: 6) {
                Label("Build \(build.id)", systemImage: "hammer.fill")
                if !build.platform.isEmpty {
                    Text("·")
                    Text(build.platform.uppercased())
                }
                if let date = build.releaseDate {
                    Text("·")
                    Text(date, style: .relative)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let notes = build.whatsNew, !notes.isEmpty {
                Divider()
                Text(notes)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
}

private struct TestFlightRegionSheet: View {
    @ObservedObject var manager: TestFlightDownloadManager
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var allRegions: [String] {
        Apple.storeFrontCodeMap.keys.sorted {
            CountryHelpers.countryName($0).localizedStandardCompare(CountryHelpers.countryName($1)) == .orderedAscending
        }
    }

    private var filteredRegions: [String] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return allRegions }
        return allRegions.filter { code in
            code.localizedCaseInsensitiveContains(keyword)
                || CountryHelpers.countryName(code).localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        manager.setPreferredRegion("")
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .foregroundStyle(themeManager.accentColor)
                            Text("testflight_region_auto".localized)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 6)
                            if manager.preferredRegion.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(themeManager.accentColor)
                            }
                        }
                    }
                } footer: {
                    Text("testflight_region_hint".localized)
                }

                Section {
                    ForEach(filteredRegions, id: \.self) { code in
                        Button {
                            manager.setPreferredRegion(code)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text(CountryHelpers.flag(country: code))
                                Text(CountryHelpers.countryName(code))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 6)
                                Text(code)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if code == manager.preferredRegion {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(themeManager.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("testflight_region".localized)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query)
            .navigationTitle("testflight_region".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("back".localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct TestFlightAccountsSheet: View {
    @ObservedObject var manager: TestFlightDownloadManager
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    if manager.savedAccountEmails.isEmpty {
                        Text("sign_in_apple_id".localized)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.savedAccountEmails, id: \.self) { email in
                            Button {
                                Task {
                                    await manager.switchAccount(email: email)
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.crop.circle")
                                    Text(email)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 6)
                                    if email == manager.accountEmail?.lowercased() {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(themeManager.accentColor)
                                    }
                                }
                            }
                            .swipeActions {
                                if email != manager.accountEmail?.lowercased() {
                                    Button(role: .destructive) {
                                        Task { await manager.deleteSavedAccount(email: email) }
                                    } label: {
                                        Text("delete".localized)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("switch_account".localized)
                }

                Section {
                    Button {
                        Task {
                            await manager.beginAddAccount()
                            dismiss()
                        }
                    } label: {
                        Label("add_account".localized, systemImage: "person.badge.plus")
                    }

                    Button(role: .destructive) {
                        Task {
                            await manager.logoutCurrentAccount()
                            dismiss()
                        }
                    } label: {
                        Text("sign_out".localized)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("apple_id".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("back".localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}
