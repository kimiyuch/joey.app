// swift-tools-version: 6.0
import PackageDescription

let brew = "/opt/homebrew"
let libtorrent = "\(brew)/opt/libtorrent-rasterbar"
let openssl = "\(brew)/Cellar/openssl@4/4.0.3"
let sparkle = "\(Context.packageDirectory)/vendor/sparkle-2.10.0"

let package = Package(
    name: "Joey",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "TorrentCore",
            cxxSettings: [
                .unsafeFlags([
                    "-std=c++17",
                    "-I\(libtorrent)/include",
                    "-I\(brew)/opt/boost/include",
                    "-I\(openssl)/include",
                    "-DTORRENT_LINKING_SHARED",
                    "-DBOOST_ASIO_NO_DEPRECATED",
                    "-DBOOST_SYSTEM_USE_UTF8",
                    "-DTORRENT_ABI_VERSION=2",
                    "-DTORRENT_USE_OPENSSL",
                    "-DTORRENT_USE_LIBCRYPTO",
                    "-DTORRENT_SSL_PEERS",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(libtorrent)/lib", "-ltorrent-rasterbar",
                    "-L\(openssl)/lib", "-lssl", "-lcrypto",
                ]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "Joey",
            dependencies: ["TorrentCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F\(sparkle)"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-F\(sparkle)", "-framework", "Sparkle"]),
            ]
        ),
    ]
)
