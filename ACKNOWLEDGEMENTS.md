小麥注音使用下列開源程式庫：

- [SwiftyOpenCC](https://github.com/ddddxxx/SwiftyOpenCC) by DengXiang under
  the MIT License.
- [SQLite.swift](https://github.com/stephencelis/SQLite.swift) by Stephen Celis
  under the MIT License.

注音字型破音字標記資料，衍生自[注音IVS字型規格](https://github.com/ButTaiwan/bpmfvs)
專案的[國字讀音整理檔](https://github.com/ButTaiwan/bpmfvs/tree/master/phonetic)，
該專案作者為 But Ko，採 Apache License v2.0 發布。

`Source/Data/latin-words.txt`（P1 中英混打詞典，見
`tools/lexicon/build_lexicon.py`）由 macOS 內建 `/usr/share/dict/words`
（symlink 至 `web2`）過濾產生。該檔案源自 Webster's Second International
Dictionary（1934 年版權已過期／公有領域，依 FreeBSD 隨附之
`/usr/share/dict/README` 所載），並由 FreeBSD 專案整理維護、隨 macOS base
system 附帶散布。`Source/Data/latin-tech-seed.txt` 為本專案原創整理的科技
詞彙補充清單，非衍生自任何第三方詞庫。

