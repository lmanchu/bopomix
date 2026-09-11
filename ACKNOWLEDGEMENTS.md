小麥注音使用下列開源程式庫：

- [SwiftyOpenCC](https://github.com/ddddxxx/SwiftyOpenCC) by DengXiang under
  the MIT License.
- [SQLite.swift](https://github.com/stephencelis/SQLite.swift) by Stephen Celis
  under the MIT License.

注音字型破音字標記資料，衍生自[注音IVS字型規格](https://github.com/ButTaiwan/bpmfvs)
專案的[國字讀音整理檔](https://github.com/ButTaiwan/bpmfvs/tree/master/phonetic)，
該專案作者為 But Ko，採 Apache License v2.0 發布。

`Source/Data/latin-words.txt`（中英混打詞典本體＋詞頻分級，見
`tools/lexicon/build_lexicon.py`）2026-09-11 起完全衍生自 **SCOWL /
ESDB**（English Speller Database，原名 Spell Checker Oriented Word Lists；
https://github.com/en-wl/wordlist ，作者 Kevin Atkinson）size ≤70 的
American-English、variant level ≤1 詞表累積輸出（`./scowl --db scowl.db
word-list <35|40|50|60|70> A 1 --categories=`），只取「一個詞第一次出現在
哪個 size 桶」當粗粒度常用度分級，不含 ESDB 資料庫本身或其原始碼。

此前（P1／P3 第一輪，2026-09-09～2026-09-11）詞表本體來自 macOS 內建
`/usr/share/dict/words`（symlink 至 `web2`，源自 Webster's Second
International Dictionary，1934 年版權已過期／公有領域，依 FreeBSD 隨附之
`/usr/share/dict/README` 所載，由 FreeBSD 專案整理維護、隨 macOS base
system 附帶散布），只拿 SCOWL 的 size 分桶做詞頻分級（`scowl-size-tiers.tsv`
標註檔）。web2 本身完全沒有字詞變化形（games／typing／comments 等一律缺席，
只有其字典形存在），2026-09-11 已停用，不再是本專案任何檔案的來源；
`scowl-size-tiers.tsv` 這個獨立標註檔也隨之移除（詞頻分級現在是產生詞表
本體時直接算好、寫進 `latin-words.txt` 的欄位，不再需要另一個檔案）。

`Source/Data/latin-tech-seed.txt` 為本專案原創整理的科技詞彙補充清單，非衍
生自任何第三方詞庫。

ESDB 專案 `Copyright` 檔的授權原文（適用於本檔案性質的「由資料庫產生的詞
表」）：

> Permission to use, copy, modify, distribute, and sell any part of the
> English Speller Database (ESDB, previously known as SCOWLv2), or word
> lists created from it, is hereby granted without fee, provided that the
> above copyright notice appears in all copies and that both the above
> copyright notice and this notice appear in supporting documentation.
> Kevin Atkinson makes no representations about the suitability of this
> database for any purpose. It is provided "as is" without express or
> implied warranty.
>
> Copyright 2000-2026 by Kevin Atkinson

（ESDB 本身彙整自多個以 Public Domain 為主的來源，含 12dicts／ENABLE2K；本
專案只使用到 size ≤70、American 拼法、variant-level 1 的一般詞表，未使用
Australian 或 UKACD 相關內容，故上述通用授權即已足夠，不觸發 `Copyright`
檔案中 `=== AU` / `=== UKACD` 段落的額外條件。）

`first20hours/google-10000-english`（Google Trillion Word Corpus 衍生的
頻率詞表）**已查證但未採用**：其 `LICENSE.md` 將底層語料綁定 LDC
（Linguistic Data Consortium）授權與研究／合理使用範圍，並明文「不建議
商業用途」，不符合本專案「授權明確可再散布」的門檻，故未使用。

