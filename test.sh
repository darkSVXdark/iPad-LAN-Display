#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/Core.swift Sources/Server.swift Tests/Runner.swift -o .build/checks
.build/checks
