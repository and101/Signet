import OpenSSL

enum CryptoSetup {
    /// zsign calls `OSSL_PROVIDER_load(NULL, "legacy")` before reading p12 files. Explicitly loading any
    /// provider stops OpenSSL from auto-loading "default", which removes HMAC/AES and makes valid p12
    /// passwords fail. Loading both up front keeps every algorithm available.
    static func loadProviders() {
        _ = OSSL_PROVIDER_load(nil, "default")
        _ = OSSL_PROVIDER_load(nil, "legacy")
    }
}
