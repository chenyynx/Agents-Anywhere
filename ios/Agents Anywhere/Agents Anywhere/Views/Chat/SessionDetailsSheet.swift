import SwiftUI
import UniformTypeIdentifiers

struct SessionDetailsSheet: View {
    let chat: SessionChatModel
    let service: V2SessionDetailService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var exportRequest: String?
    @State private var document: TimelineJSONDocument?
    @State private var showsExporter = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            SettingsScreen(title: String(localized: "会话详情"), close: { dismiss() }) {
                if let meta = chat.session.metadata {
                    SettingsSection(String(localized: "会话")) {
                        infoRow(String(localized: "标题"), meta.title ?? String(localized: "未命名会话"))
                        SettingsRowDivider(leading: SettingsStyle.rowPadding)
                        infoRow(String(localized: "设备"), meta.connectorId)
                        SettingsRowDivider(leading: SettingsStyle.rowPadding)
                        infoRow(String(localized: "Agent"), meta.runtimeName ?? meta.runtime)
                        SettingsRowDivider(leading: SettingsStyle.rowPadding)
                        infoRow(String(localized: "Agent 类型"), meta.runtimeTypeDisplayName ?? meta.runtimeType ?? meta.runtime)
                        SettingsRowDivider(leading: SettingsStyle.rowPadding)
                        infoRow(String(localized: "状态"), (chat.session.runtime.state?.status ?? meta.status).displayName)
                        SettingsRowDivider(leading: SettingsStyle.rowPadding)
                        infoRow(String(localized: "dashboard.session.workspace"), meta.cwd ?? String(localized: "无"))
                        SettingsRowDivider(leading: SettingsStyle.rowPadding)
                        infoRow(String(localized: "接管"), meta.takeover ? String(localized: "已开启") : String(localized: "只读"))
                    }
                    SettingsSection(String(localized: "标识与时间线")) {
                        infoRow(String(localized: "Session ID"), meta.id)
                        SettingsRowDivider(leading: SettingsStyle.rowPadding)
                        infoRow(String(localized: "外部 Session ID"), meta.externalSessionId ?? String(localized: "无"))
                        SettingsRowDivider(leading: SettingsStyle.rowPadding)
                        infoRow(String(localized: "已加载条目"), String(chat.session.timeline.count))
                        SettingsRowDivider(leading: SettingsStyle.rowPadding)
                        infoRow(String(localized: "待回应交互"), String(chat.session.notices.notices.filter { $0.isVisible && $0.notice.type == "interaction" }.count))
                    }
                    SettingsSection {
                        SettingsDisclosureRow(icon: "arrow.up.right.square",
                                              title: String(localized: "导出已加载时间线 JSON"),
                                              showsChevron: false,
                                              isEnabled: exportRequest == nil) {
                            exportRequest = "memory"
                        }
                        SettingsRowDivider()
                        SettingsDisclosureRow(icon: "arrow.down.document",
                                              title: String(localized: "导出服务器时间线 JSON"),
                                              showsChevron: false,
                                              isEnabled: exportRequest == nil && chat.session.network.availability != .offline) {
                            exportRequest = "remote"
                        }
                        if exportRequest != nil {
                            SettingsRowDivider()
                            SettingsRowContainer(verticalPadding: 12) {
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text(String(localized: "正在准备导出…"))
                                        .font(SettingsStyle.text(16))
                                        .foregroundStyle(SettingsStyle.secondary(colorScheme))
                                    Spacer(minLength: 8)
                                    Button(String(localized: "取消")) { exportRequest = nil }
                                        .font(SettingsStyle.text(16))
                                }
                            }
                        }
                    }
                }
                if let error {
                    SettingsSection {
                        SettingsRowContainer {
                            Text(error)
                                .font(SettingsStyle.text(15))
                                .foregroundStyle(SettingsStyle.secondary(colorScheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .appSheetPresentation(.expanded)
        .task(id: exportRequest) {
            guard let source = exportRequest, let meta = chat.session.metadata else { return }
            error = nil
            do {
                let export: SessionTimelineExport
                if source == "remote" { export = try await service.exportTimeline(sessionId: meta.id) }
                else {
                    let items = chat.session.timeline.map(\.value)
                    let deferredCount = items.filter(\.isDeferred).count
                    export = SessionTimelineExport(source: "memory", session: meta, items: items, notices: chat.session.runtime.notices,
                        nextSeq: items.map(\.updatedSeq).max() ?? 0, hasMore: chat.session.hasOlderItems || chat.session.hasNewerItems,
                        incomplete: deferredCount > 0 ? true : nil,
                        deferredItems: deferredCount > 0 ? deferredCount : nil)
                }
                try Task.checkCancellation()
                guard chat.session.isValid else { return }
                document = TimelineJSONDocument(data: try export.encoded(), name: "timeline-\(source)-\(meta.id.prefix(8))")
                showsExporter = true
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { exportRequest = nil }
        }
        .fileExporter(isPresented: $showsExporter, document: document, contentType: .json, defaultFilename: document?.name ?? "timeline") { result in
            if case let .failure(failure) = result { error = failure.localizedDescription }
            document = nil
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        SettingsRowContainer {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(SettingsStyle.text(16))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                Spacer(minLength: 8)
                Text(value)
                    .font(SettingsStyle.text(16))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct TimelineJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data
    let name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = "timeline"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
