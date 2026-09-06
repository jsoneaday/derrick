FROM swiftlang/swift:nightly-6.4.x-noble AS build

WORKDIR /build
COPY Structure /build/Structure
COPY Selenops /build/Selenops
COPY WebCrawler /build/WebCrawler

WORKDIR /build/WebCrawler
# Structure's Linux target compiles only Sources/WebCrawler (see Structure/Package.swift).
RUN swift build -c release --product derrick-web-crawler

FROM swiftlang/swift:nightly-6.4.x-noble

RUN useradd --create-home --uid 10001 crawler
COPY --from=build /build/WebCrawler/.build/release/derrick-web-crawler /usr/local/bin/derrick-web-crawler

USER crawler
ENTRYPOINT ["/usr/local/bin/derrick-web-crawler"]
