/**
 * JZOffice 鸿蒙端浮动搜索交互栏组件
 * 提供关键词输入、实时匹配计数、上下跳转与退出交互
 */
@Component
export struct OfficeSearchBar {
  @Prop query: string = '';
  @Prop currentIndex: number = -1;
  @Prop totalMatches: number = 0;
  @Prop isSearching: boolean = false;
  onQueryChange?: (query: string) => void;
  onSearchSubmit?: (query: string) => void;
  onNext?: () => void;
  onPrevious?: () => void;
  onClose?: () => void;

  private getCountText(): string {
    if (this.isSearching) {
      return '搜索中...';
    }
    if (!this.query || this.query.trim().length === 0) {
      return '';
    }
    if (this.totalMatches === 0) {
      return '无结果';
    }
    const cur = this.currentIndex >= 0 ? this.currentIndex + 1 : 0;
    return `${cur} / ${this.totalMatches}`;
  }

  build() {
    Row({ space: 8 }) {
      // 搜索图标
      Text('🔍')
        .fontSize(14)
        .fontColor('#5f6368')
        .margin({ left: 12 })

      // 关键词输入框
      TextInput({
        text: this.query,
        placeholder: '在文档中查找...'
      })
        .layoutWeight(1)
        .height(36)
        .fontSize(14)
        .fontColor('#202124')
        .placeholderColor('#9aa0a6')
        .backgroundColor('#00000000')
        .caretColor('#0a59f7')
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          if (this.onQueryChange) {
            this.onQueryChange(value);
          }
        })
        .onSubmit(() => {
          if (this.totalMatches > 0 && this.onNext) {
            this.onNext();
          } else if (this.onSearchSubmit) {
            this.onSearchSubmit(this.query);
          }
        })

      // 命中计数标签
      if (this.getCountText().length > 0) {
        Text(this.getCountText())
          .fontSize(12)
          .fontColor(this.totalMatches === 0 ? '#d93025' : '#5f6368')
          .margin({ left: 4, right: 4 })
      }

      // 上一个按钮
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Text('▲')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.totalMatches > 0 ? '#3c4043' : '#dadce0')
      }
      .width(28)
      .height(28)
      .backgroundColor('#00000000')
      .enabled(this.totalMatches > 0)
      .opacity(this.totalMatches > 0 ? 1.0 : 0.4)
      .onClick(() => {
        if (this.onPrevious) {
          this.onPrevious();
        }
      })

      // 下一个按钮
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Text('▼')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.totalMatches > 0 ? '#3c4043' : '#dadce0')
      }
      .width(28)
      .height(28)
      .backgroundColor('#00000000')
      .enabled(this.totalMatches > 0)
      .opacity(this.totalMatches > 0 ? 1.0 : 0.4)
      .onClick(() => {
        if (this.onNext) {
          this.onNext();
        }
      })

      // 分割线
      Divider()
        .vertical(true)
        .height(16)
        .color('#dadce0')
        .strokeWidth(0.5)

      // 关闭按钮
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Text('✕')
          .fontSize(13)
          .fontColor('#5f6368')
      }
      .width(28)
      .height(28)
      .backgroundColor('#00000000')
      .margin({ right: 6 })
      .onClick(() => {
        if (this.onClose) {
          this.onClose();
        }
      })
    }
    .height(44)
    .backgroundColor('#ffffff')
    .borderRadius(22)
    .border({ width: 0.8, color: '#dadce0' })
    .shadow({
      radius: 12,
      color: 'rgba(0, 0, 0, 0.12)',
      offsetX: 0,
      offsetY: 3
    })
    .padding({ left: 4, right: 4 })
  }
}
