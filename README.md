# Bopomix 混打注音

macOS 注音輸入法。打中文的時候直接打英文，不用切換輸入法。

[English](#english)

你打「我在 slack 上看到那個 issue 了」，從頭打到尾不按 Shift、不切輸入法。
打到 `sl` 的時候輸入法就知道這是英文，打到 `iss` 它會提示 `issue ⇥`，按 Tab 補完。

混打注音是[小麥注音（McBopomofo）](https://github.com/openvanilla/McBopomofo)的分支，
加了兩件事：不切換就能打英文，以及英文的預測與 Tab 補全。其他一切都跟小麥注音一樣。

## 安裝

需求：macOS 13 以上，Apple Silicon（Intel 版之後補）。

1. 到 [Releases](https://github.com/lmanchu/bopomix/releases) 下載最新的 `Bopomix-*.dmg`，打開。
2. 雙擊裡面的「安裝混打注音」，等它說安裝完成。
3. 到系統設定 ▸ 鍵盤 ▸ 輸入方式 ▸ 編輯 ▸ 按「＋」▸ 繁體中文 ▸ 加入「混打注音」（英文介面顯示為 Bopomix）。之後從選單列的輸入法選單就能切換。

安裝程式和輸入法都有 Apple 簽章與公證，不用改任何安全設定。第 3 步只有第一次需要：macOS 要求新的輸入法由使用者親自加入一次。要移除的話，到系統設定 ▸ 鍵盤 ▸ 輸入方式把它拿掉，再刪除 `~/Library/Input Methods/Bopomix.app`。

原本就在用小麥注音？第一次啟動時，你的設定和自訂詞會自動複製過來，原本的小麥注音不會被動到。

## 它會做的事

- **打英文不用切換**：字母一旦拼不出注音（例如 `th`、`acer` 打到第二個字母），
  輸入法就當它是英文，組字區直接顯示字母，後面接空白就是真的空白。
- **拼得出注音的英文字也不會卡住**：像 `app`、`ell` 這種兩邊都說得通的，先當中文，
  英文放在候選窗第二列，按一次 Tab 就切過去。選過一次，下次打同一個字加空白就直接是英文。
- **英文預測與 Tab 補全**：英文打到 4 個字母會在下方提示完整的字，Tab 接受，
  Shift+Tab 列出更多選擇。你常打的字會排前面。
- **會學你的字**：Tab 接受過或正常打完的英文字都會記進本機的個人詞庫，人名、產品名打過兩次就會開始被建議。

只支援標準（大千）注音配置與「注音」模式；「傳統注音」模式與許氏、倚天 26 配置不受影響，但也沒有混打。

## 設定

都是開著的，要關掉在「終端機」執行：

| 要關掉的功能 | 指令 |
|---|---|
| 中英混打（整組） | `defaults write io.github.lmanchu.inputmethod.bopomix MixedScriptEnabled -bool false` |
| 英文預測與 Tab 補全 | `defaults write io.github.lmanchu.inputmethod.bopomix LatinCompletionEnabled -bool false` |
| 從打過的英文學習 | `defaults write io.github.lmanchu.inputmethod.bopomix LatinLearnTypedWords -bool false` |
| 個人詞庫的字加空白直接變英文 | `defaults write io.github.lmanchu.inputmethod.bopomix MixedScriptLatinOnSpaceForUserWords -bool false` |

把 `false` 換成 `true` 就是打開。改完切到別的輸入法再切回來。

## 隱私

- 所有事情都在你的電腦上發生。輸入法唯一會連線的是每天一次的版本檢查（到 GitHub），可以在偏好設定裡關掉。
- 學到的英文字存在 `~/Library/Application Support/Bopomix/latin-user.txt`，一行一個字，你可以打開看、可以刪。
  只記提交出去的英文字，從不記注音或中文；打到一半按 Esc 或 Backspace 取消的不會記。
- 中文自訂詞也在同一個資料夾，格式跟小麥注音相同。

## 目前的限制

- 中英判斷是規則，不是 AI。拼得出注音的英文字（`mac` 也是「ㄇㄚ」）第一次一定要按 Tab。
- 補全候選窗前三名之外是字母順序，因為詞典只有粗粒度的常用度分級。真實詞頻是下一個要做的事。
- 從 `latin-user.txt` 手動刪掉的字，要切換輸入法重啟才會真的忘記。
- 補全候選窗開著的時候按小寫字母會把窗關掉。
- 整句的 AI 選字（用本機小模型重排候選）研究過但還沒做。

## 從原始碼建置、回報問題、參與

- 建置與測試方式見 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 每一版改了什麼見 [CHANGELOG.md](CHANGELOG.md)。開發過程中每一輪的審查與複驗記錄在 [docs/](docs/)，原樣公開。
- 問題與想法請開 [Issue](https://github.com/lmanchu/bopomix/issues)。打錯字的句子是最好的回報：把你打的按鍵和你期望的結果貼上來。

## 致謝與授權

混打注音衍生自 OpenVanilla 的 [小麥注音 McBopomofo](https://github.com/openvanilla/McBopomofo)（MIT License，Copyright 2011-2026 Mengjuei Hsieh et al.）。
英文詞典來自 [SCOWL](https://github.com/en-wl/wordlist)。完整清單見 [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md)。

本專案採用 MIT License，見 [LICENSE.txt](LICENSE.txt)。

---

## English

**Bopomix** is a Zhuyin (Bopomofo) input method for macOS that lets you type English in the middle of Chinese without switching input sources.

Type 我在 slack 上看到那個 issue 了 straight through. By `sl` the input method has decided it is English; by `iss` it offers `issue ⇥`, and Tab completes it.

Bopomix is a fork of [McBopomofo](https://github.com/openvanilla/McBopomofo) (OpenVanilla, MIT) with two additions: mixed Chinese/English typing without switching, and English prediction with Tab completion. Everything else is McBopomofo.

**Install** (macOS 13+, Apple Silicon): download the latest `Bopomix-*.dmg` from [Releases](https://github.com/lmanchu/bopomix/releases), open it, double-click **安裝混打注音** (Install Bopomix), then add **Bopomix** once under System Settings ▸ Keyboard ▸ Input Sources ▸ Edit ▸ + ▸ Traditional Chinese. From then on it is in the input menu. Both the installer and the input method are signed and notarized. If you already use McBopomofo, your settings and user phrases are copied over on first launch; McBopomofo itself is left untouched.

**What it does**: letters that cannot form a Zhuyin syllable (`th`, the second letter of `acer`) become English on the spot. Words that are valid both ways (`app`, `ell`) stay Chinese, with the English reading one Tab away; once chosen, the same word plus a space is English from then on. After four letters of English you get a completion hint; Tab accepts it, Shift+Tab shows more. Words you type are learned into a local list. Standard (Dachen) layout and the Bopomofo mode only.

**Privacy**: everything runs locally. The only network access is a daily update check against GitHub, which you can turn off. Learned English words live in `~/Library/Application Support/Bopomix/latin-user.txt`, one per line; nothing Chinese or phonetic is ever recorded.

**Settings**: four `defaults write io.github.lmanchu.inputmethod.bopomix <key> -bool false` switches — `MixedScriptEnabled`, `LatinCompletionEnabled`, `LatinLearnTypedWords`, `MixedScriptLatinOnSpaceForUserWords`.

**Limits**: the Chinese/English decision is rule-based, not a language model; completion ranking is coarse beyond the top few; deleting a learned word takes effect after the input method restarts. See [CHANGELOG.md](CHANGELOG.md) for details and [CONTRIBUTING.md](CONTRIBUTING.md) to build from source.

MIT License. Derived from McBopomofo, Copyright 2011-2026 Mengjuei Hsieh et al.; English word list from SCOWL. See [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
