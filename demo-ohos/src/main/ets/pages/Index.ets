import { fileIo as fs } from '@kit.CoreFileKit';
import { OfficePreviewView } from '@jzdy/office';

interface SampleItem {
  title: string;
  rawFileName: string;
}

@Entry
@Component
struct Index {
  private readonly samples: SampleItem[] = [
    { title: 'DOCX 文档', rawFileName: 'sample.docx' },
    { title: 'PPTX 幻灯片', rawFileName: 'sample.pptx' },
    { title: 'XLSX 表格', rawFileName: 'sample.xlsx' },
  ];

  @State selectedIndex: number = 0;
  @State sandboxFilePath: string = '';
  @State prepareError: string = '';

  aboutToAppear(): void {
    this.selectSample(0);
  }

  private async selectSample(index: number): Promise<void> {
    this.selectedIndex = index;
    this.prepareError = '';
    const sample = this.samples[index];
    try {
      const ctx = getContext(this);
      const rawBytes: Uint8Array = await ctx.resourceManager.getRawFileContent(sample.rawFileName);
      const targetPath = `${ctx.cacheDir}/${sample.rawFileName}`;

      const file = fs.openSync(
        targetPath,
        fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY
      );
      try {
        const buffer: ArrayBuffer = rawBytes.buffer.slice(
          rawBytes.byteOffset,
          rawBytes.byteOffset + rawBytes.byteLength
        );
        fs.writeSync(file.fd, buffer);
      } finally {
        fs.closeSync(file);
      }

      this.sandboxFilePath = targetPath;
    } catch (e) {
      this.prepareError = `无法读取 rawfile/${sample.rawFileName}: ${e}`;
    }
  }

  build() {
    Column() {
      Column({ space: 10 }) {
        Row() {
          Text('JZOffice HarmonyOS 预览')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#182431')
        }
        .width('100%')

        Row({ space: 8 }) {
          ForEach(this.samples, (item: SampleItem, index: number) => {
            Button(item.title)
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .backgroundColor(this.selectedIndex === index ? '#0a59f7' : '#f1f3f4')
              .fontColor(this.selectedIndex === index ? '#ffffff' : '#202124')
              .onClick(() => {
                if (this.selectedIndex !== index) {
                  this.selectSample(index);
                }
              })
          })
        }
        .width('100%')
      }
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#ffffff')
      .border({ width: { bottom: 0.5 }, color: '#dce1e5' })

      Stack() {
        if (this.prepareError) {
          Text(this.prepareError)
            .fontSize(14)
            .fontColor('#d93025')
            .padding(24)
        } else if (this.sandboxFilePath) {
          OfficePreviewView({ filePath: this.sandboxFilePath })
            .width('100%')
            .height('100%')
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
