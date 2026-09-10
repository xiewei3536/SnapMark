# SnapMark

精緻的 macOS 截圖／錄影／標註工具。原生 Swift + SwiftUI，Universal Binary 同時支援 **Apple Silicon（M 系列）與 Intel**，介面支援**繁體中文、简体中文、English** 即時切換（免重啟）。

![platform](https://img.shields.io/badge/macOS-13.0%2B-blue) ![arch](https://img.shields.io/badge/arch-arm64%20%2B%20x86__64-purple) ![version](https://img.shields.io/badge/version-1.2.0-green)

## 功能

| 分類 | 內容 |
|---|---|
| **截圖** | 區域截圖（凍結畫面選取）、全螢幕、視窗截圖——**點一下視窗就拍**，邊緣乾淨無陰影 |
| **選取體驗** | 像素放大鏡＋取色器（座標／HEX）、尺寸即時顯示、8 向調整手把、方向鍵微調（⇧×10）、三分構圖線、**⌘C 只複製不開編輯器** |
| **錄影** | 全螢幕／區域錄影（H.264 / HEVC，MP4 / MOV）、系統聲音、麥克風（macOS 15+）、可調影格率、可取消的錄前倒數、紅框指示、浮動控制列、**再按一次快捷鍵即停止**；錄影開始時自動把焦點還給原本的 App |
| **GIF** | 錄影完成後一鍵轉存 GIF |
| **編輯器** | 畫筆、螢光筆、直線、箭頭、矩形、橢圓、馬賽克／模糊、步驟標號 ①②③（刪除自動重新編號）、裁切、無限復原重做、縮放（⌘滾輪／捏合）、精準命中選取、原生標題列＋未儲存圓點、關閉前詢問是否儲存；**工具列的顏色／線寬／字級會直接套用在選取中的物件** |
| **文字排版** | 原生文字編輯（IME 友善）、⇧↩ 多行、拖曳 ⠿ 移動、拖曳角落縮放字級、字體選單（常用中英字體＋全部字體、各自預覽）、粗體／斜體（無斜體字型自動合成）／底線／刪除線、左中右對齊、對比色底板、外描邊、陰影；⌘B／⌘I／⌘U、⌥⌘↑↓ 調字級 |
| **OCR 取字** | Vision 文字辨識（繁中／簡中／英文），一鍵複製；快捷鍵「框選→辨識→進剪貼簿」 |
| **釘選貼圖** | 把截圖釘在所有視窗最上層：拖曳移動、滾輪縮放、懸浮工具列、右鍵選單調不透明度、雙擊關閉 |
| **流程自動化** | 截圖後自動複製到剪貼簿 ✓、自動存檔 ✓（PNG 含 Retina DPI）、可選「開編輯器／僅提示／直接釘選」、快門音效、檔名模板 `{date} {time} {seq}` |
| **人性化** | 首次啟動的「快速上手」視窗（權限狀態即時偵測＋一鍵重新啟動）、啟動提示 Toast、選單列常駐、編輯時才顯示 Dock 圖示、最近擷取縮圖選單、完整的中文主選單、快捷鍵衝突提示 |

## 預設快捷鍵（皆可在偏好設定自訂）

| 快捷鍵 | 功能 |
|---|---|
| ⇧⌘1 | 區域截圖 |
| ⇧⌘2 | 全螢幕截圖 |
| ⇧⌘7 | 視窗截圖 |
| ⇧⌘8 | 區域錄影（再按一次＝停止／取消倒數） |
| ⇧⌘9 | 全螢幕錄影（再按一次＝停止） |
| ⌥⇧⌘O | 框選 OCR 取字 |
| ⌥⇧⌘P | 框選釘選到螢幕 |
| ⌥⇧⌘R | 重複上次區域截圖 |

選取時：**點擊視窗**立即擷取整個視窗、**Enter** 確認、**⌘C** 只複製、**Esc** 取消、**方向鍵** 微調。

編輯器內（依實體鍵位，中文輸入法下也有效）：**V/P/H/L/A/R/E/T/M/B/C** 切換工具、**⌘Z / ⇧⌘Z** 復原重做、**⌘C** 複製、**⌘S** 儲存、**⇧⌘S** 另存、**⌘+ / ⌘− / ⌘0 / ⌘9** 縮放、**⌫** 刪除、**⇧拖曳** 正方形／45°、**雙擊文字** 編輯、**Enter** 套用裁切。文字：**⇧↩** 換行、**⌘B / ⌘I / ⌘U** 粗斜底線、**⌥⌘↑ / ⌥⌘↓** 字級。

## 安裝與權限

1. 把 `dist/SnapMark.app` 拖到「應用程式」（或直接執行）。
2. 首次啟動會開啟「快速上手」視窗並要求「**螢幕錄製**」權限：**系統設定 → 隱私權與安全性 → 螢幕錄製** → 開啟 SnapMark → 按視窗中的「重新啟動 SnapMark」。
3. 錄麥克風時會另外請求「麥克風」權限。

> **權限不會再因重建而失效。** 專案內建 `Packaging/make_dev_cert.sh`：執行一次會在獨立的鑰匙圈 `snapmark-dev.keychain-db` 建立自簽的程式碼簽署身分「SnapMark Dev」（唯一需要互動的一步是輸入登入密碼以信任憑證），之後 `build.sh` 會自動用它簽署。macOS 以簽章身分識別 App，同一身分的每次重建都算同一個 App，「螢幕錄製」授權一次即永久有效。
> 沒有這個身分時 `build.sh` 退回 ad-hoc 簽名，每次重建都得重新授權。
>
> **「系統設定裡明明開著，App 卻說沒授權」的真正原因**：macOS 的隱私記錄以 bundle ID 為鍵，並記住第一次要求時那個版本的簽章。換了簽章後，設定裡的開關仍綁著舊版本，開關開了也對不上。解法是清掉這筆記錄讓 macOS 重新登記：在歡迎視窗或選單列按「**重設權限記錄**」（等同 `tccutil reset ScreenCapture com.snapmark.app`），macOS 會再詢問一次，開啟後重新啟動即可。

> **📌 選單列圖示不見了？** 若有裝「選單列管家 / Bartender / Ice」等工具，新出現的圖示預設會被收進隱藏區，點選單列的「>」展開即可（建議設為永遠顯示）。啟動時的 Toast 會提醒你 App 已就緒。

## 從原始碼建置

```bash
./build.sh            # Universal Binary（arm64 + x86_64，只需 Xcode Command Line Tools）
./build.sh --native   # 只編譯目前架構（較快，開發用）
swift build && .build/debug/SnapMark           # 開發模式
.build/debug/SnapMark --edit ~/Desktop/a.png    # 直接用編輯器開圖
```

產物：`dist/SnapMark.app`（約 5 MB，無任何第三方相依）。

## 技術架構

- **擷取**：ScreenCaptureKit（`SCScreenshotManager` / `SCStream`），macOS 13 相容備援；視窗截圖用 `desktopIndependentWindow` 取得乾淨邊緣
- **錄影**：`SCStream` → `AVAssetWriter`（H.264/HEVC + AAC，系統聲音與麥克風雙軌）
- **選取覆蓋層**：凍結畫面繪於全螢幕無邊框視窗——自家 UI 永不入鏡
- **編輯器**：SwiftUI `Canvas`，畫布與匯出共用同一套 `CGContext` 渲染器（所見即所得）；命中測試依幾何（線段距離／橢圓帶／外框環）
- **快捷鍵**：Carbon `RegisterEventHotKey` 全域熱鍵；編輯器單鍵以實體 keyCode 判斷，避免輸入法干擾
- **OCR**：Vision `VNRecognizeTextRequest`
- **多語**：自製 L10n 引擎，`.strings` 資源直接放在 `Contents/Resources/*.lproj`，不依賴 SwiftPM 的 `Bundle.module`（其產生器會寫死建置機路徑）

## 專案結構

```
Sources/SnapMark/
├── main.swift / AppMain.swift      # 進入點、選單列、主選單、動作路由
├── WelcomeWindow.swift             # 快速上手／權限狀態視窗
├── CaptureEngine.swift             # SCK 截圖引擎
├── SelectionOverlay.swift          # 區域選取覆蓋層（放大鏡／吸附／手把／工具列）
├── RecorderEngine.swift            # SCStream → AVAssetWriter 錄影
├── RecordingHUD.swift              # 倒數、紅框、控制列、完成面板
├── GIFExporter.swift               # 影片轉 GIF
├── EditorState/View/Window.swift   # 標註編輯器
├── AnnotationModel.swift           # 標註模型、文字樣式、渲染器、命中測試
├── PinWindow.swift                 # 釘選浮動貼圖（AppKit）
├── OCRService.swift / ToastWindow / HistoryManager / HotkeyManager
├── PreferencesWindow.swift         # 偏好設定（含快捷鍵錄製器）
├── L10n.swift + Resources/*.lproj  # 三語系
└── Settings.swift                  # 使用者偏好
Packaging/                          # Info.plist、圖示產生器、自簽憑證腳本
Tools/                              # UI 自動測試工具（合成事件、視窗列表、輸入法切換）
```

MIT-style — 自由使用與修改。
