import Foundation
import Testing
import AppLogic

struct ServiceEndpointTests {
    @Test(arguments: ["", "$(COACH_PROXY_URL)", "not a url", "http://proxy.example", "https://user:secret@proxy.example", "https://proxy.example?key=secret", "https://proxy.example#token", "file:///tmp/key"])
    func invalidConfigurationStaysOffline(_ value: String) {
        #expect(ServiceEndpoint.parse(value) == nil)
    }

    @Test func aPublicHTTPSProxyAndExplicitLocalDevelopmentAreAccepted() {
        #expect(ServiceEndpoint.parse(" https://proxy.example/base ")?.absoluteString == "https://proxy.example/base")
        #expect(ServiceEndpoint.parse(nil) == nil)
        #expect(ServiceEndpoint.parse("http://localhost:8787", allowLocalHTTP: true) != nil)
        #expect(ServiceEndpoint.parse("http://10.0.0.1", allowLocalHTTP: true) == nil)
    }
}
