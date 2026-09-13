# 參與混打注音 / Contributing to Bopomix

問題回報、想法、PR 都歡迎。這份文件講怎麼把專案建起來、怎麼跑測試、PR 需要附什麼。
細節（架構、狀態機、詞庫資料）在 [AGENTS.md](AGENTS.md) 與 [algorithm.md](algorithm.md)，
那兩份也是給 AI 助手讀的，內容以它們為準。

## 建置

需要 macOS 26、Xcode 26（Swift 6.3），引擎測試另外需要 CMake 與 GoogleTest（`brew install cmake googletest`）。

```sh
git clone https://github.com/lmanchu/bopomix.git
cd bopomix
xcodebuild -project Bopomix.xcodeproj -scheme BopomixInstaller -configuration Debug build
```

建好的 `BopomixInstaller.app` 執行一次就會把輸入法裝進 `~/Library/Input Methods/` 並重啟它。
第一次要到系統設定 ▸ 鍵盤 ▸ 輸入方式加入「混打注音」（英文介面顯示 Bopomix）。
之後每次改完程式重跑安裝程式即可；macOS 對同一次登入能 kill 輸入法的次數有限制，
裝了幾次沒反應就登出再登入。

## 跑測試

兩套：Swift 測試（走真正的 `KeyHandler`）與 C++ 引擎測試。

```sh
tools/eval/check_plist_unchanged.sh \
  xcodebuild -project Bopomix.xcodeproj -scheme Bopomix \
    -configuration Debug -derivedDataPath build \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" test
```

```sh
cmake -S Source/Engine -B build-engine -DENABLE_TEST=ON && cmake --build build-engine && ctest --test-dir build-engine
```

三件事一定要照做：

- **Swift 測試必須序列跑。** 不要加 `-parallel-testing-enabled YES`。偏好設定是一個所有 runner 共用的檔案，並行會互相踩到，出現與你的修改無關的失敗。
- **測試不得碰你自己的輸入法設定與詞庫。** 上面那個 `check_plist_unchanged.sh` 把測試包起來跑，前後比對 `io.github.lmanchu.inputmethod.bopomix` 這個 domain 與 `~/Library/Application Support/Bopomix/`，有任何差異就報 `PLIST_CHANGED` / `DATA_FOLDER_CHANGED`。新測試若動到偏好，`setUpWithError()` 第一句要 `PreferenceSandbox.install(on: self)`；動到詞庫資料夾要用 `LanguageModelManager.dataFolderOverrideForTesting`。這條規則是血淚換來的：曾經有測試把暫存資料夾的路徑寫進維護者正在用的輸入法。
- **測試跑的時候不要在已安裝的混打注音裡改設定。** 跑完 teardown 會整包還原到測試開始時的快照。

## 評測語料

兩個評測測試（`testEval200ThroughKeyHandler`、`testEval200LatinCompletion`）讀環境變數 `BOPOMIX_EVAL_CORPUS`
指向的 TSV；沒設就 skip。語料是用你**自己的**文字產生的，永遠不進 repo（`.gitignore` 已擋 `eval-corpus/` 與 `*.private.*`）：

```sh
python3 tools/eval/build_corpus.py --candidates <你的句子檔> --output eval-corpus/corpus.tsv --cli build-engine/tools/eval/bopomix-eval --data build/Build/Products/Debug/Bopomix.app/Contents/Resources
BOPOMIX_EVAL_CORPUS="$PWD/eval-corpus/corpus.tsv" tools/eval/check_plist_unchanged.sh xcodebuild ... test
```

用法細節與 headless 的 `bopomix-eval` CLI 見 [tools/eval/README.md](tools/eval/README.md)。
評測數字以 XCTest 走真實 `KeyHandler` 的那份為準，CLI 的數字只量引擎；兩者曾經差過一輪，別再被騙。

## 送 PR

- Commit 用 Conventional Commits（`feat(mixedscript): …`、`fix(completion): …`）。
- 動到中英判斷、補全、學習的 PR，請附 eval 前後的數字（`tools/eval/BASELINE.md` 那幾行）和你用的語料規模。
- 改動集中在新檔案與少量插入點。引擎的 `McBopomofo` 命名空間、`McBopomofoLM`、上游檔頭都刻意保留，方便跟上游同步；不要順手改名。
- 打錯字的句子是最好的回報：Issue 裡貼你打的按鍵序列（例如 `ji3slack cj04`）、你期望看到的、實際看到的。

## 我們怎麼做事

這個專案是「人跟 AI 一起 build」的練習：每一輪實作都有獨立的審查與複驗，記錄原樣放在 [docs/](docs/)。
三個從那裡學到、寫進規則的教訓：評測要走 app 的真實路徑；測試不得碰真實設定；
任何「其實不需要做」的判斷都要查證，審查者的建議也要被複驗。
