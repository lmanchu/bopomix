# Bopomix 混打注音輸入法（fork of OpenVanilla McBopomofo 小麥注音）

## mixime：中英混打（P1，預設關閉）

這個 fork 多了「不切換輸入法直接打英文」的功能（見
`~/.claude/plans/zhuyin-ime-personal.md` 的 F1／P1 節）。P1 期間**預設關閉**，
要 dogfood 請自己打開：

```sh
defaults write io.github.lmanchu.bopomix MixedScriptEnabled -bool true
# 關掉：
defaults write io.github.lmanchu.bopomix MixedScriptEnabled -bool false
```

⚠️ 2026-09-10 之前的建置預設是**開啟**的，而且 `Preferences.populateDefaults()`
會把預設值寫進 plist —— 也就是說裝過舊版的機器即使升級也還是開著。這種機器要
先跑一次 `defaults delete io.github.lmanchu.bopomix MixedScriptEnabled`
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

### 英文即時預測與 Tab 補全（P3）

在 mixedScript 打開的前提下（見上面），組字區顯示英文字母且長度達 **4 個字母**以上
時，會在組字區下方顯示預測的完整詞加上 ⇥ 符號（例如打 `thro` 會看到
`throughput ⇥`）：

> 4 個字母這個門檻只管「主動顯示」。**Tab／Shift+Tab 從 2 個字母就能用**，
> 只是輸入法不會自己先跳出來猜。門檻從 2 提到 4 是 2026-09-12 實測的結果：
> 用 17 個每天會打的詞、共 100 個按鍵測，門檻 2 的時候有 33 次螢幕上顯示的是
> **錯的**字（例如打 `the` 打到第 2 個字母就跳 `throughput`），總共只省下 7 個
> 按鍵；提到 4 之後錯誤畫面掉到 11 次，而省下的按鍵只少 1 個。

- **Tab**：如果目前正在打的英文字母序列已能唯一判定成英文（例如上面提到的
  `th`／`acer`），且有比目前打的字更長的字典詞，Tab 直接把整個詞補完，游標
  停在詞尾，可以繼續往後打字。如果目前顯示的是中文（例如 `ell`／`app` 這種還
  沒切到英文的情況），Tab 維持原本「切到英文」的行為；切過去之後如果那個英文
  詞還有更長的補全，再按一次 Tab 就會繼續補完。沒有任何補全時 Tab 完全不動作
  （行為與關掉這個功能時相同）——**已經打完的完整詞也算「沒有補全」**：如果
  目前打的字母序列本身就是字典詞，而且常用度不比任何更長的補全差（例如
  `acer` 是手工科技詞表詞，排序遠優於 `acerbic`），就視為使用者已經打完了，
  不顯示預測、Tab 也不會把它拉長成別的詞。
- **Shift+Tab**：開一個候選窗列出多個補全（數量跟目前設定的選字鍵數一樣多），
  用平常選字的按鍵（預設 `123456789`）挑一個；候選窗開著的時候繼續打字母會直接
  重新查詢、更新候選清單，不會像一般候選窗一樣被字母關掉；按 Esc 關掉候選窗、
  回到還沒補完的原始字母。
- 用 Tab 或候選窗接受的補全詞會計入個人詞庫 `latin-user.txt`（格式從純字改成
  `詞<TAB>次數`，舊檔案沒有次數的行視為 1 次），下次同樣的前綴會優先排到最前
  面；只有「接受」補全才會計次，單純看到預測 tooltip 不會。
- 這個功能自己的開關是 `LatinCompletionEnabled`（**預設開**，但實際上要
  `MixedScriptEnabled` 也開著才會生效）：

  ```sh
  defaults write io.github.lmanchu.bopomix LatinCompletionEnabled -bool false
  ```

- 基礎詞典（`Source/Data/latin-words.txt`）本體與常用度分級 2026-09-11 起
  全部來自 SCOWL/ESDB（見 `ACKNOWLEDGEMENTS.md`），排序優先序是「個人詞庫
  （用過次數多的優先）＞ 手工科技詞表 `latin-tech-seed.txt`（依整理順序）＞
  基礎詞典（依常用度）＞ 字母序」。這是粗粒度分級（5 個 size 分桶），不是
  逐字精確頻率；改用 SCOWL 當詞表本體後，每個詞都有分級（不再有落到字母序
  的未分級詞），而且比舊版（macOS 內建 `/usr/share/dict/words`，1934 年
  Webster's Second，只拿 SCOWL 做分級）多了大量變化形（`games`／`typing`／
  `comments` 這類舊版查不到的詞現在都在）。
- **從實際打過的英文學習**：`LatinLearnTypedWords`（**預設開**）控制是否把
  「打完一段純英文字母、以 Enter／空白／標點結束」也計入個人詞庫，不只是
  Tab／候選窗接受的補全才算——也就是說，就算完全不用 Tab 補全，只要正常打
  英文單字，之後同一個詞也會排到比較前面。隱私：只在英文段真的被提交後才寫
  （按 Esc／Backspace 取消打到一半的英文不會寫），從不記錄任何注音或中文，
  Shift 強制大寫那條路徑（原版既有行為，跟 mixedScript 無關）也不會被這個
  功能記錄；寫入的檔案一樣是本機的 `latin-user.txt`，關掉不想被記錄：

  ```sh
  defaults write io.github.lmanchu.bopomix LatinLearnTypedWords -bool false
  ```

  **打一次記一次，打兩次才算數。** 每次提交只加 1 分，要到 2 分才會影響排序；
  字典裡沒有的詞（人名、產品名、內部代號）**第一次就會以 1 分寫進
  `latin-user.txt`**，但 1 分的非字典詞完全不會出現在預測、Tab 補全或候選窗裡
  ——它只是一張「我看過這個字一次」的紀錄，等第二次提交升到 2 分才變成建議。
  這代表：

  - 檔案裡本來就會有一些你從沒確認過的 1 分詞，包括打錯的字、以及英文後面
    黏到注音鍵的那種怪字串（`acersu` 之類）。它們不會被建議，不用管它。
  - 兩次不必在同一次開機／同一個輸入法 process 裡湊到（2026-09-12 之前是
    這樣，所以真正需要學的新詞幾乎永遠學不起來）。
  - 要「忘掉」某個詞：直接編輯 `latin-user.txt` 砍掉那一行，**然後重新啟動
    輸入法**（登出登入、或切到別的輸入法再切回來）。輸入法在記憶體裡還留著
    那個詞的時候，下一次寫入會把它合併回檔案裡。

- 使用者詞庫檔案的位置跟中文使用者詞庫同一個資料夾（預設
  `~/Library/Application Support/Bopomix/`，偏好設定裡改過就跟著走）。
  換資料夾時 Latin 詞庫會一起重新載入，寫入採「先讀現有檔案再合併」＋暫存檔
  改名落盤，所以新資料夾原本就有的 `latin-user.txt`（例如 Dropbox 從另一台
  機器同步回來的）不會被蓋掉，舊資料夾也不會被動到。

## 系統需求

小麥注音輸入法可以在 macOS 13 以上版本運作。如果您要自行編譯小麥注音輸入法，或參與開發，您需要：

- macOS 26 或更高版本
- Xcode 26 或更高版本
- Python 3.9 (使用 Xcode 安裝後內附的就可以，也可使用 homebrew 等方式安裝)

## 開發流程

用 Xcode 開啟 `Bopomix.xcodeproj`，選 "BopomixInstaller" target，build 完之後直接執行該安裝程式，就可以安裝小麥注音。

第一次安裝完，日後程式碼或詞庫有任何修改，只要重複上述流程，再次安裝小麥注音即可。

要注意的是 macOS 可能會限制同一次 login session 能 kill 同一個輸入法 process 的次數（安裝程式透過 kill input method process 來讓新版的輸入法生效）。如果安裝若干次後，發現程式修改的結果並沒有出現，或甚至輸入法已無法再選用，只要登出目前帳號再重新登入即可。

## 社群公約

歡迎小麥注音用戶回報問題與指教，也歡迎大家參與小麥注音開發。

首先，請參考我們在「[常見問題](https://github.com/openvanilla/McBopomofo/wiki/常見問題)」中所提「[我可以怎麼參與小麥注音？](https://github.com/openvanilla/McBopomofo/wiki/常見問題#我可以怎麼參與小麥注音)」一節的說明。

我們採用了 GitHub 的[通用社群公約](https://github.com/openvanilla/McBopomofo/blob/master/CODE_OF_CONDUCT.md)。公約的中文版請參考[這裡的翻譯](https://www.contributor-covenant.org/zh-tw/version/1/4/code-of-conduct/)。

## 軟體授權

本專案採用 MIT License 釋出，使用者可自由使用、散播本軟體，惟散播時必須完整保留版權聲明及軟體授權（[詳全文](https://github.com/openvanilla/McBopomofo/blob/master/LICENSE.txt)）。
