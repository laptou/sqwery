// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "sqwery",
  platforms: [
    .iOS(.v17), // This marks the entire package as iOS 17 and up
  ],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "sqwery",
      targets: ["sqwery"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.0.0"),
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(
      name: "sqwery"
    ),
    .testTarget(
      name: "sqweryTests",
      dependencies: ["sqwery"]
    ),
  ]
)
