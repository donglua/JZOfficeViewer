/**
 * JZOffice 鸿蒙端浮动选区操作气泡
 *
 * 提供「复制」与「全选」两个操作，样式与 OfficeSearchBar 保持一致的圆角白底卡片阴影风格。
 * 气泡根据选区包围框自动完成上方/下方翻转与水平边界夹紧，可直接复用于
 * DocxFlowView 与 PptxSlidesView。
 */
import { pasteboard } from '@kit.BasicServicesKit';

/** 气泡与选区包围框之间的间距（vp） */
const BUBBLE_GAP: number = 10;
/** 气泡距视口边缘的最小安全内边距（vp） */
const BUBBLE_SAFE_INSET: number = 8;

/**
 * 将纯文本写入系统剪贴板。
 * 空串直接返回 false；写入异常（如剪贴板服务不可用）同样返回 false，
 * 由调用方决定是否提示用户。
 */
export function copyTextToPasteboard(text: string): boolean {
  if (!text || text.length === 0) {
    return false;
  }
  try {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setDataSync(data);
    return true;
  } catch (_e) {
    return false;
  }
}

@Component
export struct SelectionMenuBubble {
  /** 选区包围框中心 X（视口坐标，vp） */
  @Prop anchorX: number = 0;
  /** 选区包围框顶部 Y（视口坐标，vp） */
  @Prop anchorY: number = 0;
  /** 选区包围框底部 Y（视口坐标，vp） */
  @Prop anchorBottomY: number = 0;
  /** 视口宽度（vp） */
  @Prop viewportWidth: number = 0;
  /** 视口高度（vp） */
  @Prop viewportHeight: number = 0;
  /** 是否展示「全选」（已全选时仅保留「复制」） */
  @Prop showSelectAll: boolean = true;
  /** 点击「复制」 */
  onCopy?: () => void;
  /** 点击「全选」 */
  onSelectAll?: () => void;

  @State private bubbleWidth: number = 0;
  @State private bubbleHeight: number = 0;

  /**
   * 计算气泡左上角位置：
   * 优先置于选区上方 BUBBLE_GAP 处；上方空间不足则翻转到选区下方；
   * 水平方向夹紧到视口安全区内。
   */
  private resolveLeft(): number {
    const w = this.bubbleWidth > 0 ? this.bubbleWidth : 140;
    const viewW = this.viewportWidth > 0 ? this.viewportWidth : w + BUBBLE_SAFE_INSET * 2;
    const raw = this.anchorX - w / 2;
    const maxLeft = Math.max(BUBBLE_SAFE_INSET, viewW - w - BUBBLE_SAFE_INSET);
    return Math.max(BUBBLE_SAFE_INSET, Math.min(maxLeft, raw));
  }

  /** 计算气泡顶部位置：上翻优先，空间不足则落在选区下方 */
  private resolveTop(): number {
    const h = this.bubbleHeight > 0 ? this.bubbleHeight : 40;
    const above = this.anchorY - h - BUBBLE_GAP;
    if (above >= BUBBLE_SAFE_INSET) {
      return above;
    }
    const below = this.anchorBottomY + BUBBLE_GAP;
    const viewH = this.viewportHeight > 0 ? this.viewportHeight : below + h + BUBBLE_SAFE_INSET;
    const maxTop = Math.max(BUBBLE_SAFE_INSET, viewH - h - BUBBLE_SAFE_INSET);
    if (below <= maxTop) {
      return below;
    }
    // 选区铺满全屏：贴视口顶端安全区内边距，保证气泡始终可见
    return BUBBLE_SAFE_INSET;
  }

  build() {
    Row({ space: 0 }) {
      // 复制按钮
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Text('复制')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1a73e8')
      }
      .height(36)
      .padding({ left: 18, right: 18 })
      .backgroundColor('#00000000')
      .borderRadius(18)
      .onClick(() => {
        if (this.onCopy) {
          this.onCopy();
        }
      })

      // 已全选时隐藏「全选」，避免无效操作
      if (this.showSelectAll) {
        Divider()
          .vertical(true)
          .height(18)
          .color('#dadce0')
          .strokeWidth(0.5)

        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Text('全选')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1a73e8')
        }
        .height(36)
        .padding({ left: 18, right: 18 })
        .backgroundColor('#00000000')
        .borderRadius(18)
        .onClick(() => {
          if (this.onSelectAll) {
            this.onSelectAll();
          }
        })
      }
    }
    .height(40)
    .backgroundColor('#ffffff')
    .borderRadius(20)
    .border({ width: 0.8, color: '#dadce0' })
    .shadow({
      radius: 12,
      color: 'rgba(0, 0, 0, 0.12)',
      offsetX: 0,
      offsetY: 3
    })
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w = Number(newArea.width);
      const h = Number(newArea.height);
      if (w > 0) {
        this.bubbleWidth = w;
      }
      if (h > 0) {
        this.bubbleHeight = h;
      }
    })
    .position({ x: this.resolveLeft(), y: this.resolveTop() })
  }
}
