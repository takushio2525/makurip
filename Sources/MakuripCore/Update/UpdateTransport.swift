import Foundation

/// 版の問い合わせとダウンロード（本番は URLSession。テストでは偽物）。
///
/// 送るのは GET だけ（User-Agent に Makurip の版を入れる）。履歴・設定・使い方の情報は送らない。
/// クッキー・キャッシュ・認証は使わない（ephemeral）
public protocol UpdateTransport: Sendable {
    /// 小さいもの（Release の一覧・sha256 のファイル）を読む。`maxBytes` を超えたら `tooLarge`
    func data(from url: URL, maxBytes: Int) async throws -> Data
    /// 大きいもの（zip）を `destination` に落とす。`maxBytes` を超えたら `tooLarge`
    func download(from url: URL, to destination: URL, maxBytes: Int) async throws
}

public struct URLSessionUpdateTransport: UpdateTransport {
    private let session: URLSession

    public init(userAgent: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent, "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        ]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func data(from url: URL, maxBytes: Int) async throws -> Data {
        if url.isFileURL { return try Self.readFile(url, maxBytes: maxBytes) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw UpdateFailure.network(Self.describe(error))
        }
        try Self.checkStatus(response)
        guard data.count <= maxBytes else { throw UpdateFailure.tooLarge }
        return data
    }

    public func download(from url: URL, to destination: URL, maxBytes: Int) async throws {
        if url.isFileURL {
            try Self.checkFileSize(url, maxBytes: maxBytes)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                throw UpdateFailure.network("ファイルを読めない")
            }
            return
        }
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(from: url)
        } catch {
            throw UpdateFailure.network(Self.describe(error))
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.checkStatus(response)
        try Self.checkFileSize(temporary, maxBytes: maxBytes)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw UpdateFailure.network("落としたファイルを置けない")
        }
    }

    static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200: return
        case 403, 429: throw UpdateFailure.network("GitHub の問い合わせの回数の上限です。しばらく待ってからもう一度")
        case 404: throw UpdateFailure.network("見つからない（404）")
        default: throw UpdateFailure.network("HTTP \(http.statusCode)")
        }
    }

    static func readFile(_ url: URL, maxBytes: Int) throws -> Data {
        try checkFileSize(url, maxBytes: maxBytes)
        guard let data = try? Data(contentsOf: url) else { throw UpdateFailure.network("ファイルを読めない") }
        return data
    }

    static func checkFileSize(_ url: URL, maxBytes: Int) throws {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            throw UpdateFailure.network("ファイルを読めない")
        }
        guard size <= maxBytes else { throw UpdateFailure.tooLarge }
    }

    /// 通信の誤りの短い説明（URL は入れない）
    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return "通信できない" }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost: return "インターネットにつながっていない"
        case .timedOut: return "時間切れ"
        case .cannotFindHost, .dnsLookupFailed: return "相手が見つからない"
        case .cannotConnectToHost: return "つながらない"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "安全な接続を確かめられない"
        default: return "通信できない（\(urlError.code.rawValue)）"
        }
    }
}
