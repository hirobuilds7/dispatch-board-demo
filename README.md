# 配車ボード 動作検証デモ（dispatch-board-demo）

kintone + JavaScript による配車管理アプリの提案にあたり、
**行をまたぐドラッグ＆ドロップ / 未配車からの投入 / 重複チェック / 色分け**が
実際に動くことを示すための1枚。

- 使用ライブラリ：[vis-timeline](https://github.com/visjs/vis-timeline)（Apache-2.0 OR MIT・商用利用可・ライセンス費用なし）
- 有償ライブラリ・有料プラグインは不使用
- データは保存されない（再読み込みで初期状態に戻る）
- `noindex` 指定

## 実装上のポイント

- `itemsAlwaysDraggable: { item: true, range: true }`
  既定値 `false` だと「1回クリックして選択してから」でないとドラッグできず、初回操作が空振りする。
  配車の現場では1件動かすのに2アクション要ることになるため必ず有効化する。
- `groupHeightMode: "fixed"`  行の高さを固定してドラッグ中に狙いがズレるのを防ぐ
- 未配車一覧からボードへの投入は vis-timeline の標準機能では賄えないため、HTML5 Drag and Drop で自前配線
