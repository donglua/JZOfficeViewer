import SwiftUI
import AppKit
import JZOffice

@main
struct JZOfficeMacDemoApp: App {
    var body: some Scene {
        WindowGroup("JZOffice macOS 预览演示") {
            DemoContentView()
                .frame(minWidth: 860, minHeight: 620)
        }
    }
}

final class DemoViewModel: ObservableObject {
    @Published var currentURL: URL?
    @Published var statusText: String = "请选择或切换 DOCX / PPTX / XLSX 样例"
}

struct DemoContentView: View {
    @StateObject private var controller = OfficePreviewController()
    @StateObject private var viewModel = DemoViewModel()

    private let sampleNames = [
        ("DOCX 文档", "sample.docx"),
        ("PPTX 幻灯片", "sample.pptx"),
        ("XLSX 表格", "sample.xlsx")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("JZOffice macOS 原生预览")
                        .font(.system(size: 16, weight: .bold))
                    Text(viewModel.statusText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()

                ForEach(sampleNames, id: \.1) { title, fileName in
                    Button(title) {
                        selectSample(named: fileName)
                    }
                }

                Button("打开文件...") {
                    pickLocalFile()
                }

                Divider().frame(height: 20)

                Button("-") {
                    controller.setZoom(controller.zoom - 0.25)
                }
                Button("100%") {
                    controller.resetZoom()
                }
                Button("+") {
                    controller.setZoom(controller.zoom + 0.25)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if let url = viewModel.currentURL {
                OfficePreviewView(
                    fileURL: url,
                    controller: controller,
                    onLoaded: { info in
                        viewModel.statusText = "\(info.format.rawValue)  |  \(info.pageCount) 页  |  \(info.warnings.count) 条提示"
                    },
                    onError: { err in
                        viewModel.statusText = "加载失败: \(err.localizedDescription)"
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                Text("正在定位内置样例...")
                    .foregroundColor(.secondary)
                Spacer()
            }

            OfficeSheetTabs(controller: controller)
        }
        .onAppear {
            selectSample(named: "sample.docx")
        }
    }

    private func selectSample(named name: String) {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../demo/src/main/assets/samples/\(name)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("demo/src/main/assets/samples/\(name)")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            viewModel.currentURL = candidate.standardizedFileURL
            return
        }
    }

    private func pickLocalFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.currentURL = url
        }
    }
}
