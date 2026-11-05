#!/bin/bash
# Usage: PATH=/opt/swift/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH scripts/linux-jmapkit-check.sh
# Builds and tests JMAPKit (Foundation-only) on Linux, minus CryptoKit/OSLog/URLSession files.
# Mirror JMAPKit + its tests into a Linux-buildable scratch package.
S=${S:-/tmp/plmail-linux-check}
R=$(cd "$(dirname "$0")/../Packages/PLMail" && pwd)
rm -rf $S/Sources $S/Tests; mkdir -p $S/Sources $S/Tests
cp -r $R/Sources/JMAPKit $R/Sources/JMAPTestSupport $S/Sources/
cp -r $R/Tests/JMAPKitTests $S/Tests/
rm -f $S/Sources/JMAPKit/Client/ServerTrust.swift $S/Sources/JMAPKit/Client/URLSessionTransport.swift $S/Sources/JMAPKit/EventSource/EventSourceClient.swift
for t in CredentialTests ; do rm -f $S/Tests/JMAPKitTests/$t.swift; done
find $S/Sources $S/Tests -name "*.swift" -exec sed -i 's/^\(public \)\?import Foundation$/&\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif/' {} +
cat > $S/Package.swift <<'PKG'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LinuxCheck",
  targets: [
    .target(name: "JMAPKit"),
    .target(name: "JMAPTestSupport", dependencies: ["JMAPKit"]),
    .testTarget(name: "JMAPKitTests", dependencies: ["JMAPKit","JMAPTestSupport"], resources: [.copy("Fixtures")]),
  ], swiftLanguageModes: [.v6])
PKG
cd $S && swift test
