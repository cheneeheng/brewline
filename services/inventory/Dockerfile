FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod ./
# Resolve deps and generate go.sum (network available at build time).
RUN go mod tidy
COPY . .
RUN CGO_ENABLED=0 go build -o /out/inventory .

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/inventory /inventory
EXPOSE 8080
ENTRYPOINT ["/inventory"]
