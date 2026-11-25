# Third-party notices

The GrandSlam SRP implementation was adapted from a C++ port of blacktop/ipsw
and ipatool. Its upstream license is retained below.
The ADI implementation includes recovered protocol formulas and fixed algorithm
parameters. The HTTPS transport embeds Apple's public Root CA certificate as a
supplemental trust anchor while retaining peer and hostname verification.

External dependencies remain under their respective licenses; license texts are
provided in `LICENSES/`:

- Mbed TLS: Apache-2.0 or GPL-2.0-or-later (used under Apache-2.0).
- libcurl: curl license.
- libplist: LGPL-2.1-or-later.
- nlohmann/json: MIT.
- Optional TestFlight module: libzip (BSD-3-Clause), zlib (Zlib), and LZFSE
  (BSD-3-Clause). LZFSE is pinned at `e634ca58b4821d9f3d560cdc6df5dec02ffc93fd`;
  its license is installed with the enabled module.

## ipsw / ipatool

MIT License

Copyright (c) 2018-2026 blacktop

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
