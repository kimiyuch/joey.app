// swift-tools-version: 6.0
import PackageDescription

let brew = "/opt/homebrew"
let libtorrent = "\(brew)/opt/libtorrent-rasterbar"
let openssl = "\(brew)/Cellar/openssl@4/4.0.3"
let mpv = "\(brew)/opt/mpv"
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
        // libmpv headers; the library itself is linked by the app target.
        .systemLibrary(name: "CMpv", path: "Sources/CMpv"),
        .executableTarget(
            name: "Joey",
            dependencies: ["TorrentCore", "CMpv"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F\(sparkle)", "-Xcc", "-I\(mpv)/include", "-Xcc", "-DGL_SILENCE_DEPRECATION"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-F\(sparkle)", "-framework", "Sparkle", "-L\(mpv)/lib", "-lmpv"]),
                .linkedFramework("OpenGL"),
            ]
        ),
    ]
)
