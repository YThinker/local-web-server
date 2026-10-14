import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                rootSection
                actionSection
                helpSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("LocalWeb")
            .safeAreaInset(edge: .bottom) { toastBar }
            .onAppear {
                model.restoreExternalRootIfPossible()
                model.start()
                // 调试钩子：SIMCTL_CHILD_LOCALWEB_OPEN_BROWSER=1 启动时自动打开页面
                if ProcessInfo.processInfo.environment["LOCALWEB_OPEN_BROWSER"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        model.bumpReload()
                        model.showBrowser = true
                    }
                }
            }
            .sheet(isPresented: $model.showPicker) {
                FolderPicker { url in
                    model.showPicker = false
                    model.handlePickedFolder(url)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $model.showBrowser) {
                BrowserSheet(model: model)
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("服务器") {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.status.running ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(model.status.message)
                Spacer()
                if model.status.running {
                    Text(":\(String(model.status.port))")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let url = model.siteURL {
                HStack {
                    Text(url.absoluteString)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        model.copyAddress()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                Button(model.status.running ? "重启服务" : "启动服务") {
                    model.restart()
                }
                Spacer()
                Button("停止") { model.stop() }
                    .disabled(!model.status.running)
                    .foregroundStyle(model.status.running ? .red : .secondary)
            }

            Toggle(isOn: Binding(
                get: { model.allowLAN },
                set: { model.setAllowLAN($0) }
            )) {
                Text("允许同 Wi-Fi 设备访问")
            }

            if let lan = model.lanURLString {
                Text(lan)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var rootSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.usingExternalFolder ? "外部文件夹" : "App 文件夹")
                    .font(.subheadline.weight(.semibold))
                Text(model.rootDisplayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 2)

            Button {
                model.showPicker = true
            } label: {
                Label("选择文件夹…", systemImage: "folder")
            }

            Button {
                model.resetToAppFolder()
            } label: {
                Label("恢复为 App 文件夹", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.usingExternalFolder)
        } header: {
            Text("站点根目录")
        } footer: {
            Text("把 index.html 和 js 文件放进「文件」App → On My iPhone → LocalWeb，或直接从 iCloud 云盘 / 本机选一个文件夹。")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                model.bumpReload()
                model.showBrowser = true
            } label: {
                Label("打开页面", systemImage: "safari")
                    .font(.body.weight(.semibold))
            }
            .disabled(!model.status.running)

            Button {
                model.openInSafari()
            } label: {
                Label("在 Safari 中打开", systemImage: "arrow.up.right.square")
            }
            .disabled(!model.status.running)

            Button {
                model.revealInFiles()
            } label: {
                Label("打开「文件」App", systemImage: "folder.badge.gearshape")
            }
        }
    }

    private var helpSection: some View {
        Section("小提示") {
            Text("页面在 App 内部加载，切到后台也不会断。默认只监听 127.0.0.1，手机之外访问不到；需要别的设备访问时再打开上面的开关。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var toastBar: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - 浏览器全屏页

private struct BrowserSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = model.siteURL {
                    BrowserView(url: url).id(model.reloadToken)
                } else {
                    ContentUnavailableView("服务器未运行", systemImage: "bolt.horizontal.circle")
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(model.siteURL?.absoluteString ?? "LocalWeb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        model.bumpReload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button {
                        model.openInSafari()
                    } label: {
                        Image(systemName: "safari")
                    }
                }
            }
        }
    }
}

// MARK: - 文件夹选择器

struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
