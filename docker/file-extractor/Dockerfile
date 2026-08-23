FROM swiftlang/swift:nightly-6.4.x-noble AS build

WORKDIR /build/FileExtractor
COPY packages/FileExtractor/Package.swift ./
COPY packages/FileExtractor/Sources ./Sources
COPY packages/FileExtractor/Tests ./Tests

RUN swift build -c release --product derrick-file-extractor

FROM swiftlang/swift:nightly-6.4.x-noble

RUN apt-get update \
    && apt-get install -y --no-install-recommends poppler-utils \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 extractor

COPY --from=build /build/FileExtractor/.build/release/derrick-file-extractor /usr/local/bin/derrick-file-extractor
RUN mkdir -p /data/in /data/out && chown -R extractor:extractor /data

USER extractor
ENTRYPOINT ["/usr/local/bin/derrick-file-extractor"]
