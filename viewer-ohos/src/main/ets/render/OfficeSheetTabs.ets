import { OfficePreviewController } from './OfficePreviewView';

/**
 * JZOffice 鸿蒙端多工作表切换标签栏组件（XLSX Sheet Tabs）
 */
@Component
export struct OfficeSheetTabs {
  @Prop sheetNames: string[] = [];
  @Prop currentSheet: number = 1;
  controller?: OfficePreviewController;
  onSelectSheet?: (sheetNumber: number) => void;

  build() {
    if (this.sheetNames.length > 0) {
      List({ space: 0 }) {
        ForEach(this.sheetNames, (name: string, index: number) => {
          ListItem() {
            Text(name)
              .fontSize(14)
              .fontWeight(this.currentSheet === index + 1 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.currentSheet === index + 1 ? '#176b43' : '#4a5159')
              .backgroundColor(this.currentSheet === index + 1 ? '#e0efe6' : '#f4f5f7')
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
      .backgroundColor('#f4f5f7')
      .scrollBar(BarState.Off)
    }
  }
}
