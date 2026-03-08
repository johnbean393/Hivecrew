import Foundation
import Testing
@testable import Hivecrew

struct WebpageReaderTests {

    @Test
    func proxyFallbackStatusesIncludeRateLimitAndPolicyBlocks() {
        #expect(WebpageReader.shouldUseProxyFallback(statusCode: 429))
        #expect(WebpageReader.shouldUseProxyFallback(statusCode: 451))
        #expect(!WebpageReader.shouldUseProxyFallback(statusCode: 404))
    }

    @Test
    func readableTextExtractsTextFromHTMLResponses() throws {
        let html = """
        <html>
          <head><title>Ignored</title></head>
          <body>
            <article>
              <h1>Tencent Q4</h1>
              <p>Revenue increased year over year.</p>
            </article>
          </body>
        </html>
        """

        let text = try WebpageReader.readableText(from: Data(html.utf8), mimeType: "text/html")

        #expect(text.contains("Tencent Q4"))
        #expect(text.contains("Revenue increased year over year."))
    }

    @Test
    func readableTextReturnsPlainTextResponses() throws {
        let payload = Data("Line one\nLine two".utf8)

        let text = try WebpageReader.readableText(from: payload, mimeType: "text/plain")

        #expect(text == "Line one\nLine two")
    }
}
