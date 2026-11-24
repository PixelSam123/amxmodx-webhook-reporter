# Third-party notices

This project is licensed under GPL-3.0-or-later (see [`LICENSE`](LICENSE)).
It incorporates the third-party material listed below; those files remain
under their own licenses.

## AmxxEasyHttp

- **Files:** `amxmodx/scripting/include/easy_http.inc`,
  `amxmodx/scripting/include/easy_http_json.inc`
- **Source:** <https://github.com/Next21Team/AmxxEasyHttp>
- **Version:** `1.5.0` (tag `1.5.0`)
- **License:** MIT, Copyright (c) 2021 Igor Minin
- **Changes:** only an SPDX/license header comment was added to each file.
  The code is otherwise unmodified.

Upstream SHA-256 of the unmodified files (to detect drift against the release):

| File | SHA-256 |
| --- | --- |
| `easy_http.inc` | `31b2e852ceaa2012bdfc8725f8dad41cbf0b67a271c7c97ea60c130807af9bdd` |
| `easy_http_json.inc` | `9b804efd85b2d2b1bc9fa125e0de4789db84bcdd1f964ebb2f2faec8ed4f831d` |

The full MIT text is in
[`LICENSES/MIT-AmxxEasyHttp.txt`](LICENSES/MIT-AmxxEasyHttp.txt) and is
reproduced below.

```text
MIT License

Copyright (c) 2021 Igor Minin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## PugMod

- **Source:** <https://github.com/SmileYzn/PugMod>
- **License:** MIT, Copyright (c) 2024 Cleverson
- **Use:** no PugMod source code is included or linked. The plugin only reads
  PugMod's public cvars (`pug_state`, `pug_rounds`, `pug_rounds_ot`) and
  follows its documented match-state values and side-swap behaviour. PugMod is
  credited for interoperability only.

## AMX Mod X

- **Source:** <https://github.com/alliedmodders/amxmodx>
- **License:** GPL-3.0-or-later with exceptions, see
  <https://www.alliedmods.net/amxmodx-license>

No AMX Mod X source files are redistributed in this repository. The plugin is
compiled against the AMX Mod X headers, which makes it a derivative work of
AMX Mod X. AMX Mod X's license explicitly permits derivative works such as
Pawn plugins to be licensed under GPL-2.0-or-later or GPL-3.0-or-later.
