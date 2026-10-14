import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { OfficePreviewView } from '@donglua/jzoffice';

interface SampleDoc {
  title: string;
  fileName: string;
  format: string;
  icon: string;
}

@Entry
@Component
struct Index {
  @State selectedIndex: number = 0;
  @State currentFilePath: string = '';
  @State isExtracting: boolean = false;
  @State errorMessage: string = '';

  private samples: SampleDoc[] = [
    { title: 'Word 文档', fileName: 'sample.docx', format: 'DOCX', icon: '📝' },
    { title: '幻灯片演示', fileName: 'sample.pptx', format: 'PPTX', icon: '📊' },
    { title: '电子表格', fileName: 'sample.xlsx', format: 'XLSX', icon: '📈' }
  ];

  aboutToAppear(): void {
    this.switchSample(0);
  }

  private async switchSample(index: number): Promise<void> {
    this.selectedIndex = index;
    const sample = this.samples[index];
    this.isExtracting = true;
    this.errorMessage = '';

    try {
      const context = getContext(this) as common.UIAbilityContext;
      const targetPath = `${context.cacheDir}/${sample.fileName}`;

      // 从 rawfile 中提取内置 sample 写入沙箱 cache 目录
      const rawContent: Uint8Array = await context.resourceManager.getRawFileContent(sample.fileName);
      const file = fileIo.openSync(
        targetPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC
      );
      fileIo.writeSync(file.fd, rawContent.buffer);
      fileIo.closeSync(file.fd);

      this.currentFilePath = targetPath;
    } catch (e) {
      this.errorMessage = `提取内置演示文档失败: ${e}`;
    } finally {
      this.isExtracting = false;
    }
  }

  build() {
    Column() {
      // 1. 顶部文档类型切换标签栏
      Row() {
        ForEach(this.samples, (item: SampleDoc, index: number) => {
          Button() {
            Row({ space: 4 }) {
              Text(item.icon).fontSize(14)
              Text(item.title)
                .fontSize(14)
                .fontColor(this.selectedIndex === index ? '#ffffff' : '#3c4043')
                .fontWeight(this.selectedIndex === index ? FontWeight.Medium : FontWeight.Normal)
            }
          }
          .layoutWeight(1)
          .height(38)
          .backgroundColor(this.selectedIndex === index ? '#0a59f7' : '#f1f3f4')
          .borderRadius(8)
          .margin({ left: index > 0 ? 6 : 0 })
          .onClick(() => {
            if (this.selectedIndex !== index) {
              this.switchSample(index);
            }
          })
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#ffffff')
      .shadow({ radius: 4, color: '#0f000000', offsetY: 1 })

      // 2. 主体文档预览区域
      Stack() {
        if (this.isExtracting) {
          Column({ space: 8 }) {
            LoadingProgress().width(36).height(36).color('#0a59f7')
            Text('正在准备演示文档...').fontSize(13).fontColor('#5f6368')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorMessage) {
          Column({ space: 8 }) {
            Text(this.errorMessage).fontSize(14).fontColor('#d93025')
            Button('重试').fontSize(13).height(32).onClick(() => this.switchSample(this.selectedIndex))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.currentFilePath) {
          OfficePreviewView({ filePath: this.currentFilePath })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#f8f9fa')
  }
}
