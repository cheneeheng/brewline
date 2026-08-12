FROM golang:1.22 AS build
WORKDIR /src
COPY . .
# Resolve deps and generate go.sum (network available at build time). Must run
# after the sources are copied: tidy resolves imports by reading the .go files.
RUN go mod tidy
RUN CGO_ENABLED=0 go build -o /out/inventory .

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/inventory /inventory
EXPOSE 8080
ENTRYPOINT ["/inventory"]
