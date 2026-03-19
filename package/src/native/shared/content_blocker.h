// content_blocker.h - Cross-platform content blocker interface
// Defines the abstract handler and global rule store used by all platforms.
// Each platform provides a concrete ContentBlockerHandler subclass.
//
// Header-only interface; platform implementations live in their respective
// nativeWrapper files.

#ifndef ELECTROBUN_CONTENT_BLOCKER_H
#define ELECTROBUN_CONTENT_BLOCKER_H

#include <atomic>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

namespace electrobun {

// Per-webview handler that applies/removes compiled rules.
// Each platform subclass wraps the native content-blocking API.
class ContentBlockerHandler {
public:
    virtual ~ContentBlockerHandler() = default;

    virtual void enable() = 0;
    virtual void disable() = 0;

    bool isEnabled() const { return m_enabled; }

protected:
    bool m_enabled = false;
};

// Parsed representation of a single WebKit Content Blocker rule.
// Used on Windows where rules must be interpreted manually.
struct ContentBlockerRule {
    std::string urlFilter;
    std::string actionType;     // "block", "css-display-none", "ignore-previous-rules", "block-cookies"
    std::string selector;       // only for css-display-none
    std::string loadType;       // "first-party", "third-party", or empty
    std::vector<std::string> ifDomain;
    std::vector<std::string> unlessDomain;
    std::vector<std::string> resourceType;
};

// Data extracted from WebKit JSON for use on Windows (WebView2).
// Separates network-blocking domains from cosmetic CSS.
struct WebView2BlockData {
    std::unordered_set<std::string> blockedDomains;
    std::unordered_set<std::string> exceptionDomains;
    std::string cosmeticCSS;
};

// Global store for compiled/parsed content-blocker rules.
// Loaded once at startup, shared by all webview instances.
//
// On macOS the compiled rules are WKContentRuleList objects (stored externally
// via Objective-C because this header is plain C++).
// On Linux they are WebKitUserContentFilter objects (same situation).
// On Windows the parsed rules live in the WebView2BlockData member.
class ContentBlockerRuleStore {
public:
    static ContentBlockerRuleStore& instance() {
        static ContentBlockerRuleStore s_instance;
        return s_instance;
    }

    bool isReady() const { return m_ready.load(); }

    void setReady(bool ready) { m_ready.store(ready); }

    // Windows-specific parsed data
    WebView2BlockData& webView2Data() { return m_webView2Data; }
    const WebView2BlockData& webView2Data() const { return m_webView2Data; }

private:
    ContentBlockerRuleStore() = default;
    ContentBlockerRuleStore(const ContentBlockerRuleStore&) = delete;
    ContentBlockerRuleStore& operator=(const ContentBlockerRuleStore&) = delete;

    std::atomic<bool> m_ready{false};
    WebView2BlockData m_webView2Data;
};

// Zero-copy hostname extraction. Returns a view into the original URL string.
inline std::string_view extractHostnameView(const std::string& url) {
    auto schemeEnd = url.find("://");
    if (schemeEnd == std::string::npos) return {};
    size_t hostStart = schemeEnd + 3;
    if (hostStart >= url.size()) return {};

    size_t hostEnd = url.find_first_of(":/?#", hostStart);
    if (hostEnd == std::string::npos) hostEnd = url.size();

    return std::string_view(url.data() + hostStart, hostEnd - hostStart);
}

// Check if a URL should be blocked. Walks the domain hierarchy once,
// checking both exception and block sets at each level for O(d) total
// hash lookups (d = domain depth, typically 3-4).
inline bool shouldBlockUrl(const WebView2BlockData& data, const std::string& url) {
    std::string_view host = extractHostnameView(url);
    if (host.empty()) return false;

    // Single walk up the domain hierarchy: check exceptions before blocks
    // at each level so an exception at any level short-circuits.
    size_t offset = 0;
    while (offset < host.size()) {
        std::string_view segment(host.data() + offset, host.size() - offset);
        // Construct a temporary string only for the hash lookup
        std::string segStr(segment);
        if (data.exceptionDomains.count(segStr)) return false;
        if (data.blockedDomains.count(segStr)) return true;
        auto dot = segment.find('.');
        if (dot == std::string_view::npos) break;
        offset += dot + 1;
    }
    return false;
}

} // namespace electrobun

#endif // ELECTROBUN_CONTENT_BLOCKER_H
