FROM swiftlang/swift:nightly-6.4.x-noble AS build

WORKDIR /build/WebCrawler
COPY packages/WebCrawler/Package.swift packages/WebCrawler/Package.resolved ./
COPY packages/WebCrawler/Sources ./Sources
COPY packages/WebCrawler/Tests ./Tests
COPY packages/Selenops /build/Selenops

RUN swift build -c release --product derrick-web-crawler

FROM swiftlang/swift:nightly-6.4.x-noble

RUN useradd --create-home --uid 10001 crawler
COPY --from=build /build/WebCrawler/.build/release/derrick-web-crawler /usr/local/bin/derrick-web-crawler

USER crawler
ENTRYPOINT ["/usr/local/bin/derrick-web-crawler"]
