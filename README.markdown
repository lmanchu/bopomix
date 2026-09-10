# OpenVanilla McBopomofo 小麥注音輸入法

## mixime：中英混打（P1，預設關閉）

這個 fork 多了「不切換輸入法直接打英文」的功能（見
`~/.claude/plans/zhuyin-ime-personal.md` 的 F1／P1 節）。P1 期間**預設關閉**，
要 dogfood 請自己打開：

```sh
defaults write org.openvanilla.inputmethod.McBopomofo MixedScriptEnabled -bool true
# 關掉：
defaults write org.openvanilla.inputmethod.McBopomofo MixedScriptEnabled -bool false
```

⚠️ 2026-09-10 之前的建置預設是**開啟**的，而且 `Preferences.populateDefaults()`
會把預設值寫進 plist —— 也就是說裝過舊版的機器即使升級也還是開著。這種機器要
先跑一次 `defaults delete org.openvanilla.inputmethod.McBopomofo MixedScriptEnabled`
才會回到「預設關閉」。

關閉時所有 mixedScript 的程式路徑都會短路，行為與上游 McBopomofo 完全相同
（`McBopomofoTests/MixedScriptKeyHandlerTests.swift` 的
`testB7_DisabledBehavesLikeUpstream` 釘住這件事）。

打開之後：

- 字母打到「注音上不可能組成音節」時（例如 `th`、`acer` 的第二個字母）自動轉成
  英文，組字區直接顯示原始字母；空白鍵接在英文後面就是一個真正的空白。
- 打得出合法注音、又剛好是英文單字時（例如 `ell`／`app`）**維持中文**，英文形式
  放在候選窗第二列，按一次 Tab 就切過去。用 Tab 或候選窗選過的英文詞會寫進
  `latin-user.txt`，之後再打同一個詞加空白就會自動判成英文。
- 只支援標準（大千）鍵盤配置與「注音」輸入模式，「傳統注音」不受影響。

另一個開關 `MixedScriptLatinOnSpaceForUserWords`（預設開）控制上面最後那條
「個人詞庫 + 空白 → 英文」的自動行為。

## 系統需求

小麥注音輸入法可以在 macOS 13 以上版本運作。如果您要自行編譯小麥注音輸入法，或參與開發，您需要：

- macOS 26 或更高版本
- Xcode 26 或更高版本
- Python 3.9 (使用 Xcode 安裝後內附的就可以，也可使用 homebrew 等方式安裝)

## 開發流程

用 Xcode 開啟 `McBopomofo.xcodeproj`，選 "McBopomofo Installer" target，build 完之後直接執行該安裝程式，就可以安裝小麥注音。

第一次安裝完，日後程式碼或詞庫有任何修改，只要重複上述流程，再次安裝小麥注音即可。

要注意的是 macOS 可能會限制同一次 login session 能 kill 同一個輸入法 process 的次數（安裝程式透過 kill input method process 來讓新版的輸入法生效）。如果安裝若干次後，發現程式修改的結果並沒有出現，或甚至輸入法已無法再選用，只要登出目前帳號再重新登入即可。

## 社群公約

歡迎小麥注音用戶回報問題與指教，也歡迎大家參與小麥注音開發。

首先，請參考我們在「[常見問題](https://github.com/openvanilla/McBopomofo/wiki/常見問題)」中所提「[我可以怎麼參與小麥注音？](https://github.com/openvanilla/McBopomofo/wiki/常見問題#我可以怎麼參與小麥注音)」一節的說明。

我們採用了 GitHub 的[通用社群公約](https://github.com/openvanilla/McBopomofo/blob/master/CODE_OF_CONDUCT.md)。公約的中文版請參考[這裡的翻譯](https://www.contributor-covenant.org/zh-tw/version/1/4/code-of-conduct/)。

## 軟體授權

本專案採用 MIT License 釋出，使用者可自由使用、散播本軟體，惟散播時必須完整保留版權聲明及軟體授權（[詳全文](https://github.com/openvanilla/McBopomofo/blob/master/LICENSE.txt)）。
