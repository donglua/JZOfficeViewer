import { OfficePreviewController } from './OfficePreviewView';

/**
 * JZOffice 鸿蒙端多工作表切换标签栏组件（XLSX Sheet Tabs）
 *
 * 支持两种使用模式：
 * 1. 自动联动模式（推荐，对齐 Android attachTo）：仅传入 `controller`，组件内部自动订阅工作表列表与当前激活页码，非 XLSX 文档自动隐藏。
 * 2. 受控属性模式：显式传入 `sheetNames` 与 `currentSheet`。
 */
@Component
export struct OfficeSheetTabs {
  @Prop sheetNames: string[] = [];
  @Prop currentSheet: number = 0;
  controller?: OfficePreviewController;
  onSelectSheet?: (sheetNumber: number) => void;

  @Prop selectedTextColor: ResourceColor = '#176b43';
  @Prop normalTextColor: ResourceColor = '#4a5159';
  @Prop selectedTabBgColor: ResourceColor = '#e0efe6';
  @Prop normalTabBgColor: ResourceColor = '#f4f5f7';

  @State private boundSheetNames: string[] = [];
  @State private boundCurrentSheet: number = 1;
  private pageChangeListener: ((pageNumber: number, pageCount: number) => void) | null = null;

  aboutToAppear(): void {
    if (this.controller) {
      this.pageChangeListener = (pageNumber: number, _pageCount: number): void => {
        this.syncFromController(pageNumber);
      };
      this.controller.addOnPageChangeListener(this.pageChangeListener);
    }
  }

  aboutToDisappear(): void {
    if (this.controller && this.pageChangeListener) {
      this.controller.removeOnPageChangeListener(this.pageChangeListener);
      this.pageChangeListener = null;
    }
  }

  private syncFromController(pageNumber: number): void {
    if (!this.controller) return;
    const names = this.controller.getSheetNames();
    this.boundSheetNames = names ? names.slice() : [];
    this.boundCurrentSheet = pageNumber > 0 ? pageNumber : 1;
  }

  private effectiveSheetNames(): string[] {
    return this.sheetNames && this.sheetNames.length > 0 ? this.sheetNames : this.boundSheetNames;
  }

  private effectiveCurrentSheet(): number {
    return this.currentSheet > 0 ? this.currentSheet : this.boundCurrentSheet;
  }

  build() {
    if (this.effectiveSheetNames().length > 0) {
      List({ space: 0 }) {
        ForEach(this.effectiveSheetNames(), (name: string, index: number) => {
          ListItem() {
            Text(name)
              .fontSize(14)
              .fontWeight(this.effectiveCurrentSheet() === index + 1 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.effectiveCurrentSheet() === index + 1 ? this.selectedTextColor : this.normalTextColor)
              .backgroundColor(this.effectiveCurrentSheet() === index + 1 ? this.selectedTabBgColor : this.normalTabBgColor)
              .padding({ left: 16, right: 16 })
              .height(48)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => {
                const target = index + 1;
                if (this.controller) {
                  this.controller.selectSheet(target);
                }
                if (this.onSelectSheet) {
                  this.onSelectSheet(target);
                }
              })
          }
        }, (name: string, index: number) => `${name}_${index}`)
      }
      .listDirection(Axis.Horizontal)
      .height(48)
      .width('100%')
      .backgroundColor(this.normalTabBgColor)
      .scrollBar(BarState.Off)
    }
  }
}
