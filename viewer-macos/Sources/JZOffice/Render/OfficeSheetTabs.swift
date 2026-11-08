import SwiftUI

/// JZOffice macOS 端标准化多工作表切换标签栏组件（XLSX Sheet Tabs）
/// 对齐 Android `OfficeSheetTabs` 与鸿蒙 `OfficeSheetTabs`：
/// 仅需传入 `controller` 即可自动订阅工作表列表与激活页码，非 XLSX 文档自动隐藏
public struct OfficeSheetTabs: View {
    @ObservedObject private var controller: OfficePreviewController
    private let onSelectSheet: ((Int) -> Void)?

    public init(
        controller: OfficePreviewController,
        onSelectSheet: ((Int) -> Void)? = nil
    ) {
        self.controller = controller
        self.onSelectSheet = onSelectSheet
    }

    public var body: some View {
        if !controller.sheetNames.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(controller.sheetNames.enumerated()), id: \.offset) { index, name in
                        let sheetNumber = index + 1
                        let isSelected = controller.currentPage == sheetNumber
                        Button(action: {
                            controller.selectSheet(sheetNumber)
                            onSelectSheet?(sheetNumber)
                        }) {
                            Text(name)
                                .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                                .foregroundColor(
                                    isSelected
                                        ? Color(red: 0x17 / 255.0, green: 0x6b / 255.0, blue: 0x43 / 255.0)
                                        : Color(red: 0x4a / 255.0, green: 0x51 / 255.0, blue: 0x59 / 255.0)
                                )
                                .padding(.horizontal, 16)
                                .frame(height: 40)
                                .background(
                                    isSelected
                                        ? Color(red: 0xe0 / 255.0, green: 0xef / 255.0, blue: 0xe6 / 255.0)
                                        : Color(red: 0xf4 / 255.0, green: 0xf5 / 255.0, blue: 0xf7 / 255.0)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0xf4 / 255.0, green: 0xf5 / 255.0, blue: 0xf7 / 255.0))
        }
    }
}
