// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "dns-chain",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DNSChainCore", targets: ["DNSChainCore"]),
        .executable(name: "DNSChain", targets: ["DNSChain"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.98.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.0")
    ],
    targets: [
        .target(
            name: "DNSChainCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1")
            ]
        ),
        .executableTarget(
            name: "DNSChain",
            dependencies: ["DNSChainCore"]
        ),
        .testTarget(
            name: "DNSChainCoreTests",
            dependencies: [
                "DNSChainCore",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ]
        )
    ]
)
