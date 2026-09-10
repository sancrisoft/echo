# Third-party notices

Echo is licensed under the Apache License 2.0; the text is in [LICENSE](LICENSE)
and Echo's own attribution is in [NOTICE](NOTICE). This file lists the other
people's work that a release of Echo compiles into `Echo.app` or downloads onto
your Mac, with the license each piece is under and the copyright notice that
license asks to travel with the binary. It ships in every release zip next to
`Echo.app`, together with LICENSE and NOTICE.

The Swift packages below are the ones pinned in
[Package.resolved](Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved),
which also holds the exact versions. Licenses and copyright lines were copied
from each package's own LICENSE file at the pinned revision; where a LICENSE
leaves the Apache boilerplate copyright line unfilled, the line comes from the
package's NOTICE file or its source headers, and says so. A test
(`EchoTests/ThirdPartyNoticesTests.swift`) fails when a package appears in
`Package.resolved` without an entry here.

- [Swift packages](#swift-packages)
- [Vendored libraries](#vendored-libraries)
- [Fonts](#fonts)
- [Models](#models)
- [License texts](#license-texts)

## Swift packages

### FluidAudio

Apache License 2.0 · <https://github.com/FluidInference/FluidAudio>

On-device speech recognition: runs the Parakeet Core ML model that transcribes
each meeting. The package's LICENSE leaves the copyright line unfilled; the
project is published by FluidInference. It bundles two components of its own:

- **fastcluster** (hierarchical clustering, C++), BSD 2-Clause License.
  Copyright © 2011 Daniel Müllner; all changes from version 1.1.24 on
  © Google Inc. Text under [BSD 2-Clause License](#bsd-2-clause-license).
- **VBx** speaker clustering, ported from <https://github.com/BUTSpeechFIT/VBx>,
  Apache License 2.0. Copyright 2021-2024 BUT Speech@FIT.

### mlx-swift

MIT License · <https://github.com/ml-explore/mlx-swift>

Copyright (c) 2023 ml-explore. The array framework the summary model runs on.
It compiles in these vendored libraries (under `Source/Cmlx` in the package):

- **MLX** (the C++ core), MIT License. Copyright © 2023 Apple Inc.
  <https://github.com/ml-explore/mlx>
- **mlx-c**, MIT License. Copyright (c) 2023 ml-explore.
  <https://github.com/ml-explore/mlx-c>
- **{fmt}**, MIT License with the optional exception reproduced below.
  Copyright (c) 2012 - present, Victor Zverovich and {fmt} contributors.
  <https://github.com/fmtlib/fmt>
- **nlohmann/json**, MIT License. Copyright (c) 2013-2022 Niels Lohmann.
  <https://github.com/nlohmann/json>
- **metal-cpp**, Apache License 2.0. Copyright © 2024 Apple Inc.
  <https://developer.apple.com/metal/cpp/>

### mlx-swift-lm

MIT License · <https://github.com/ml-explore/mlx-swift-lm>

Copyright (c) 2024 ml-explore. Loads and runs the language model that writes
the summaries. Its `MLXHuggingFaceMacros` compiler plugin is what depends on
swift-syntax.

### swift-transformers

Apache License 2.0 · <https://github.com/huggingface/swift-transformers>

Copyright 2022 Hugging Face SAS. The tokenizer and the Hub client Echo
downloads the summary model with.

### swift-huggingface

Apache License 2.0 · <https://github.com/huggingface/swift-huggingface>

Copyright 2025 Hugging Face SAS. Hugging Face Hub API client, pulled in by
swift-transformers.

### swift-jinja

Apache License 2.0 · <https://github.com/huggingface/swift-jinja>

Copyright 2022 Hugging Face SAS. Renders chat templates, pulled in by
swift-transformers.

### swift-nio

Apache License 2.0 · <https://github.com/apple/swift-nio>

Copyright 2017, 2018 The SwiftNIO Project (from the package's NOTICE.txt);
source headers read "Copyright (c) 2014-2026 Apple Inc. and the SwiftNIO
project authors". Pulled in by EventSource. It bundles:

- **llhttp**, MIT License. Copyright Fedor Indutny, 2018.
  <https://github.com/nodejs/llhttp>

Its NOTICE.txt also carries these attributions, reproduced as the Apache
License asks:

> This product is heavily influenced by Netty (Apache License 2.0,
> <https://netty.io>).
>
> This product contains NodeJS's llhttp (MIT, <https://github.com/nodejs/llhttp>).
>
> This product contains "cpp_magic.h" from Thomas Nixon & Jonathan Heathcote's
> uSHET (MIT, <https://github.com/18sg/uSHET>).
>
> This product contains "sha1.c" and "sha1.h" from FreeBSD (Copyright (C) 1995,
> 1996, 1997, and 1998 WIDE Project) (BSD-3,
> <https://github.com/freebsd/freebsd-src>).
>
> This product contains a derivation of Fabian Fett's 'Base64.swift' (Apache
> License 2.0, <https://github.com/fabianfett/swift-base64-kit>).
>
> This product contains a derivation of "XCTest+AsyncAwait.swift" &
> "StructuredConcurrencyHelpers" from AsyncHTTPClient (Apache License 2.0,
> <https://github.com/swift-server/async-http-client>).
>
> This product contains a derivation of "_TinyArray.swift" from
> SwiftCertificates (Apache License 2.0,
> <https://github.com/apple/swift-certificates>).
>
> This product contains a derivation of the mocking infrastructure from Swift
> System (Apache License 2.0, <https://github.com/apple/swift-system>).
>
> This product contains a derivation of "TokenBucket.swift" from Swift Package
> Manager (Apache License 2.0,
> <https://github.com/swiftlang/swift-package-manager>).

### swift-crypto

Apache License 2.0 · <https://github.com/apple/swift-crypto>

Copyright 2019 The SwiftCrypto Project (from the package's NOTICE.txt).
Pulled in by swift-huggingface and swift-transformers. It bundles:

- **BoringSSL**, Apache License 2.0. Source headers read "Copyright 1995-2025
  The OpenSSL Project Authors. All Rights Reserved." and "Copyright 2014-2025
  The BoringSSL Authors"; a few files carry other permissive notices, kept in
  their headers under `Sources/CCryptoBoringSSL`.
  <https://boringssl.googlesource.com/boringssl>
- **XKCP** (the eXtended Keccak Code Package), released by its implementers
  under the CC0 1.0 public-domain waiver. <https://github.com/XKCP/XKCP>

Its NOTICE.txt also carries these attributions:

> This product contains test vectors from Google's wycheproof project (Apache
> License 2.0, <https://github.com/google/wycheproof>).
>
> This product contains a derivation of various files from SwiftNIO (Apache
> License 2.0, <https://github.com/apple/swift-nio>).

### swift-asn1

Apache License 2.0 · <https://github.com/apple/swift-asn1>

Copyright 2022 The SwiftASN1 Project (from the package's NOTICE.txt). Pulled
in by swift-crypto. Its NOTICE.txt also carries these attributions:

> This product contains derivations of various scripts from SwiftNIO (Apache
> License 2.0, <https://github.com/apple/swift-nio>).
>
> This product contains derivations of various scripts from Swift OpenAPI
> Generator (Apache License 2.0,
> <https://github.com/apple/swift-openapi-generator>).

### swift-collections

Apache License 2.0 with Runtime Library Exception ·
<https://github.com/apple/swift-collections>

Copyright (c) 2019-2026 Apple Inc. and the Swift project authors (source
headers). Pulled in by swift-nio, swift-jinja and swift-transformers.

### swift-numerics

Apache License 2.0 with Runtime Library Exception ·
<https://github.com/apple/swift-numerics>

Copyright (c) 2017-2025 Apple Inc. and the Swift Numerics project authors
(source headers). Pulled in by mlx-swift.

### swift-atomics

Apache License 2.0 with Runtime Library Exception ·
<https://github.com/apple/swift-atomics>

Copyright (c) 2020-2025 Apple Inc. and the Swift project authors (source
headers). Pulled in by swift-nio.

### swift-system

Apache License 2.0 with Runtime Library Exception ·
<https://github.com/apple/swift-system>

Copyright (c) 2020-2026 Apple Inc. and the Swift System project authors
(source headers). Pulled in by swift-nio.

### swift-argument-parser

Apache License 2.0 with Runtime Library Exception ·
<https://github.com/apple/swift-argument-parser>

Copyright (c) 2020-2025 Apple Inc. and the Swift project authors (source
headers). Pulled in by mlx-swift.

### swift-syntax

Apache License 2.0 with Runtime Library Exception ·
<https://github.com/swiftlang/swift-syntax>

Copyright (c) 2014-2025 Apple Inc. and the Swift project authors (source
headers). Backs mlx-swift-lm's compiler macro plugin, which runs at build
time.

### EventSource

MIT License · <https://github.com/mattt/EventSource>

Copyright 2025 Mattt (https://mat.tt). Server-sent events client, pulled in
by swift-huggingface.

### yyjson

MIT License · <https://github.com/ibireme/yyjson>

Copyright (c) 2020 YaoYuan <ibireme@gmail.com>. JSON parser, pulled in by
swift-transformers.

## Vendored libraries

These are checked into the repository under [Packages/Audio/Vendor/webrtc-apm](Packages/Audio/Vendor/webrtc-apm)
as a prebuilt static library; [Packages/Audio/Vendor/webrtc-apm/VERSION](Packages/Audio/Vendor/webrtc-apm/VERSION)
records the upstream tag, commit and build.

### webrtc-audio-processing

BSD 3-Clause License · <https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing>

Copyright (c) 2011, Google Inc. All rights reserved. Source headers read
"Copyright 2006-2023 The WebRTC Project Authors". The standalone WebRTC Audio Processing
Module (AEC3), which cancels the meeting audio out of the microphone. License
file: [Packages/Audio/Vendor/webrtc-apm/licenses/LICENSE.webrtc-audio-processing](Packages/Audio/Vendor/webrtc-apm/licenses/LICENSE.webrtc-audio-processing);
text under [BSD 3-Clause License](#bsd-3-clause-license).

### abseil-cpp

Apache License 2.0 · <https://github.com/abseil/abseil-cpp>

Copyright 2017-2024 The Abseil Authors (source headers). Statically bundled
inside the vendored WebRTC library. License file:
[Packages/Audio/Vendor/webrtc-apm/licenses/LICENSE.abseil-cpp](Packages/Audio/Vendor/webrtc-apm/licenses/LICENSE.abseil-cpp).

## Fonts

The two typefaces the interface is set in are checked into the repository under
[Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts](Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts)
and ship inside `Echo.app`, in the DesignSystem resource bundle. Both are under
the SIL Open Font License 1.1, whose text travels with them in that same folder
as the licence requires.
[Packages/DesignSystem/Vendor/fonts/VERSION](Packages/DesignSystem/Vendor/fonts/VERSION)
records where each file came from, its version and its hash.

Echo neither sells the fonts nor distributes them on their own, and no reserved
font name is used.

### Onest

SIL Open Font License 1.1 · <https://github.com/simpals/onest>

Copyright 2021 The Onest Project Authors. Everything the interface says is set
in Onest. The vendored file is the variable font (weight axis), because the
design sets its headings at a weight no static instance ships. Licence file:
[OFL-Onest.txt](Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts/OFL-Onest.txt);
text under [SIL Open Font License 1.1](#sil-open-font-license-11).

### DM Mono

SIL Open Font License 1.1 · <https://github.com/googlefonts/dm-mono>

Copyright 2020 The DM Mono Project Authors. Numbers and identifiers only —
timers, durations, word counts, model names, shortcuts. Three upright weights
are vendored; the italics are not. Licence file:
[OFL-DMMono.txt](Packages/DesignSystem/Sources/DesignSystem/Resources/Fonts/OFL-DMMono.txt);
text under [SIL Open Font License 1.1](#sil-open-font-license-11).

## Models

Echo downloads two models from Hugging Face at first launch, into
`~/Library/Application Support/Echo/Models`. They are not in the release zip
and Echo never redistributes them; they are listed here because Echo runs
them and because CC BY 4.0 asks for attribution wherever the model is named.
Licenses are as published on Hugging Face on 2026-09-04.

### Parakeet TDT 0.6B v3

- **Original model:** [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
  by NVIDIA, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
  Attribution: Parakeet TDT 0.6B v3 © NVIDIA, CC-BY-4.0. This is the line
  Echo shows wherever the app names the model.
- **What Echo downloads:** [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml),
  FluidInference's Core ML conversion of that model (Echo uses the int8
  encoder). Its Hugging Face metadata declares `license: cc-by-4.0` with
  `base_model: nvidia/parakeet-tdt-0.6b-v3`; the model card's License section
  says "Apache 2.0. See the FluidAudio repository". Both are recorded here as
  published. NVIDIA's attribution applies either way.

### Qwen3.5 4B (OptiQ 4-bit)

- **What Echo downloads:** [mlx-community/Qwen3.5-4B-OptiQ-4bit](https://huggingface.co/mlx-community/Qwen3.5-4B-OptiQ-4bit),
  a 4-bit mixed-precision MLX quantization produced with mlx-optiq and
  published by mlx-community, Apache License 2.0 (`license: apache-2.0`).
- **Base model:** [Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B)
  by Qwen, Apache License 2.0. Copyright 2026 Alibaba Cloud (from the model's
  [LICENSE](https://huggingface.co/Qwen/Qwen3.5-4B/blob/main/LICENSE)).

## License texts

### MIT License

The MIT text below is the one shipped, word for word, by EventSource,
mlx-swift, mlx-swift-lm, yyjson, MLX, mlx-c, nlohmann/json and llhttp. It
applies to each with that component's copyright line:

- Copyright 2025 Mattt (https://mat.tt) — EventSource
- Copyright (c) 2023 ml-explore — mlx-swift, mlx-c
- Copyright (c) 2024 ml-explore — mlx-swift-lm
- Copyright (c) 2020 YaoYuan <ibireme@gmail.com> — yyjson
- Copyright © 2023 Apple Inc. — MLX
- Copyright (c) 2013-2022 Niels Lohmann — nlohmann/json
- Copyright Fedor Indutny, 2018. — llhttp
- Copyright (c) 2012 - present, Victor Zverovich and {fmt} contributors — {fmt},
  whose LICENSE adds the optional exception that follows the text

```text
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

{fmt}'s LICENSE continues:

```text
--- Optional exception to the license ---

As an exception, if, as a result of your compiling your source code, portions
of this Software are embedded into a machine-executable object form of such
source code, you may redistribute such embedded portions in such object form
without including the above copyright and permission notices.
```

### BSD 3-Clause License

webrtc-audio-processing, from `Packages/Audio/Vendor/webrtc-apm/licenses/LICENSE.webrtc-audio-processing`:

```text
Copyright (c) 2011, Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### BSD 2-Clause License

fastcluster, bundled in FluidAudio (`ThirdPartyLicenses/fastcluster-LICENSE.md`
in that package):

```text
Copyright:
  * Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>
  * All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Apache License 2.0

The full text is Echo's own [LICENSE](LICENSE); the packages above that are
under it ship the same text. Abseil's copy is at
[Packages/Audio/Vendor/webrtc-apm/licenses/LICENSE.abseil-cpp](Packages/Audio/Vendor/webrtc-apm/licenses/LICENSE.abseil-cpp).
The Swift packages marked "with Runtime Library Exception" append this to it:

```text
Runtime Library Exception to the Apache 2.0 License:

As an exception, if you use this Software to compile your source code and
portions of this Software are embedded into the binary product as a result,
you may redistribute such product without providing attribution as would
otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
```

### CC0 1.0 (XKCP)

The XKCP sources inside swift-crypto state: "To the extent possible under law,
the implementer has waived all copyright and related or neighboring rights to
the source code in this file." <http://creativecommons.org/publicdomain/zero/1.0/>

### CC BY 4.0 (Parakeet)

<https://creativecommons.org/licenses/by/4.0/legalcode>

### SIL Open Font License 1.1

The text below is the one shipped, word for word, by Onest and DM Mono. It
applies to each with that font's copyright line:

- Copyright 2021 The Onest Project Authors (https://github.com/googlefonts/onest) — Onest
- Copyright 2020 The DM Mono Project Authors (https://www.github.com/googlefonts/dm-mono) — DM Mono

```
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```
